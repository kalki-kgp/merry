import Testing
@testable import MerryCore

/// A PDF with a line of real text on each page, so no OCR is needed to read it.
private func makePDF(_ path: String, pages: [String]) throws {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil) else { throw MerryError("no pdf context") }
    for text in pages {
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
}

private func failure(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch { return messageOf(error) }
}

@Test func readingDocuments() async throws {
    let s = try FileScratch("docs")
    let allowed = "\(s.root)/allowed"
    try s.write("allowed/notes.txt", "Rent is due on the 5th.\nUntrusted text.")
    try s.write("allowed/long.md", String(repeating: "ab", count: 40_000))
    try s.write("allowed/thing.xyz", "?")
    try s.write("outside/secret.txt", "secret")
    try makePDF("\(allowed)/invoice.pdf", pages: ["Merry invoice total 4200 rupees", "Second page of the invoice", "Third page of the invoice"])
    try FileManager.default.createSymbolicLink(atPath: "\(allowed)/link.txt", withDestinationPath: "\(s.root)/outside/secret.txt")
    try FileManager.default.createSymbolicLink(atPath: "\(allowed)/inner.txt", withDestinationPath: "\(allowed)/notes.txt")
    let ctx = FileRecorder().context(Authorization(readRoots: [allowed]))

    // Plain text.
    let text = try readDocument.input.parse(["path": .string("\(allowed)/notes.txt")])
    #expect(readDocument.scopes(text) == [.read(path: "\(allowed)/notes.txt")])
    let read = try await readDocument.execute(text, ctx)
    #expect(read.result.str("path") == "\(allowed)/notes.txt")
    #expect(read.result["untrustedDocument"]?.firstDifference(from: [
        "pages": [["page": 1, "text": "Rent is due on the 5th.\nUntrusted text.", "ocr": false]], "pageCount": 1, "truncated": false
    ]) == nil)
    #expect(read.evidence == [.path("notes.txt", "\(allowed)/notes.txt")])

    // Text is cut at 60,000 characters and says so.
    let long = try await readDocumentText("\(allowed)/long.md")
    #expect(long.pages[0].text.count == 60_000 && long.truncated)

    // A one-page read of a generated PDF, then later pages by number.
    let pdf = try await readDocument.execute(try readDocument.input.parse(["path": .string("\(allowed)/invoice.pdf"), "maxPages": 1]), ctx).result["untrustedDocument"]!
    #expect(pdf.int("pageCount") == 3 && pdf.flag("truncated") && pdf.list("pages").count == 1)
    #expect(pdf.list("pages")[0].int("page") == 1 && pdf.list("pages")[0].flag("ocr") == false)
    #expect(pdf.list("pages")[0].str("text").contains("Merry invoice total 4200 rupees"))
    let rest = try await readDocumentText("\(allowed)/invoice.pdf", startPage: 2, maxPages: 8)
    #expect(rest.pages.map(\.page) == [2, 3] && !rest.truncated && rest.pages[1].text.contains("Third page"))
    #expect(await failure { _ = try await readDocumentText("\(allowed)/invoice.pdf", startPage: 4) } == "Page number is outside the document")
    try s.write("allowed/broken.pdf", "not a pdf")
    #expect(await failure { _ = try await readDocumentText("\(allowed)/broken.pdf") } == "PDF unreadable or locked")

    // What it will not read.
    #expect(await failure { _ = try await readDocumentText("\(allowed)/thing.xyz") } == "Supported: PDFs, images, Word documents, and text files.")
    #expect(await failure { _ = try await readDocumentText(allowed) } == "Choose a document smaller than 50 MB.")
    #expect(await failure { _ = try await readDocumentText("\(allowed)/gone.txt") } == "ENOENT: no such file or directory, realpath '\(allowed)/gone.txt'")

    // A link inside the allowed folder that leads out of it is refused on where it really points.
    let outside = "The actual document location is outside the folders allowed for this task. Select that location explicitly."
    let link = try readDocument.input.parse(["path": .string("\(allowed)/link.txt")])
    #expect(checkScopes(ctx.task().authorization, readDocument.scopes(link)).allowed)
    #expect(await failure { _ = try await readDocument.execute(link, ctx) } == outside)
    #expect(await failure { _ = try await readDocument.execute(try readDocument.input.parse(["path": .string("\(s.root)/outside/secret.txt")]), ctx) } == outside)
    // A link that stays inside is followed, and reported at its real location.
    let inner = try await readDocument.execute(try readDocument.input.parse(["path": .string("\(allowed)/inner.txt")]), ctx)
    #expect(inner.result.str("path") == "\(allowed)/notes.txt")
    // The allowed folder may itself be named through a link.
    try FileManager.default.createSymbolicLink(atPath: "\(s.root)/alias", withDestinationPath: allowed)
    let viaAlias = FileRecorder().context(Authorization(readRoots: ["\(s.root)/alias"]))
    #expect(try await readDocument.execute(text, viaAlias).result.str("path") == "\(allowed)/notes.txt")
}

@Test func searchingDocumentContents() async throws {
    let s = try FileScratch("docsearch")
    let rec = FileRecorder(), ctx = rec.context(Authorization(readRoots: [s.root]))
    try s.write("a.txt", "The electricity bill for March is 1840 rupees.", modified: 5_000_000)
    try s.write("b.md", "Nothing relevant here.", modified: 4_000_000)
    try s.write("one/two/deep.txt", "Electricity bill, second copy.", modified: 3_000_000)
    try s.write("one/two/three/too-deep.txt", "electricity bill", modified: 9_000_000)
    try s.write("node_modules/x.txt", "electricity bill", modified: 9_000_000)
    try s.write(".hidden.txt", "electricity bill", modified: 9_000_000)
    try s.write("skip.json", "electricity bill", modified: 9_000_000)
    try s.write("broken.pdf", "electricity bill", modified: 2_000_000)
    try makePDF("\(s.root)/bill.pdf", pages: ["Electricity bill for April", "page two", "electricity bill on page three"])

    let input = try searchDocuments.input.parse(["folder": .string(s.root), "query": "  Electricity   BILL "])
    #expect(input.str("query") == "Electricity   BILL")
    let out = try await searchDocuments.execute(input, ctx)
    let r = out.result
    #expect(r.int("candidates") == 5 && r.int("examined") == 5)
    #expect(r.strings("unreadable") == ["\(s.root)/broken.pdf"])
    let matches = r.list("matches")
    // Only the first two pages of a PDF are looked at.
    #expect(Set(matches.map { "\(Path.basename($0.str("path"))):\($0.int("page"))" }) == ["bill.pdf:1", "a.txt:1", "deep.txt:1"])
    #expect(matches.first { $0.str("path") == "\(s.root)/a.txt" }?.str("snippet") == "The electricity bill for March is 1840 rupees.")
    #expect(r.str("coverage") == "Up to two subfolder levels; 500 directory entries; newest files first; first two PDF pages only.")
    #expect(out.evidence.contains(.path("a.txt · page 1", "\(s.root)/a.txt")))
    #expect(rec.progress.contains("Looking inside a.txt"))

    // Newest first, up to maxFiles.
    let few = try await searchDocuments.execute(try searchDocuments.input.parse(["folder": .string(s.root), "query": "electricity", "maxFiles": 1]), ctx).result
    #expect(few.int("examined") == 1 && few.int("candidates") == 5)
    // A folder the task was not given is refused.
    let other = try FileScratch("docsearch-other")
    #expect(await failure { _ = try await searchDocuments.execute(try searchDocuments.input.parse(["folder": .string(other.root), "query": "electricity"]), ctx) } != nil)
}

@Test func preparingCopies() async throws {
    let s = try FileScratch("prepare")
    let rec = FileRecorder(), ctx = rec.context(Authorization(readRoots: ["\(s.root)/in"], writeRoots: ["\(s.root)/out"]))
    try FileManager.default.createDirectory(atPath: "\(s.root)/in", withIntermediateDirectories: true)
    try makePDF("\(s.root)/in/scan.pdf", pages: ["Page one of a scan", "Page two of a scan"])
    let original = FileManager.default.contents(atPath: "\(s.root)/in/scan.pdf")

    let input = try prepareDocuments.input.parse(["paths": [.string("\(s.root)/in/scan.pdf")], "outputFolder": .string("\(s.root)/out/prepared"), "format": "pdf", "maxEdge": 600])
    #expect(prepareDocuments.scopes(input) == [.read(path: "\(s.root)/in/scan.pdf"), .write(path: "\(s.root)/out/prepared")])
    let out = try await prepareDocuments.execute(input, ctx)
    let outputs = out.result.list("outputs")
    #expect(outputs.count == 1 && out.result.flag("originalsPreserved"))
    let path = outputs[0].str("path")
    #expect(Path.basename(path) == "01-scan.pdf" && Path.basename(Path.dirname(path)).hasPrefix("Merry-prepared-") && Path.dirname(Path.dirname(path)) == "\(s.root)/out/prepared")
    #expect(PDFDocument(url: URL(fileURLWithPath: path))?.pageCount == 2)
    #expect(try NodeFS.stat(path).size == outputs[0].int("bytes"))
    #expect(FileManager.default.contents(atPath: "\(s.root)/in/scan.pdf") == original)
    #expect(out.evidence.first == .path("Prepared copies", Path.dirname(path)))
    #expect(rec.progress == ["Preparing scan.pdf"])
    #expect(try await prepareDocuments.verify?(input, out, ctx).verified == true)
    try Data("changed".utf8).write(to: URL(fileURLWithPath: path))
    #expect(try await prepareDocuments.verify?(input, out, ctx) == VerificationResult(verified: false, method: "file-size-readback", detail: "Checked every prepared copy and its size limit"))

    // A PDF only becomes a PDF, and a failed call leaves no folder of its own behind.
    let before = try NodeFS.readdir("\(s.root)/out/prepared").count
    let jpeg = try prepareDocuments.input.parse(["paths": [.string("\(s.root)/in/scan.pdf")], "outputFolder": .string("\(s.root)/out/prepared"), "format": "jpeg"])
    #expect(await failure { _ = try await prepareDocuments.execute(jpeg, ctx) } == "Choose PDF output for a PDF source")
    #expect(try NodeFS.readdir("\(s.root)/out/prepared").count == before)
    // An impossible size limit is reported, not quietly missed.
    let tiny = try prepareDocuments.input.parse(["paths": [.string("\(s.root)/in/scan.pdf")], "outputFolder": .string("\(s.root)/out/prepared"), "format": "pdf", "maxBytes": 10000])
    #expect(await failure { _ = try await prepareDocuments.execute(tiny, ctx) } == "Could not meet this size limit. Try a larger limit or fewer pages.")
    // Unsupported sources and folders outside the grant are refused.
    try s.write("in/notes.txt")
    let wrong = try prepareDocuments.input.parse(["paths": [.string("\(s.root)/in/notes.txt")], "outputFolder": .string("\(s.root)/out"), "format": "pdf"])
    #expect(await failure { _ = try await prepareDocuments.execute(wrong, ctx) } == "Choose supported images or PDFs under 50 MB in an allowed location.")
    let elsewhere = try prepareDocuments.input.parse(["paths": [.string("\(s.root)/in/scan.pdf")], "outputFolder": .string("\(s.root)/in"), "format": "pdf"])
    #expect(await failure { _ = try await prepareDocuments.execute(elsewhere, ctx) } == "The actual document location is outside the folders allowed for this task. Select that location explicitly.")
}
