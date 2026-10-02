import Foundation

private let PROMPT = "Do not use any tools. Reply with exactly MERRY_OK and nothing else."
private let TIMEOUT = 30_000

/// What JavaScript says when a property is read off `null`; the check turns it into its generic failure.
private let NULL_READ = "Cannot read properties of null"

func claudeCheckArgs(_ model: String) -> [String] {
    ["-p", "--output-format", "json", "--model", model, "--tools", "", "--allowed-tools", "", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence", "--max-turns", "1", "--system-prompt", "Answer the model connection check only."]
}

func codexCheckArgs(_ model: String, out: String) -> [String] {
    ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "-m", model, "-o", out, "-"]
}

func openCodeCheckArgs(_ model: String) -> [String] {
    ["run", "--format", "json", "-m", model, PROMPT]
}

/// Only called by an explicit Check & use click. One short reply may consume quota or incur provider charges.
public func checkCodingModel(_ app: CodingApp, _ model: String) async -> CodingModelCheck {
    if model.isEmpty || !validModelId(model) { return CodingModelCheck(ok: false, message: "Enter a valid model ID.") }
    if app == .opencode && (!model.contains("/") || model.hasPrefix("/") || model.hasSuffix("/")) {
        return CodingModelCheck(ok: false, message: "OpenCode needs a provider/model ID, for example provider/model-name.")
    }
    let dir = scratchFolder("merry-model-check-")
    defer { try? FileManager.default.removeItem(atPath: dir) }
    do {
        if app == .claudeCode {
            let bin = try resolveBin()
            let catalog = try? await discoverClaudeModels(bin, dir)
            let entry = catalog?.models.first { $0.id == model }
            if let entry, entry.access == "unavailable" { return CodingModelCheck(ok: false, message: entry.reason ?? "", unavailable: true) }
            let output = try await runOnce(bin, claudeCheckArgs(model), cwd: dir, input: PROMPT, timeoutMs: TIMEOUT, label: "Claude Code model check")
            return parseClaudeCheck(output, model, entry?.resolvedModel)
        }
        if app == .codex {
            let out = Path.join(dir, "reply.txt")
            let output = try await runOnce(try resolveCodex(), codexCheckArgs(model, out: out), cwd: dir, input: PROMPT, timeoutMs: TIMEOUT, label: "Codex model check")
            for event in jsonEvents(output) {
                if event.isNull { return modelCheckFailure(NULL_READ) }
                let type = event["type"]?.stringValue
                if type == "error" || type == "turn.failed" { return modelCheckFailure(event.stringify()) }
            }
            // Missing replies are not success.
            let text = FileManager.default.contents(atPath: out).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return checkedReply(text, model)
        }
        let config: JSON = ["permission": ["*": "deny"]]
        try config.stringify().write(toFile: Path.join(dir, "opencode.json"), atomically: true, encoding: .utf8)
        let output = try await runOnce(try resolveOpenCode(), openCodeCheckArgs(model), cwd: dir, timeoutMs: TIMEOUT, label: "OpenCode model check")
        return parseOpenCodeCheck(output, model)
    } catch {
        return modelCheckFailure(messageOf(error))
    }
}

private func jsonEvents(_ output: String) -> [JSON] {
    Rx("\\r?\\n").split(output).compactMap { strictJSON($0) }
}

private func checkedReply(_ text: String, _ model: String) -> CodingModelCheck {
    text.jsTrimmed == "MERRY_OK"
        ? CodingModelCheck(ok: true, message: "Access checked. This model is ready to use.", resolvedModel: model)
        : CodingModelCheck(ok: false, message: "The model did not complete the connection check. Try again or choose another model.")
}

public func parseClaudeCheck(_ output: String, _ requested: String, _ expected: String? = nil) -> CodingModelCheck {
    guard let result = strictJSON(output) else {
        return CodingModelCheck(ok: false, message: "Couldn’t read the model check. Update Claude Code or try again.")
    }
    if result.isNull { return modelCheckFailure(NULL_READ) }
    if result["is_error"]?.jsTruthy == true {
        let said = JSON.truthy(result["result"])?.jsString ?? ""
        let errors = JSON.truthy(result["errors"]) ?? .array([])
        return modelCheckFailure("\(said) \(errors.stringify())")
    }
    let models: [String]
    switch result["modelUsage"] {
    case .object(let usage)?: models = jsKeys(usage)
    case .array(let items)?: models = items.indices.map(String.init)
    case .string(let text)?: models = (0..<text.jsLength).map(String.init)
    default: models = []
    }
    func normalized(_ id: String) -> String { id.hasSuffix("[1m]") ? String(id.dropLast(4)) : id }
    // Managed policies can substitute a denied --model. Do not silently save a model that never answered.
    let expected = expected.flatMap { $0.isEmpty ? nil : $0 }
    let target = normalized(expected ?? requested)
    let actual = models.first { id in
        normalized(id) == target
            || (expected == nil && ["sonnet", "opus", "haiku"].contains(requested) && id.hasPrefix("claude-\(requested)-"))
            || (expected == nil && requested == "default")
    }
    guard let actual else {
        return CodingModelCheck(
            ok: false,
            message: models.isEmpty ? "Claude Code did not report which model answered. Update Claude Code and try again."
                : "Claude Code answered with a different model. Your account or administrator may restrict this choice. Refresh models and choose an allowed model.",
            unavailable: !models.isEmpty
        )
    }
    return checkedReply(JSON.truthy(result["result"])?.jsString ?? "", actual)
}

public func parseOpenCodeCheck(_ output: String, _ model: String) -> CodingModelCheck {
    let events = jsonEvents(output)
    for event in events {
        if event.isNull { return modelCheckFailure(NULL_READ) }
        if event["type"]?.stringValue == "error" {
            return modelCheckFailure((JSON.truthy(event["error"]) ?? event).stringify())
        }
    }
    let text = events.filter { $0["type"]?.stringValue == "text" }
        .map { event in JSON.truthy(event["part"]?["text"])?.jsString ?? "" }
        .joined()
    return checkedReply(text, model)
}

/// Return actionable, credential-free messages, not raw CLI errors (which may contain keys or paths).
public func modelCheckFailure(_ error: String) -> CodingModelCheck {
    if Rx("quota|rate.?limit|usage.?limit|insufficient.?credit|insufficient_quota|limit.?reached|credit.?balance", "i").test(error) {
        return CodingModelCheck(ok: false, message: "Usage limits or credits are exhausted for this connection. Wait for a reset or update your provider account, then refresh models.", unavailable: true)
    }
    if Rx("401|unauthorized|authentication|not.?logged|sign.?in|log.?in|login|api.?key.*(?:missing|invalid)|no.*credentials", "i").test(error) {
        return CodingModelCheck(ok: false, message: "Sign in or reconnect this provider in your coding app, then refresh models.", unavailable: true)
    }
    if Rx("403|404|not.?found|not.?supported|unsupported|does.?not.?exist|not.?available|unavailable|not.*access|access.*denied|permission.?denied|not.*plan|upgrade.*plan|requires.*(?:pro|plus|paid|subscription)|modelnotfound", "i").test(error) {
        return CodingModelCheck(ok: false, message: "This model is unavailable for your connection or plan. Choose another model, or update access in your coding app and refresh.", unavailable: true)
    }
    if Rx("find|ENOENT|install", "i").test(error) {
        return CodingModelCheck(ok: false, message: "The coding app could not be started. Check its installation, then retry.")
    }
    if Rx("too.?long|longer.?than|timeout|timed.?out", "i").test(error) {
        return CodingModelCheck(ok: false, message: "The access check timed out. Check your connection and retry.")
    }
    return CodingModelCheck(ok: false, message: "Couldn’t check model access. Check your connection and provider setup, then retry. Your previous model is still selected.")
}
