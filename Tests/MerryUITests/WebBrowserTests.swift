import Testing
import MerryCore
@testable import MerryUI

// The browser tools against a real WKWebView, kept off screen, and a website
// served from 127.0.0.1. These mirror what the reference checked against
// Chromium: a real page, a real click.

@Suite(.serialized) struct WebBrowserTests {
    @Test func navigateLandsAndComparesTheOrigin() async throws {
        let bench = try BrowserBench()
        #expect(!bench.browser.isOpen, "nothing is opened until it is needed")

        let input: JSON = ["url": .string(bench.site.origin + "/")]
        let out = try await bench.run("browser_navigate", input)
        #expect(bench.browser.isOpen)
        #expect(out.result.str("url") == bench.site.origin + "/")
        #expect(out.result.num("status") == 200)
        #expect(out.result.str("title") == "Merry Test Home")
        #expect(bench.progress.all == ["Opening 127.0.0.1"])
        let landed = try await bench.verify("browser_navigate", input, out)
        #expect(landed == VerificationResult(verified: true, method: "compare landed origin", detail: "on \(bench.site.origin)/"))

        // A redirect within the origin still verifies; the status is the final one.
        let redirect: JSON = ["url": .string(bench.site.origin + "/redirect"), "waitUntil": "load"]
        let followed = try await bench.run("browser_navigate", redirect)
        #expect(followed.result.str("url") == bench.site.origin + "/second")
        #expect(followed.result.num("status") == 200)
        #expect(followed.result.str("title") == "Second Page")
        #expect(try await bench.verify("browser_navigate", redirect, followed).verified)

        let missing = try await bench.run("browser_navigate", ["url": .string(bench.site.origin + "/nope"), "waitUntil": "networkidle"])
        #expect(missing.result.num("status") == 404)
        #expect(missing.result.str("title") == "Not Found")

        // The site sees a desktop Safari, not an embedded view.
        let agent = bench.site.last("GET", "/nope")?.headers["user-agent"] ?? ""
        #expect(agent.contains("Macintosh") && agent.contains("Version/") && agent.contains("Safari/"))

        // Landing somewhere else is reported, not passed.
        let other = try await bench.verify("browser_navigate", ["url": "http://127.0.0.1:9/"], missing)
        #expect(other == VerificationResult(verified: false, method: "compare landed origin", detail: "asked for http://127.0.0.1:9/ but landed on \(bench.site.origin)/nope"))
        await bench.finish()
    }

    @Test func navigationFailuresAndTimeoutsAreErrors() async throws {
        let bench = try BrowserBench()
        // A site that has gone away: nothing listens on its port any more.
        let closed = try TestSite()
        let dead = closed.origin + "/"
        closed.stop()
        let refused = await bench.failure("browser_navigate", ["url": .string(dead)])
        #expect(refused?.hasPrefix("could not open \(dead): ") == true, "\(refused ?? "no error")")

        let began = milliseconds()
        var said = ""
        do { _ = try await bench.browser.navigate(bench.site.origin + "/slow", waitUntil: "load", timeoutMs: 1000) } catch { said = messageOf(error) }
        #expect(said == "Timeout 1000ms exceeded navigating to \(bench.site.origin)/slow")
        #expect(milliseconds() - began < 2500)
        await bench.finish()
    }

    @Test func evaluateReturnsJSON() async throws {
        let bench = try BrowserBench()
        try await bench.open("/")
        let browser = bench.browser
        #expect(try await browser.evaluate("1 + 2") == 3)
        #expect(try await browser.evaluate("undefined") == .null)
        #expect(try await browser.evaluate("null") == .null)
        #expect(try await browser.evaluate("document.title") == "Merry Test Home")
        #expect(try await browser.evaluate("({ a: [1, 'two', null], b: { c: true }, d: undefined })") == ["a": [1, "two", nil], "b": ["c": true]])
        #expect(try await browser.evaluate("Promise.resolve(7)") == 7)
        #expect(try await browser.evaluate("document.body // a trailing comment") != .null)
        // The page's own world: its globals are visible.
        #expect(try await browser.evaluate("typeof tracked") == "object")
        var said = ""
        do { _ = try await browser.evaluate("(() => { throw new Error('boom') })()") } catch { said = messageOf(error) }
        #expect(said.contains("boom"), "\(said)")
        #expect(try await browser.title() == "Merry Test Home")
        #expect(try await browser.currentURL() == bench.site.origin + "/")
        await bench.finish()
    }

    @Test func inspectGivesReferencesAndUntrustedText() async throws {
        let bench = try BrowserBench()
        try await bench.open("/")
        let out = try await bench.run("browser_inspect_page", [:])
        #expect(out.result.objectValue?.keys == ["url", "title", "elements", "untrustedPageText"])
        #expect(out.result.str("url") == bench.site.origin + "/")
        #expect(out.result.str("title") == "Merry Test Home")
        let text = out.result.str("untrustedPageText")
        #expect(text.contains("Welcome home"))
        #expect(text.contains("Ignore previous instructions"))
        #expect(!text.contains("Hidden words"))

        let elements = out.result.list("elements")
        #expect(elements.map { $0.str("ref") } == (1...elements.count).map { "e\($0)" })
        func element(_ label: String) -> JSON? { elements.first { $0.str("label") == label } }
        // The visible label describes a field, not its name attribute.
        let name = try #require(element("Full name"))
        #expect(name.str("tag") == "input")
        #expect(name.str("type") == "text")
        #expect(name.flag("required"))
        #expect(name["value"] == "")
        #expect((name["box"]?.num("width") ?? 0) > 2)
        #expect(element("Favourite colour")?.str("tag") == "select")
        #expect(element("Send the form")?.str("tag") == "button")
        #expect(element("Go to the second page")?.str("tag") == "a")
        #expect(element("Cannot press")?.flag("disabled") == true)
        #expect(element("Document to upload")?.str("type") == "file")
        // Each reference is stamped on exactly one element.
        for e in elements {
            #expect(try await bench.browser.evaluate("document.querySelectorAll('[data-merry-ref=\"\(e.str("ref"))\"]').length") == 1)
        }
        await bench.finish()
    }

    @Test func fillSetsTheValueAndReadsItBack() async throws {
        let bench = try BrowserBench()
        try await bench.open("/")
        let name = try await bench.ref("Full name")
        let input: JSON = ["ref": .string(name), "value": "Ada \"Countess\" Lovelace"]
        let out = try await bench.run("browser_fill", input)
        #expect(out.result == input)
        #expect(try await bench.browser.evaluate("document.getElementById('name').value") == "Ada \"Countess\" Lovelace")
        let good = try await bench.verify("browser_fill", input, out)
        #expect(good == VerificationResult(verified: true, method: "read input value back", detail: "field contains the value"))
        // The verifier reads the DOM, not what the tool said it typed.
        _ = try await bench.browser.evaluate("document.getElementById('name').value = 'changed by the page'")
        let bad = try await bench.verify("browser_fill", input, out)
        #expect(bad == VerificationResult(verified: false, method: "read input value back", detail: "field contains \"changed by the page\""))

        // Filling replaces, and the page hears about it through events.
        let tracked = try await bench.ref("Tracked field")
        _ = try await bench.run("browser_fill", ["ref": .string(tracked), "value": "first"])
        _ = try await bench.run("browser_fill", ["ref": .string(tracked), "value": "second"])
        #expect(try await bench.browser.evaluate("document.getElementById('echo').textContent") == "typed:second")
        #expect(try await bench.browser.evaluate("window.trackedEvents") == "input,change,input,change")

        let notes = try await bench.ref("Notes")
        _ = try await bench.run("browser_fill", ["ref": .string(notes), "value": "two\nlines"])
        #expect(try await bench.browser.evaluate("document.querySelector('textarea').value") == "two\nlines")

        let editable = try await bench.ref("Free text")
        _ = try await bench.run("browser_fill", ["ref": .string(editable), "value": "new words"])
        #expect(try await bench.browser.evaluate("document.getElementById('editable').textContent") == "new words")

        // Things that hold no text are refused.
        #expect(await bench.failure("browser_fill", ["ref": .string(try await bench.ref("I agree")), "value": "yes"]) == "Input of type \"checkbox\" cannot be filled")
        #expect(await bench.failure("browser_fill", ["ref": .string(try await bench.ref("Send the form")), "value": "x"])
            == "Element is not an <input>, <textarea> or [contenteditable] element")
        await bench.finish()
    }

    @Test func selectChoosesByLabelOrValue() async throws {
        let bench = try BrowserBench()
        try await bench.open("/")
        let colour = try await bench.ref("Favourite colour")
        let byLabel = try await bench.run("browser_select", ["ref": .string(colour), "label": "Green"])
        #expect(byLabel.result == ["ref": .string(colour), "selected": ["g"]])
        #expect(try await bench.browser.evaluate("document.getElementById('colour').value") == "g")
        #expect(try await bench.browser.evaluate("window.colourChanged") == "g")
        let byValue = try await bench.run("browser_select", ["ref": .string(colour), "value": "b"])
        #expect(byValue.result.strings("selected") == ["b"])
        #expect(try await bench.browser.evaluate("document.getElementById('colour').selectedOptions[0].label") == "Blue")
        #expect(await bench.failure("browser_select", ["ref": .string(colour)]) == "give either label or value")
        #expect(await bench.failure("browser_select", ["ref": .string(try await bench.ref("Full name")), "value": "b"]) == "Element is not a <select> element")
        await bench.finish()
    }

    @Test func clickFollowsALink() async throws {
        let bench = try BrowserBench()
        try await bench.open("/")
        let link = try await bench.ref("Go to the second page")
        let out = try await bench.run("browser_click", ["ref": .string(link), "description": "the link to the second page"])
        #expect(out.result == ["ref": .string(link), "urlBefore": .string(bench.site.origin + "/"), "urlAfter": .string(bench.site.origin + "/second")])
        #expect(try await bench.browser.evaluate("document.querySelector('h1').innerText") == "Second page")

        // A link asking for a new window opens in this one.
        try await bench.open("/")
        let blank = try await bench.ref("Open the second page in a new window")
        _ = try await bench.run("browser_click", ["ref": .string(blank), "description": "the new-window link"])
        _ = try await bench.run("browser_wait_for", ["mode": "text", "text": "Nothing to click here", "timeoutMs": 5000])
        #expect(try await bench.browser.currentURL() == bench.site.origin + "/second")

        // A click that goes nowhere returns promptly with the same address.
        try await bench.open("/")
        let order = try await bench.ref("Place order")
        let began = milliseconds()
        let stayed = try await bench.run("browser_click", ["ref": .string(order), "description": "the order button"])
        #expect(stayed.result.str("urlAfter") == bench.site.origin + "/")
        #expect(milliseconds() - began < 3000)
        await bench.finish()
    }

    @Test func aSubmittedFormReachesTheServerWithTheValues() async throws {
        let bench = try BrowserBench()
        try await bench.open("/")
        _ = try await bench.run("browser_fill", ["ref": .string(try await bench.ref("Full name")), "value": "Ada Lovelace & Co"])
        _ = try await bench.run("browser_select", ["ref": .string(try await bench.ref("Favourite colour")), "label": "Blue"])
        _ = try await bench.run("browser_fill", ["ref": .string(try await bench.ref("Notes")), "value": "ring twice"])
        _ = try await bench.run("browser_click", ["ref": .string(try await bench.ref("I agree")), "description": "the agreement checkbox"])
        let sent = try await bench.run("browser_click", ["ref": .string(try await bench.ref("Send the form")), "description": "the submit button"])
        #expect(sent.result.str("urlAfter") == bench.site.origin + "/submit")
        _ = try await bench.run("browser_wait_for", ["mode": "text", "text": "Thanks, we got it", "timeoutMs": 5000])

        let request = try #require(bench.site.last("POST", "/submit"))
        #expect(request.text == "fullName=Ada+Lovelace+%26+Co&colour=b&notes=ring+twice&agree=on")
        #expect(request.headers["content-type"] == "application/x-www-form-urlencoded")
        await bench.finish()
    }

    @Test func aDownloadLandsOnDiskAndIsVerified() async throws {
        let bench = try BrowserBench()
        try await bench.open("/")
        let link = try await bench.ref("Download the report")
        let folder = bench.scratch + "/saved/reports"

        let input: JSON = ["ref": .string(link), "saveTo": .string(folder), "timeoutMs": 20_000]
        #expect(bench.tool("browser_download").scopes(input) == [.write(path: folder)])
        let out = try await bench.run("browser_download", input)
        #expect(out.result == ["path": .string(folder + "/report.csv"), "filename": "report.csv", "bytes": .number(Double(TestSite.report.utf8.count))])
        #expect(out.evidence == [.path("report.csv", folder + "/report.csv")])
        #expect(bench.read(folder + "/report.csv") == TestSite.report)
        #expect(bench.progress.all.last == "Downloading")
        let checked = try await bench.verify("browser_download", input, out)
        #expect(checked == VerificationResult(verified: true, method: "stat downloaded file", detail: "\(folder)/report.csv is \(TestSite.report.utf8.count) bytes"))
        // The page stayed where it was.
        #expect(try await bench.browser.currentURL() == bench.site.origin + "/")

        // Saving into the same folder again replaces the file.
        let again = try await bench.run("browser_download", input)
        #expect(again.result.str("path") == folder + "/report.csv")
        #expect(bench.read(folder + "/report.csv") == TestSite.report)

        // With no folder named it goes to Merry's downloads folder, never over an earlier file.
        let plain = try await bench.run("browser_download", ["ref": .string(link)])
        #expect(plain.result.str("path") == bench.downloads + "/report.csv")
        #expect(bench.read(bench.downloads + "/report.csv") == TestSite.report)
        let second = try await bench.run("browser_download", ["ref": .string(link)])
        #expect(second.result.str("path") == bench.downloads + "/report (1).csv")
        #expect(second.result.str("filename") == "report.csv")
        #expect(try await bench.verify("browser_download", ["ref": .string(link)], second).verified)

        // An element that starts no download runs out of time, and a file that vanished fails the verifier.
        let none = await bench.failure("browser_download", ["ref": .string(try await bench.ref("Place order")), "timeoutMs": 1000])
        #expect(none == "Timeout 1000ms exceeded while waiting for a download to start and finish")
        let gone = ToolOutcome(["path": .string(folder + "/not-there.csv"), "filename": "not-there.csv", "bytes": 0])
        #expect(try await bench.verify("browser_download", input, gone).detail == "\(folder)/not-there.csv is missing or empty")
        await bench.finish()
    }

    @Test func anUploadedFileReachesTheServer() async throws {
        let bench = try BrowserBench()
        try await bench.open("/")
        let bytes: [UInt8] = Array("MERRY-UPLOAD ".utf8) + [0, 1, 2, 254, 255] + Array(" end of file".utf8)
        let file = bench.write("passport scan.bin", bytes)
        let input = try await bench.ref("Document to upload")

        let out = try await bench.run("browser_upload", ["ref": .string(input), "path": .string(file)])
        #expect(out.result == ["ref": .string(input), "path": .string(file)])
        #expect(out.evidence == [.path("Uploaded file", file)])
        #expect(try await bench.browser.evaluate("document.querySelector('input[type=file]').files[0].name") == "passport scan.bin")
        #expect(try await bench.browser.evaluate("document.querySelector('input[type=file]').files[0].size") == .number(Double(bytes.count)))

        let sent = try await bench.run("browser_click", ["ref": .string(try await bench.ref("Upload now")), "description": "the upload button"])
        #expect(sent.result.str("urlAfter") == bench.site.origin + "/upload")
        let request = try #require(bench.site.last("POST", "/upload"))
        #expect(request.headers["content-type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(contains(request.body, bytes), "the server received the file's bytes")
        #expect(contains(request.body, Array("name=\"doc\"; filename=\"passport scan.bin\"".utf8)))

        // Not a file on disk, and not a file input.
        #expect(await bench.failure("browser_upload", ["ref": "e1", "path": .string(bench.scratch)]) == "\(bench.scratch) is not a file")
        try await bench.open("/")
        let name = try await bench.ref("Full name")
        #expect(await bench.failure("browser_upload", ["ref": .string(name), "path": .string(file)]) == "element \"\(name)\" is not a file input")
        await bench.finish()
    }

    @Test func aReferenceFromAnEarlierPageIsRefused() async throws {
        let bench = try BrowserBench()
        try await bench.open("/")
        let link = try await bench.ref("Download the report")
        let name = try await bench.ref("Full name")
        try await bench.open("/second")
        let requestsBefore = bench.site.requests.count

        let gone = { (ref: String) in "element \"\(ref)\" is no longer on the page; call browser_inspect_page again" }
        #expect(await bench.failure("browser_click", ["ref": .string(link), "description": "the report link"]) == gone(link))
        #expect(await bench.failure("browser_fill", ["ref": .string(name), "value": "x"]) == gone(name))
        #expect(await bench.failure("browser_select", ["ref": .string(name), "value": "x"]) == gone(name))
        #expect(await bench.failure("browser_download", ["ref": .string(link)]) == gone(link))
        let file = bench.write("a.txt", Array("a".utf8))
        #expect(await bench.failure("browser_upload", ["ref": .string(name), "path": .string(file)]) == gone(name))
        let checked = try await bench.verify("browser_fill", ["ref": .string(name), "value": "x"], ToolOutcome(.null))
        #expect(checked == VerificationResult(verified: false, method: "read input value back", detail: "Error: \(gone(name))"))
        // Nothing was clicked: the page did not move and the site heard nothing.
        #expect(try await bench.browser.currentURL() == bench.site.origin + "/second")
        #expect(bench.site.requests.count == requestsBefore)
        await bench.finish()
    }

    @Test func waitForTextSeesLateTextAndTimesOut() async throws {
        let bench = try BrowserBench()
        try await bench.open("/")
        #expect(try await bench.browser.evaluate("document.body.innerText.includes('confirmed')") == false)
        _ = try await bench.run("browser_click", ["ref": .string(try await bench.ref("Place order")), "description": "the order button"])
        // Case and spacing do not matter, as with the reference's text match.
        let out = try await bench.run("browser_wait_for", ["mode": "text", "text": "order confirmed", "timeoutMs": 10_000])
        #expect(out.result == ["found": "order confirmed", "url": .string(bench.site.origin + "/")])

        let began = milliseconds()
        #expect(await bench.failure("browser_wait_for", ["mode": "text", "text": "Payment declined", "timeoutMs": 1000])
            == "Timeout 1000ms exceeded waiting for the text \"Payment declined\" to appear")
        #expect(milliseconds() - began >= 1000)
        // Text that is in the document but not shown does not count.
        #expect(await bench.failure("browser_wait_for", ["mode": "text", "text": "Hidden words", "timeoutMs": 1000]) != nil)
        await bench.finish()
    }

    @Test func closingKeepsTheProfile() async throws {
        let bench = try BrowserBench()
        try await bench.open("/")
        #expect(bench.browser.isOpen)
        await bench.browser.close()
        #expect(!bench.browser.isOpen)

        // The next use opens a fresh window; the cookie set before is still sent.
        try await bench.open("/second")
        #expect(bench.browser.isOpen)
        #expect(bench.site.last("GET", "/second")?.headers["cookie"]?.contains("merry_session=abc123") == true)

        // A second browser on the same profile shares the login; another profile does not.
        let sameProfile = WebBrowser(downloadsFolder: bench.downloads, profile: bench.profile, offscreen: true)
        _ = try await sameProfile.navigate(bench.site.origin + "/nope", waitUntil: "load", timeoutMs: 20_000)
        #expect(bench.site.last("GET", "/nope")?.headers["cookie"]?.contains("merry_session=abc123") == true)
        await sameProfile.close()

        let other = try BrowserBench()
        _ = try await other.browser.navigate(bench.site.origin + "/other", waitUntil: "load", timeoutMs: 20_000)
        #expect(bench.site.last("GET", "/other")?.headers["cookie"] == nil)
        await other.finish()

        // The person closing the window is the same as closing the browser.
        await bench.closeWindowAsThePersonWould()
        #expect(!bench.browser.isOpen)
        try await bench.open("/")
        #expect(bench.browser.isOpen)
        await bench.finish()
    }
}
