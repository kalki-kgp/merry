import Foundation

/// Times every route a request can actually take on this machine.
///
/// The point is to stop guessing where the seconds go. Jev's own latency, the
/// macOS index, and pure local work differ by two orders of magnitude, and
/// which one a feature can afford is a measurement, not an opinion.
public func runBench(jevApiKey: String?, model: ModelConfig) async -> [BenchRow] {
    var rows: [BenchRow] = []

    func time(_ group: String, _ label: String, usd: (() -> Double)? = nil, _ work: () async throws -> String) async {
        let started = Date()
        let detail: String
        do { detail = try await work() } catch { detail = "failed: \(messageOf(error))" }
        rows.append(BenchRow(group: group, label: label, ms: (Date().timeIntervalSince(started) * 1000).rounded(), detail: detail, usd: usd?()))
    }

    // ---- Jev, over the real network ----
    let jev = Jev(apiKey: jevApiKey, enabled: true, model: model.jev)
    if !jev.available {
        rows.append(BenchRow(group: "Jev", label: "not configured", ms: 0, detail: "no TypeSafe key, so nothing to measure"))
    } else {
        var spent = 0.0
        let spentSince: () -> Double = {
            let now = jev.metrics.totalUsd
            defer { spent = now }
            return now - spent
        }

        await time("Jev", "first call (includes TLS handshake)", usd: spentSince) {
            let a = await jev.ask("bench_warm", state: ["userRequest": "find my tax pdf"],
                                  questions: [("kind", .choice("What is this?", [("file", "A file search."), ("app", "Launching an app."), ("other", "Something else.")]))])
            return a.map { "answered \"\($0["kind"]?.choice ?? "")\"" } ?? "no answer (check the key)"
        }

        // Deliberately ask Jev directly rather than through routeRequest: that
        // method answers from local keyword rules whenever it can, so timing it
        // measures the shortcut, not the model.
        for i in 1...3 {
            await time("Jev", "one small question (warm, run \(i))", usd: spentSince) {
                let a = await jev.ask("bench_small", state: ["userRequest": "the thing I was working on this afternoon"], questions: [
                    ("kind", .choice("What kind of work is this?", [("files", "Something about files on disk."), ("apps", "Something about applications on this Mac."), ("web", "Something on a website.")]))
                ])
                return a.map { "chose \"\($0["kind"]?.choice ?? "")\"" } ?? "no answer"
            }
        }

        await time("Jev", "route a request (local rules may answer)", usd: spentSince) {
            let r = await jev.routeRequest("find the ethernet frames pdf I downloaded last week", hasDroppedPaths: false)
            return "chose \"\(r.route.rawValue)\": \(r.reason)"
        }

        // The ranking call a natural-language search would actually make.
        let candidates = ((try? await benchFind(["-onlyin", Path.join(Path.home, "Downloads"), "kind:pdf"])) ?? []).prefix(40).map { $0.jsSplit("/").last ?? $0 }
        if !candidates.isEmpty {
            // A rubric, not a bare number: Jev scores against described levels.
            let rubric: [String?] = [
                "Nothing about this file matches the request.", "Only loosely related.", "Plausibly the file, but not clearly.",
                "Very likely the file the user means.", "Certainly the file the user means."
            ]
            let questions = candidates.enumerated().map { ("c\($0.offset)", JevQuestion.score("How well does \"\($0.element)\" match what the user asked for?", rubric)) }
            await time("Jev", "rank \(candidates.count) real candidates, one call", usd: spentSince) {
                guard let a = await jev.ask("bench_rank", state: ["userRequest": "the pdf about ethernet frames from last week", "candidates": JSON(Array(candidates))], questions: questions) else { return "no answer" }
                let top = candidates.enumerated().map { (n: $0.element, s: a["c\($0.offset)"]?.score ?? 0) }.ecmaSorted { $0.s > $1.s }.prefix(2)
                return "best: \(top.map { "\($0.n) (\(JSON.format($0.s)))" }.joined(separator: ", "))"
            }
        }
    }

    // ---- The index macOS already maintains ----
    let home = Path.home
    await time("macOS index", "whole home, by content") { "\(try await benchFind(["-onlyin", home, "ethernet"]).count) hits" }
    await time("macOS index", "Downloads, kind:pdf") { "\(try await benchFind(["-onlyin", Path.join(home, "Downloads"), "kind:pdf"]).count) hits" }
    await time("macOS index", "Downloads, modified this week") {
        "\(try await benchFind(["-onlyin", Path.join(home, "Downloads"), "kMDItemContentModificationDate >= $time.today(-7)"]).count) hits"
    }
    await time("macOS index", "every installed application") { "\(try await benchFind(["kMDItemContentType == \"com.apple.application-bundle\""]).count) apps" }

    // ---- No model at all ----
    await time("local", "arithmetic, parsed and evaluated") {
        evaluateArithmetic("18% of 4250 + 12*3").map { "= \(JSON.format($0))" } ?? "could not parse"
    }
    await time("local", "match an app name by prefix") {
        let apps = try await benchFind(["kMDItemContentType == \"com.apple.application-bundle\""])
        let hit = apps.first { ($0.jsSplit("/").last ?? "").lowercased().hasPrefix("saf") }
        return hit.map { "\"saf\" → \($0.jsSplit("/").last ?? "")" } ?? "no match"
    }
    return rows
}

private func benchFind(_ args: [String]) async throws -> [String] {
    try await Exec.checked("/usr/bin/mdfind", args, timeoutMs: 30_000, maxBytes: 32 * 1024 * 1024).jsSplit("\n").filter { !$0.isEmpty }
}
