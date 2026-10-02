import Foundation
import AppKit
import PDFKit
import Vision
import CoreGraphics

// Reading PDFs and images, and preparing copies of them, with PDFKit, Vision
// and ImageIO. The reference ran this in its helper process; here it runs in
// this one, on a background queue, under the same time limits.

public struct DocumentText: Equatable, Sendable {
    public struct Page: Equatable, Sendable {
        public var page: Int
        public var text: String
        public var ocr: Bool
        public init(page: Int, text: String, ocr: Bool) { self.page = page; self.text = text; self.ocr = ocr }
    }

    public var pages: [Page]
    public var pageCount: Int
    public var truncated: Bool

    public init(pages: [Page], pageCount: Int, truncated: Bool) { self.pages = pages; self.pageCount = pageCount; self.truncated = truncated }

    public var json: JSON {
        [
            "pages": .array(pages.map { ["page": JSON($0.page), "text": .string($0.text), "ocr": .bool($0.ocr)] }),
            "pageCount": JSON(pageCount),
            "truncated": .bool(truncated)
        ]
    }
}

public struct PreparedDocument: Equatable, Sendable {
    public var bytes: Int
    public var pages: Int
    public var rasterized: Bool
    public var path: String
}

public enum NativeDocuments {
    /// Text of a PDF's pages or of an image, using on-device OCR where a page has no text layer.
    public static func read(path: String, startPage: Int = 1, maxPages: Int = 8, timeoutMs: Int = 90_000) async throws -> DocumentText {
        let start = max(1, startPage), count = max(1, min(20, maxPages))
        return try await offMain("readDocument", timeoutMs) { try readDocument(path: path, startPage: start, maxPages: count) }
    }

    /// Writes a new PDF, JPEG or PNG copy at `output`. The source is never changed.
    public static func prepare(path: String, output: String, format: String, edge: Int = 1600, maxBytes: Int = 0, timeoutMs: Int = 120_000) async throws -> PreparedDocument {
        let boundedEdge = max(480, min(3000, edge)), limit = max(0, maxBytes)
        return try await offMain("prepareDocument", timeoutMs) {
            try prepareDocument(path: path, output: output, format: format, edge: boundedEdge, maxBytes: limit)
        }
    }

    /// Runs blocking work on a background queue and gives up waiting after `timeoutMs`.
    private static func offMain<T: Sendable>(_ op: String, _ timeoutMs: Int, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let once = Once<T>()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<T, Error>
                do {
                    result = .success(try work())
                } catch let error as MerryError {
                    result = .failure(error)
                } catch {
                    result = .failure(MerryError("\(error)"))
                }
                if once.claim() { continuation.resume(with: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                if once.claim() { continuation.resume(throwing: MerryError("macOS helper timed out after \(timeoutMs)ms on \"\(op)\"")) }
            }
        }
    }

    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

private func documentImage(_ image: NSImage) throws -> CGImage {
    var rect = CGRect(origin: .zero, size: image.size)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw MerryError("Could not decode image") }
    return cg
}

private func recognizeText(_ image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

private func readDocument(path: String, startPage: Int, maxPages: Int) throws -> DocumentText {
    let url = URL(fileURLWithPath: path)
    if url.pathExtension.lowercased() == "pdf" {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { throw MerryError("PDF unreadable or locked") }
        guard startPage >= 1 && startPage <= doc.pageCount else { throw MerryError("Page number is outside the document") }
        var pages: [DocumentText.Page] = []
        var chars = 0
        for index in (startPage - 1)..<min(doc.pageCount, startPage - 1 + maxPages) {
            guard let page = doc.page(at: index) else { continue }
            var text = page.string ?? ""
            let ocr = text.trimmingCharacters(in: .whitespacesAndNewlines).count < 12
            if ocr { text = try recognizeText(documentImage(page.thumbnail(of: NSSize(width: 1600, height: 2000), for: .mediaBox))) }
            text = String(text.prefix(20000))
            pages.append(.init(page: index + 1, text: text, ocr: ocr))
            chars += text.count
            if chars >= 60000 { break }
        }
        return DocumentText(pages: pages, pageCount: doc.pageCount, truncated: startPage - 1 + pages.count < doc.pageCount)
    }
    guard let image = NSImage(contentsOf: url) else { throw MerryError("Unsupported image") }
    return DocumentText(pages: [.init(page: 1, text: String(try recognizeText(documentImage(image)).prefix(60000)), ocr: true)], pageCount: 1, truncated: false)
}

private func scaledImage(_ image: CGImage, edge: Int) throws -> CGImage {
    let scale = min(1.0, Double(edge) / Double(max(image.width, image.height)))
    let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw MerryError("Could not resize image") }
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else { throw MerryError("Could not resize image") }
    return result
}

/// Output is a new copy. PDF reduction rasterizes pages, so searchable originals are preserved.
private func prepareDocument(path: String, output: String, format: String, edge: Int, maxBytes: Int) throws -> PreparedDocument {
    let input = URL(fileURLWithPath: path)
    let pdf = input.pathExtension.lowercased() == "pdf" ? PDFDocument(url: input) : nil
    if input.pathExtension.lowercased() == "pdf" && (pdf == nil || pdf!.isLocked) { throw MerryError("PDF unreadable or locked") }
    if let pdf = pdf, pdf.pageCount > 80 { throw MerryError("Prepare at most 80 PDF pages at a time") }
    if pdf != nil && format != "pdf" { throw MerryError("Choose PDF output for a PDF source") }
    let count = pdf?.pageCount ?? 1
    guard count > 0 else { throw MerryError("Empty document") }
    // Bound decoded pixels across a batch of PDF pages, even at the largest requested edge.
    let effectiveEdge = min(edge, max(480, Int(sqrt(24_000_000.0 / Double(count)))))
    var images: [CGImage] = []
    for index in 0..<count {
        let image: NSImage?
        if let pdf = pdf { image = pdf.page(at: index)?.thumbnail(of: NSSize(width: effectiveEdge, height: effectiveEdge), for: .mediaBox) }
        else { image = NSImage(contentsOf: input) }
        guard let image = image else { throw MerryError("Unsupported source file") }
        images.append(try scaledImage(documentImage(image), edge: effectiveEdge))
    }
    var result: Data?
    for attempt in 0..<7 {
        let attemptEdge = max(480, Int(Double(effectiveEdge) * pow(0.8, Double(attempt))))
        let quality = max(0.3, 0.85 - Double(attempt) * 0.08)
        if format == "pdf" {
            let doc = PDFDocument()
            for (index, original) in images.enumerated() {
                let cg = try scaledImage(original, edge: attemptEdge)
                let rep = NSBitmapImageRep(cgImage: cg)
                guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]), let decoded = NSImage(data: jpeg), let page = PDFPage(image: decoded) else { throw MerryError("Could not create PDF") }
                doc.insert(page, at: index)
            }
            result = doc.dataRepresentation()
        } else {
            let rep = NSBitmapImageRep(cgImage: try scaledImage(images[0], edge: attemptEdge))
            result = rep.representation(using: format == "png" ? .png : .jpeg, properties: [.compressionFactor: quality])
        }
        if let data = result, maxBytes == 0 || data.count <= maxBytes { break }
    }
    guard let data = result, maxBytes == 0 || data.count <= maxBytes else { throw MerryError("Could not meet this size limit. Try a larger limit or fewer pages.") }
    try data.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    return PreparedDocument(bytes: data.count, pages: count, rasterized: pdf != nil, path: output)
}
