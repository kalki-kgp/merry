import AppKit
import Foundation
import MerryCore
import WebKit

/// Merry's own browser: a WebKit view in an ordinary window, with a profile
/// that belongs to Merry alone. It never reaches into the user's Safari or
/// Chrome sessions: the user signs into services here, once, and those logins
/// persist in this profile only.
///
/// Nothing is created until the first call that needs a page. Every method can
/// be called from any thread; the WebKit work happens on the main actor.
public final class WebBrowser: BrowserSession, @unchecked Sendable {
    /// The profile every launch of Merry shares, so logins persist.
    public static let defaultProfile = UUID(uuidString: "6B1B7A0E-4B1D-4F6A-9C55-4B4942550001")!

    private let engine: Engine
    private let state: OpenState

    /// - Parameters:
    ///   - downloadsFolder: where a download lands when the tool names no folder.
    ///   - profile: identifies the persistent website data store.
    ///   - offscreen: keeps the window off screen, for tests. Visible by
    ///     default: the user must be able to see what Merry is doing in the
    ///     browser, and complete sign-ins there themselves.
    public init(
        downloadsFolder: String,
        profile: UUID = WebBrowser.defaultProfile,
        offscreen: Bool = false,
        log: @escaping @Sendable (LogEntry.Level, String) -> Void = { _, _ in }
    ) {
        let state = OpenState()
        self.state = state
        self.engine = Engine(downloadsFolder: downloadsFolder, profile: profile, offscreen: offscreen, state: state, log: log)
    }

    public var isOpen: Bool { state.value }

    /// Closes the window and lets go of the view. The profile stays.
    public func close() async { await engine.close() }

    public func navigate(_ url: String, waitUntil: String, timeoutMs: Int) async throws -> BrowserNavigation {
        try await engine.navigate(url, waitUntil: waitUntil, timeoutMs: timeoutMs)
    }

    public func currentURL() async throws -> String { await engine.currentURL() }
    public func title() async throws -> String { try await engine.title() }
    public func evaluate(_ script: String) async throws -> JSON { try await engine.evaluate(script) }
    public func waitForLoad(timeoutMs: Int) async { await engine.waitForLoad(timeoutMs: timeoutMs) }

    public func setInputFiles(ref: String, path: String, timeoutMs: Int) async throws {
        try await engine.setInputFiles(ref: ref, path: path, timeoutMs: timeoutMs)
    }

    public func download(clickingRef ref: String, saveTo: String?, timeoutMs: Int) async throws -> BrowserDownload {
        try await engine.download(clickingRef: ref, saveTo: saveTo, timeoutMs: timeoutMs)
    }

    /// Deletes a profile's stored website data. The browser using it must be closed.
    public static func removeProfile(_ profile: UUID) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                WKWebsiteDataStore.remove(forIdentifier: profile) { _ in done.resume() }
            }
        }
    }
}

private final class OpenState: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return open }
        set { lock.lock(); open = newValue; lock.unlock() }
    }
}

@MainActor
private final class Engine: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSWindowDelegate {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// Where the main frame is in loading a page.
    private enum Phase { case idle, asked, started, committed }

    private struct DownloadPlan {
        var folder: String?
        var outcome: Result<BrowserDownload, Error>?
    }

    private let downloadsFolder: String
    private let profile: UUID
    private let offscreen: Bool
    private let state: OpenState
    private let log: @Sendable (LogEntry.Level, String) -> Void

    private var window: NSWindow?
    private var webView: WKWebView?

    private var phase = Phase.idle
    private var phaseSince = Date()
    private var sawStart = false
    private var mainStatus: Int?
    private var loadFailure: Error?
    private var becameDownload = false
    private var processEnded = false
    /// The address of the page last shown, to return to if its process ends.
    private var lastCommitted: URL?
    /// When the page process last had to be replaced, so a page that keeps
    /// taking it down is not reloaded forever.
    private var lastRecovery = Date.distantPast

    private var uploadPath: String?
    private var uploadTaken = false
    private var plan: DownloadPlan?
    private var destinations: [ObjectIdentifier: (path: String, name: String)] = [:]

    nonisolated init(downloadsFolder: String, profile: UUID, offscreen: Bool, state: OpenState, log: @escaping @Sendable (LogEntry.Level, String) -> Void) {
        self.downloadsFolder = downloadsFolder
        self.profile = profile
        self.offscreen = offscreen
        self.state = state
        self.log = log
        super.init()
    }

    // MARK: Window

    private func page() -> WKWebView {
        if let webView { return webView }
        _ = NSApplication.shared
        log(.info, "opening Merry's browser with profile \(profile.uuidString)")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
        let view = WKWebView(frame: frame, configuration: configuration)
        view.customUserAgent = Engine.userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true

        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Merry's Browser"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.delegate = self
        if offscreen {
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        self.window = window
        self.webView = view
        phase = .idle
        state.value = true
        return view
    }

    /// Drops the view and the window. Website data stays in the profile.
    private func release() {
        guard let view = webView else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        window?.delegate = nil
        window?.contentView = nil
        webView = nil
        window = nil
        phase = .idle
        uploadPath = nil
        if plan != nil, plan?.outcome == nil { plan?.outcome = .failure(MerryError("Merry's browser window was closed")) }
        state.value = false
    }

    func close() {
        let closing = window
        release()
        closing?.close()
    }

    /// The person closed the window. The next use opens a fresh one.
    func windowWillClose(_ notification: Notification) {
        release()
    }

    // MARK: Session

    func currentURL() -> String {
        // While a page process that ended is being replaced the view has no
        // address; the page it is coming back to is still where we are.
        page().url?.absoluteString ?? lastCommitted?.absoluteString ?? "about:blank"
    }

    func title() async throws -> String {
        let view = page()
        if let title = (try? await evaluate("document.title"))?.stringValue { return title }
        return view.title ?? ""
    }

    func navigate(_ url: String, waitUntil: String, timeoutMs: Int) async throws -> BrowserNavigation {
        guard let target = URL(string: url) else { throw MerryError("Invalid URL: \(url)") }
        let view = page()
        mainStatus = nil
        loadFailure = nil
        processEnded = false
        becameDownload = false
        sawStart = false
        set(.started)
        let began = Date()
        view.load(URLRequest(url: target))

        let deadline = began.addingTimeInterval(Double(timeoutMs) / 1000)
        var retried = false
        var quietSince: Date?
        var resources = -1
        while true {
            guard webView === view else { throw MerryError("Merry's browser window was closed") }
            if processEnded {
                // WebKit starts a new page process on the next load; ask once more.
                if retried { throw MerryError(describe(MerryError("the page stopped responding"), url: url)) }
                retried = true
                processEnded = false
                sawStart = false
                set(.started)
                view.load(URLRequest(url: target))
            }
            if let loadFailure { throw MerryError(describe(loadFailure, url: url)) }
            if becameDownload { throw MerryError("Download is starting") }
            // A change of fragment loads nothing, so nothing reports back.
            let nothingToLoad = !sawStart && !view.isLoading && Date().timeIntervalSince(began) > 1
            let finished = !processEnded && (phase == .idle || nothingToLoad)
            var done = false
            switch waitUntil {
            case "load":
                done = finished
            case "networkidle":
                // No network view exists here: idle means loaded, and no new
                // resource fetched for half a second.
                if finished {
                    let count = (try? await evaluate("performance.getEntriesByType('resource').length"))?.intValue ?? 0
                    if count != resources || view.isLoading { resources = count; quietSince = Date() }
                    done = Date().timeIntervalSince(quietSince ?? Date()) >= 0.5
                }
            default:
                done = finished
                if !done, phase == .committed { done = await domReady(view) }
            }
            if done { break }
            if Date() >= deadline { throw MerryError("Timeout \(timeoutMs)ms exceeded navigating to \(url)") }
            await pause(20)
        }
        return BrowserNavigation(url: currentURL(), status: mainStatus, title: (try? await title()) ?? "")
    }

    /// The script is an expression. Its value is serialised in the page and
    /// parsed here, so `undefined` reads as null and objects arrive whole.
    func evaluate(_ script: String) async throws -> JSON {
        let view = page()
        let body = "const __merryValue = await (\n\(script)\n);\nconst __merryText = JSON.stringify(__merryValue);\nreturn __merryText === undefined ? 'null' : __merryText;"
        var text: Any?
        var attempt = 0
        while true {
            do {
                text = try await view.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
                break
            } catch {
                let failure = error as NSError
                // A page that navigates away mid-call takes the answer with it.
                // That is the page changing, not the script failing: let the
                // new page arrive and ask it instead.
                let interrupted = failure.domain == WKErrorDomain && failure.userInfo["WKJavaScriptExceptionMessage"] == nil
                    && [WKError.javaScriptResultTypeIsUnsupported.rawValue, WKError.webContentProcessTerminated.rawValue, WKError.webViewInvalidated.rawValue].contains(failure.code)
                if interrupted, attempt < 2, webView === view {
                    attempt += 1
                    await pause(60)
                    await waitForLoad(timeoutMs: 10_000)
                    continue
                }
                throw MerryError((failure.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription)
            }
        }
        guard let text = text as? String else { return .null }
        return try JSON.parse(text)
    }

    func waitForLoad(timeoutMs: Int) async {
        guard let view = webView else { return }
        let began = Date()
        // A click answers before the page has asked to go anywhere.
        while phase == .idle, !view.isLoading, Date().timeIntervalSince(began) < 0.3 { await pause(10) }
        let deadline = began.addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline, webView === view {
            switch phase {
            case .idle:
                if !view.isLoading || Date().timeIntervalSince(began) >= 0.3 { return }
            case .asked:
                // Allowed, yet nothing started: a jump within the same document.
                if !view.isLoading, Date().timeIntervalSince(phaseSince) > 0.7 { set(.idle); return }
            case .started:
                break
            case .committed:
                if await domReady(view) { return }
            }
            await pause(20)
        }
    }

    func setInputFiles(ref: String, path: String, timeoutMs: Int) async throws {
        _ = page()
        // WebKit lets no script put a file into an input. The input is clicked
        // instead, and the open panel it asks for is answered with the file.
        uploadPath = path
        uploadTaken = false
        defer { uploadPath = nil }
        let clicked = try await evaluate(clickScript(ref, fileInputOnly: true)).stringValue ?? ""
        if clicked == "missing" { throw stale(ref) }
        if clicked == "not-file" { throw MerryError("element \"\(ref)\" is not a file input") }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while !uploadTaken {
            if Date() >= deadline { throw MerryError("Timeout \(timeoutMs)ms exceeded: the page never asked for a file after \"\(ref)\" was clicked") }
            await pause(20)
        }
        // The page learns of the file a moment after the panel is answered.
        let settled = Date().addingTimeInterval(2)
        while Date() < settled {
            if (try? await evaluate(filesScript(ref)))?.intValue ?? 0 > 0 { return }
            await pause(20)
        }
    }

    func download(clickingRef ref: String, saveTo: String?, timeoutMs: Int) async throws -> BrowserDownload {
        let view = page()
        plan = DownloadPlan(folder: saveTo)
        defer { plan = nil }
        let clicked = try await evaluate(clickScript(ref, fileInputOnly: false)).stringValue ?? ""
        if clicked == "missing" { throw stale(ref) }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if let outcome = plan?.outcome { return try outcome.get() }
            guard webView === view else { throw MerryError("Merry's browser window was closed") }
            if Date() >= deadline { throw MerryError("Timeout \(timeoutMs)ms exceeded while waiting for a download to start and finish") }
            await pause(20)
        }
    }

    // MARK: Helpers

    private func set(_ next: Phase) {
        phase = next
        phaseSince = Date()
    }

    private func pause(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func domReady(_ view: WKWebView) async -> Bool {
        guard let state = try? await view.evaluateJavaScript("document.readyState") as? String else { return false }
        return state != "loading"
    }

    private func stale(_ ref: String) -> MerryError {
        MerryError("element \"\(ref)\" is no longer on the page; call browser_inspect_page again")
    }

    private func find(_ ref: String) -> String {
        "Array.from(document.querySelectorAll('[data-merry-ref]')).find((e) => e.getAttribute('data-merry-ref') === \(JSON.string(ref).stringify()))"
    }

    private func clickScript(_ ref: String, fileInputOnly: Bool) -> String {
        """
        (() => {
          const el = \(find(ref));
          if (!el) return 'missing';
          if (\(fileInputOnly) && !(el.tagName === 'INPUT' && (el.getAttribute('type') || '').toLowerCase() === 'file')) return 'not-file';
          if (!\(fileInputOnly)) el.scrollIntoView({ block: 'center', inline: 'center' });
          el.click();
          return 'ok';
        })()
        """
    }

    private func filesScript(_ ref: String) -> String {
        "(() => { const el = \(find(ref)); return el && el.files ? el.files.length : 0; })()"
    }

    private func describe(_ error: Error, url: String) -> String {
        "could not open \(url): \(error.localizedDescription)"
    }

    /// Errors that mean "this load gave way to something else", not "it failed".
    private func isSuperseded(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return true }
        // Frame load interrupted: the response turned into a download.
        return e.domain == "WebKitErrorDomain" && e.code == 102
    }

    private func finish(_ error: Error?) {
        if let error {
            if isSuperseded(error) {
                // A cancelled load is followed by the one that replaced it.
                if (error as NSError).domain == NSURLErrorDomain { return }
            } else {
                loadFailure = error
            }
        }
        set(.idle)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // A link that asks for a new window opens in this one: there is one
        // page. Refusing the new window here and loading the address ourselves
        // keeps WebKit from ever starting to build a second page.
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            // A fresh request for the address: the action's own request belongs
            // to the window that was refused.
            if let url = navigationAction.request.url {
                if phase == .idle { set(.asked) }
                DispatchQueue.main.async { [weak webView] in webView?.load(URLRequest(url: url)) }
            }
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true, phase == .idle { set(.asked) }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        let attachment = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment")
        if attachment || !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        if navigationResponse.isForMainFrame { mainStatus = http?.statusCode }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        sawStart = true
        set(.started)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        lastCommitted = webView.url
        set(.committed)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log(.warn, "the browser's page process ended unexpectedly")
        processEnded = true
        // WebKit's page process can end by itself (it has done so while
        // clearing away a previous page). The window would be left blank, so
        // put back the page it was showing, unless that was only just tried.
        if phase == .idle, let url = lastCommitted, Date().timeIntervalSince(lastRecovery) > 5 {
            lastRecovery = Date()
            processEnded = false
            sawStart = false
            set(.started)
            webView.load(URLRequest(url: url))
            return
        }
        set(.idle)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adopt(download)
    }

    private func adopt(_ download: WKDownload) {
        download.delegate = self
        becameDownload = true
        // The page that was showing stays; nothing is loading any more.
        if phase != .committed { set(.idle) }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let name = Path.basename(suggestedFilename).isEmpty ? "download" : Path.basename(suggestedFilename)
        let chosen = plan?.folder
        let folder = chosen ?? downloadsFolder
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            var path = Path.join(folder, name)
            if FileManager.default.fileExists(atPath: path) {
                if chosen != nil {
                    // Saving to a named folder replaces what is there, as the reference's saveAs did.
                    try FileManager.default.removeItem(atPath: path)
                } else {
                    let ext = Path.extname(name)
                    let stem = Path.basename(name, ext)
                    var n = 1
                    repeat { path = Path.join(folder, "\(stem) (\(n))\(ext)"); n += 1 } while FileManager.default.fileExists(atPath: path)
                }
            }
            destinations[ObjectIdentifier(download)] = (path, name)
            completionHandler(URL(fileURLWithPath: path))
        } catch {
            if plan != nil { plan?.outcome = .failure(MerryError("could not save the download: \(messageOf(error))")) }
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let landed = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        log(.info, "downloaded \(landed.path)")
        if plan != nil, plan?.outcome == nil { plan?.outcome = .success(BrowserDownload(path: landed.path, suggestedFilename: landed.name)) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        if plan != nil, plan?.outcome == nil { plan?.outcome = .failure(MerryError("the download failed: \(error.localizedDescription)")) }
    }

    // MARK: WKUIDelegate

    /// Reached only by `window.open` calls the policy above did not see; the
    /// address is loaded in this page instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        if let path = uploadPath {
            uploadPath = nil
            uploadTaken = true
            completionHandler([URL(fileURLWithPath: path)])
            return
        }
        // The person is choosing a file themselves in Merry's window.
        guard !offscreen, let window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}
