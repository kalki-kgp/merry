import Foundation

// "Remember that my manager is Priya", "forget that", "what do you remember
// about me": handled in code, instantly, with no planning model. The person
// should never need a settings screen to know or change what Merry keeps.

private let allRoutes = ["files", "desktop", "browser", "apps", "mixed", "unclear"]
private let forget = Rx("^\\s*(?:please |merry[, ]+)*(?:forget|stop remembering|delete the memory|unlearn)\\b\\s*(?:that |about |what you know about |everything you know about )?(.*)$", "i")
private let forgetAll = Rx("^\\s*(?:please |merry[, ]+)*(?:forget everything|clear (?:your |all )?memor(?:y|ies)|wipe (?:your )?memory|forget all (?:of )?(?:it|that|about me))\\b", "i")
private let asking = Rx("\\bwhat (?:do|did) you (?:remember|know|learn(?:ed)?)(?: about)?\\s*(.*?)\\??$|\\bwhat have you learned\\b|\\bshow (?:me )?(?:your )?memor(?:y|ies)\\b", "i")

private func bullets(_ memories: [Memory]) -> String { memories.map { "• \($0.text)" }.joined(separator: "\n") }

public let memoryWorkflow = Workflow(
    id: "memory",
    description: "Remember something the user says about themselves, forget something, or say what is remembered.",
    routes: allRoutes,
    plausible: { request, _ in
        forgetAll.test(request) || asking.test(request) || explicitMemory(request) != nil || (forget.test(request) && !Rx("^\\s*forget it\\s*$", "i").test(request))
    },
    run: { request, _, ctx in
        let mem = ctx.memory
        if !mem.enabled {
            return WorkflowResult(success: false, headline: "Memory is off, so I'm not keeping anything. You can turn it on in Settings.")
        }

        if forgetAll.test(request) {
            let all = mem.all()
            if all.isEmpty { return WorkflowResult(success: true, headline: "There's nothing to forget. I don't remember anything yet.") }
            let answer = try await ctx.askUser(QuestionDraft(
                reason: .authorization,
                prompt: "Forget all \(all.count) things I remember about you? This can't be undone.",
                allowFreeText: false,
                options: [QuestionOption(id: "yes", label: "Forget everything"), QuestionOption(id: "no", label: "Keep them")]
            ))
            if answer.optionId != "yes" { return WorkflowResult(success: true, headline: "Kept everything.") }
            mem.forget(all.map(\.id))
            return WorkflowResult(success: true, headline: "Done. I've forgotten all \(all.count).")
        }

        if let asked = asking.exec(request) {
            let about = Rx("^(?:me|myself)\\b", "i").replaceFirst(asked[1] ?? "", "").jsTrimmed
            let all = mem.all().ecmaSorted { a, b in a.uses != b.uses ? a.uses > b.uses : a.updatedAt > b.updatedAt }
            let shown = about.isEmpty ? all : all.filter { lexicalScore(about, $0) > 0 }
            if shown.isEmpty {
                return WorkflowResult(success: true, headline: about.isEmpty
                    ? "I don't remember anything about you yet. Tell me with \"remember that …\"."
                    : "I don't remember anything about \(about).")
            }
            let told = shown.filter { $0.source == "told" }
            let learned = shown.filter { $0.source == "learned" }
            var evidence: [Evidence] = []
            if !told.isEmpty { evidence.append(.text("You told me", bullets(Array(told.prefix(30))))) }
            if !learned.isEmpty { evidence.append(.text("I picked up", bullets(Array(learned.prefix(30))))) }
            return WorkflowResult(
                success: true,
                headline: "I remember \(shown.count) \(plural(shown.count, "thing"))\(about.isEmpty ? "" : " about \(about)"). Say \"forget …\" to drop one.",
                evidence: evidence
            )
        }

        if let told = explicitMemory(request) {
            if let secret = looksSecret(told.text) {
                return WorkflowResult(success: false, headline: "I don't keep \(secret), even when asked. They're safer in your password manager.")
            }
            guard let kept = mem.keep(makeMemory(told.text, kind: told.kind, source: "told")) else {
                return WorkflowResult(success: false, headline: "I couldn't keep that one.")
            }
            return WorkflowResult(success: true, headline: "Got it. I'll remember that.", evidence: [.text("Remembered", kept.text)])
        }

        // Forget one thing: the closest match, or ask which when it is unclear.
        let what = (forget.exec(request)?[1] ?? "").jsTrimmed
        let candidates = mem.all().map { (m: $0, score: lexicalScore(what, $0)) }.filter { $0.score > 0 }.ecmaSorted { $0.score > $1.score }
        if candidates.isEmpty { return WorkflowResult(success: true, headline: "I don't remember anything about \(what.isEmpty ? "that" : what).") }
        var target: Memory? = candidates.count == 1 || Double(candidates[0].score) > Double(candidates[1].score) * 1.5 ? candidates[0].m : nil
        if target == nil {
            let top = Array(candidates.prefix(6))
            let options = top.enumerated().map { ("m\($0.offset)", $0.element.m.text) }
            let answers = await ctx.ask("pick_memory", ["request": .string(request)], [("which", .choice("Which remembered thing does the user want forgotten?", options))])
            if let pick = answers?["which"], let choice = pick.choice, (pick.confidence ?? 0) > 0.7, let index = Int(choice.dropFirst()), top.indices.contains(index) {
                target = top[index].m
            }
            if target == nil {
                let answer = try await ctx.askUser(QuestionDraft(
                    reason: .ambiguous,
                    prompt: "Which one should I forget?",
                    allowFreeText: false,
                    options: top.enumerated().map { QuestionOption(id: "m\($0.offset)", label: $0.element.m.text.jsSlice(0, 80)) } + [QuestionOption(id: "none", label: "None of these")]
                ))
                if let id = answer.optionId, id != "none", let index = Int(id.dropFirst()), top.indices.contains(index) { target = top[index].m }
            }
        }
        guard let target else { return WorkflowResult(success: true, headline: "Okay, I kept everything.") }
        mem.forget([target.id])
        return WorkflowResult(success: true, headline: "Forgotten.", evidence: [.text("No longer remembered", target.text)])
    }
)

/// Words a request is "about", minus the verbs that start it. Used to key learned choices.
func aboutWords(_ text: String) -> [String] {
    words(Rx("\\b(run|start|trigger|shortcut|please)\\b", "i").replaceAll(text, " "))
}
