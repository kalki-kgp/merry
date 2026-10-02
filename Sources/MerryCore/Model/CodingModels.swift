import Foundation

private let DISCOVERY_TIMEOUT = 15_000

/// Metadata only. Opening a picker never generates tokens or changes a person's CLI settings.
public func codingModels(_ app: CodingApp, refresh: Bool = false) async throws -> CodingModelCatalog {
    let dir = scratchFolder("merry-models-")
    defer { try? FileManager.default.removeItem(atPath: dir) }
    if app == .claudeCode { return try await discoverClaudeModels(try resolveBin(), dir) }
    if app == .codex { return try await discoverCodexCatalog(try resolveCodex(), dir) }
    var refreshFailed = false
    if refresh {
        do { _ = try await runOnce(try resolveOpenCode(), ["models", "--refresh", "--verbose"], cwd: dir, timeoutMs: DISCOVERY_TIMEOUT, label: "OpenCode model refresh") }
        catch { refreshFailed = true }
    }
    do {
        var catalog = try await discoverOpenCodeModels(try resolveOpenCode(), dir)
        if refreshFailed { catalog.note = "Couldn’t refresh OpenCode’s online catalog. Showing its locally known models. " + catalog.note }
        return catalog
    } catch {
        // Older OpenCode versions may not provide the server metadata endpoints.
        let output = try await runOnce(try resolveOpenCode(), ["models", "--verbose"], cwd: dir, timeoutMs: DISCOVERY_TIMEOUT, label: "OpenCode model list")
        return CodingModelCatalog(models: parseOpenCodeModels(output), note: "Your OpenCode version lists models without connection details. Check a model before using it. Update OpenCode for provider recommendations.", connection: "OpenCode · connection details unavailable")
    }
}

// MARK: - Reading what a CLI reports

/// The shape checks zod made in the reference: a value of the wrong type is an error, not a default.
private struct ShapeError: Error {}

private enum Shape {
    static func object(_ value: JSON?) throws -> JSON {
        guard let value, value.objectValue != nil else { throw ShapeError() }
        return value
    }

    static func array(_ value: JSON?) throws -> [JSON] {
        guard let items = value?.arrayValue else { throw ShapeError() }
        return items
    }

    static func string(_ value: JSON?) throws -> String {
        guard let text = value?.stringValue else { throw ShapeError() }
        return text
    }

    static func optString(_ value: JSON?, nullable: Bool = false) throws -> String? {
        guard let value else { return nil }
        if nullable, value.isNull { return nil }
        return try string(value)
    }

    static func optBool(_ value: JSON?) throws -> Bool? {
        guard let value else { return nil }
        guard let flag = value.boolValue else { throw ShapeError() }
        return flag
    }

    static func number(_ value: JSON?) throws -> Double {
        guard let n = value?.doubleValue else { throw ShapeError() }
        return n
    }

    static func modelId(_ value: JSON?) throws -> String {
        let id = try string(value)
        guard !id.isEmpty, validModelId(id) else { throw ShapeError() }
        return id
    }

    /// `{ input: number, output: number }`, when present.
    static func optCost(_ value: JSON?) throws -> (input: Double, output: Double)? {
        guard let value else { return nil }
        let cost = try object(value)
        return (try number(cost["input"]), try number(cost["output"]))
    }
}

/// `validCodingModel`, with JavaScript's `$`: the end of the text and nowhere else.
func validModelId(_ value: String) -> Bool {
    if let last = value.unicodeScalars.last, CharacterSet.newlines.contains(last) { return false }
    return validCodingModel(value)
}

/// An object's own keys in JavaScript's order: whole numbers first, ascending, then the rest as written.
func jsKeys(_ object: JSONObject) -> [String] {
    var numeric: [(UInt32, String)] = []
    var rest: [String] = []
    for key in object.keys {
        if let n = UInt32(key), n < UInt32.max, String(n) == key { numeric.append((n, key)) } else { rest.append(key) }
    }
    return numeric.sorted { $0.0 < $1.0 }.map(\.1) + rest
}

private func safePlan(_ value: JSON?) -> String {
    // Never send emails, credentials or an arbitrary server object to the renderer.
    guard let text = value?.stringValue, Rx("^[a-zA-Z0-9 _-]{1,40}$").test(text), !text.hasSuffix("\n") else { return "plan not reported" }
    return text.replacingOccurrences(of: "_", with: " ")
}

/// Models kept in the order they were first listed, a later entry replacing an earlier one in place.
private struct ModelList {
    private(set) var models: [CodingModel] = []
    private var index: [String: Int] = [:]

    mutating func set(_ model: CodingModel) {
        if let at = index[model.id] { models[at] = model } else { index[model.id] = models.count; models.append(model) }
    }
}

/// One side of a JSONL conversation with a CLI: what to say first, and what
/// to say (or conclude) on each message that comes back.
protocol ModelListing: AnyObject {
    func open() -> [JSON]
    func receive(_ message: JSON) throws -> (send: [JSON], catalog: CodingModelCatalog?)
}

/// Codex's app-server protocol: initialize, read the account, read the
/// configured model, then page through the model list.
final class CodexListing: ModelListing {
    private var id = 1
    private var stage = "initialize"
    private var connection = "Codex · connection details unavailable"
    private var blocked = false
    private var defaultModel: String?
    private var models = ModelList()
    private var cursors = Set<String>()

    private func request(_ method: String, _ params: JSON) -> JSON {
        stage = method
        id += 1
        return ["method": .string(method), "id": .number(Double(id)), "params": params]
    }

    func open() -> [JSON] {
        [["method": "initialize", "id": .number(Double(id)), "params": ["clientInfo": ["name": "merry", "title": "Merry", "version": "0.1.0"]]]]
    }

    func receive(_ message: JSON) throws -> (send: [JSON], catalog: CodingModelCatalog?) {
        if message.isNull { throw ShapeError() }
        guard message["id"]?.doubleValue == Double(id) else { return ([], nil) }
        let failed = message["error"]?.jsTruthy == true
        if stage == "initialize" {
            if failed { throw ShapeError() }
            return ([["method": "initialized", "params": [:]], request("account/read", ["refreshToken": false])], nil)
        }
        if stage == "account/read" {
            let result = message["result"]
            let account = result?["account"]
            blocked = !failed && result?["requiresOpenaiAuth"]?.boolValue == true && account?.isNull == true
            if blocked {
                connection = "Codex · sign-in required"
            } else if account?["type"]?.stringValue == "chatgpt" {
                connection = "ChatGPT · \(safePlan(account?["planType"]))"
            } else if account?["type"]?.stringValue == "apiKey" {
                connection = "Codex · API billing"
            } else if result?["requiresOpenaiAuth"]?.boolValue == false {
                connection = "Codex · configured provider"
            }
            return ([request("config/read", ["includeLayers": false])], nil)
        }
        if stage == "config/read" {
            if let value = message["result"]?["config"]?["model"]?.stringValue, validModelId(value) { defaultModel = value }
            return ([request("model/list", ["limit": 100])], nil)
        }
        if failed { throw ShapeError() }
        let page = try Shape.object(message["result"])
        let entries = try Shape.array(page["data"]).map { entry -> (model: String, displayName: String?, description: String?, isDefault: Bool?, hidden: Bool?) in
            let entry = try Shape.object(entry)
            return (try Shape.modelId(entry["model"]), try Shape.optString(entry["displayName"]), try Shape.optString(entry["description"]), try Shape.optBool(entry["isDefault"]), try Shape.optBool(entry["hidden"]))
        }
        let nextCursor = try Shape.optString(page["nextCursor"], nullable: true)
        for entry in entries where entry.hidden != true {
            var model = CodingModel(id: entry.model, label: entry.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? entry.model)
            model.description = entry.description
            model.recommended = blocked ? false : entry.isDefault
            model.recommendation = entry.isDefault == true ? "Codex recommends this model for your connection." : nil
            model.access = blocked ? "unavailable" : "listed"
            model.reason = blocked ? "Sign in to Codex, then refresh models." : nil
            models.set(model)
        }
        guard let nextCursor, !nextCursor.isEmpty else {
            return ([], CodingModelCatalog(models: models.models, note: "Models come from your Codex connection. Plan access and remaining quota are checked when you use a model; a listed model is not a guarantee of access.", connection: connection, defaultModel: defaultModel))
        }
        if cursors.contains(nextCursor) || cursors.count >= 20 { throw ShapeError() }
        cursors.insert(nextCursor)
        return ([request("model/list", ["limit": 100, "cursor": .string(nextCursor)])], nil)
    }
}

/// Claude Code's control protocol: one initialize request, whose answer
/// carries the models and the account.
final class ClaudeListing: ModelListing {
    private let requestId: String
    private let environment: [String: String]

    init(requestId: String = newId(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.requestId = requestId
        self.environment = environment
    }

    func open() -> [JSON] {
        [["type": "control_request", "request_id": .string(requestId), "request": ["subtype": "initialize", "hooks": [:]]]]
    }

    func receive(_ message: JSON) throws -> (send: [JSON], catalog: CodingModelCatalog?) {
        if message.isNull { throw ShapeError() }
        guard message["type"]?.stringValue == "control_response", message["response"]?["request_id"]?.stringValue == requestId else { return ([], nil) }
        let response = message["response"] ?? .null
        if response["subtype"]?.stringValue != "success" { throw ShapeError() }
        let result = try Shape.object(response["response"])
        let listed = try Shape.array(result["models"]).map { entry -> (value: String, displayName: String, description: String?, resolvedModel: String?) in
            let entry = try Shape.object(entry)
            return (try Shape.modelId(entry["value"]), try Shape.string(entry["displayName"]), try Shape.optString(entry["description"]), try Shape.optString(entry["resolvedModel"]))
        }
        var subscriptionType: String?, tokenSource: String?, apiKeySource: String?
        if let account = result["account"] {
            let account = try Shape.object(account)
            subscriptionType = try Shape.optString(account["subscriptionType"], nullable: true)
            tokenSource = try Shape.optString(account["tokenSource"])
            apiKeySource = try Shape.optString(account["apiKeySource"], nullable: true)
        }
        func set(_ name: String) -> Bool { !(environment[name] ?? "").isEmpty }
        let blocked = tokenSource == "none" && (apiKeySource ?? "").isEmpty || tokenSource == "none" && apiKeySource == "none"
        let signedOut = blocked && !set("CLAUDE_CODE_USE_BEDROCK") && !set("CLAUDE_CODE_USE_VERTEX") && !set("CLAUDE_CODE_USE_FOUNDRY")
        let models = listed.map { entry -> CodingModel in
            var model = CodingModel(id: entry.value, label: entry.displayName)
            model.description = entry.description
            model.resolvedModel = entry.resolvedModel
            model.recommended = !signedOut && entry.value == "default"
            model.recommendation = entry.value == "default" ? "Claude Code recommends this model for your connection." : nil
            model.access = signedOut ? "unavailable" : "listed"
            model.reason = signedOut ? "Sign in to Claude Code or connect a provider, then refresh models." : nil
            return model
        }
        let connection = signedOut ? "Claude Code · sign-in required"
            : (subscriptionType ?? "").isEmpty ? "Claude Code · configured connection" : "Claude · \(safePlan(subscriptionType.map(JSON.string)))"
        return ([], CodingModelCatalog(
            models: models,
            note: "Models are reported by your installed Claude Code. Check access before selecting. Merry uses your chosen model for answers and tasks.",
            connection: connection,
            defaultModel: models.first { $0.id == "default" }?.resolvedModel
        ))
    }
}

/// Bounded JSONL RPC transport shared by the two CLI control protocols.
private final class JsonLines: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private let listing: ModelListing
    private var continuation: CheckedContinuation<CodingModelCatalog, Error>?
    private var settled = false
    private var child: CliProcess?
    private var timer: DispatchWorkItem?
    private var buffer = Data()

    init(label: String, listing: ModelListing) {
        self.label = label
        self.listing = listing
    }

    private func finish(_ result: Result<CodingModelCatalog, Error>) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true
        let waiting = continuation
        continuation = nil
        timer?.cancel()
        let running = child
        lock.unlock()
        running?.end()
        running?.kill()
        waiting?.resume(with: result)
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func send(_ values: [JSON]) {
        guard let child = lock.withLock({ settled ? nil : child }) else { return }
        for value in values { child.write(value.stringify() + "\n") }
    }

    func start(bin: String, args: [String], cwd: String, timeoutMs: Int, _ continuation: CheckedContinuation<CodingModelCatalog, Error>) {
        lock.withLock { self.continuation = continuation }
        let child: CliProcess
        do {
            child = try CliProcess(
                bin: bin, args: args, cwd: cwd, env: Exec.environment(),
                onStdout: { [self] data in read(data) },
                onStderr: { _ in },
                onClose: { [self] _ in finish(.failure(MerryError("\(label) stopped before listing models. Update it or enter a model ID."))) }
            )
        } catch {
            finish(.failure(MerryError("Couldn’t start \(label). Check its installation.")))
            return
        }
        let work = DispatchWorkItem { [self] in finish(.failure(MerryError("\(label) took too long to list models. Try Refresh or enter a model ID."))) }
        let already: Bool = lock.withLock {
            self.child = child
            timer = work
            return settled
        }
        if already { child.end(); child.kill(); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: work)
        send(listing.open())
    }

    /// Runs on the child's event queue, one chunk at a time.
    private func read(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.hasSuffix("\r") { line.removeLast() }
            if lock.withLock({ settled }) { return }
            guard let message = strictJSON(line) else { continue } // Ignore older CLIs' startup messages.
            do {
                let step = try listing.receive(message)
                if let catalog = step.catalog { finish(.success(catalog)); return }
                send(step.send)
            } catch {
                finish(.failure(MerryError("Couldn’t read \(label) models. Check your login or update the app.")))
                return
            }
        }
    }
}

private func jsonLines(_ bin: String, _ args: [String], _ cwd: String, _ label: String, _ listing: ModelListing, _ timeoutMs: Int) async throws -> CodingModelCatalog {
    let run = JsonLines(label: label, listing: listing)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            run.start(bin: bin, args: args, cwd: cwd, timeoutMs: timeoutMs, continuation)
        }
    } onCancel: {
        run.cancel()
    }
}

public func discoverCodexModels(_ bin: String, _ cwd: String, timeoutMs: Int = 15_000) async throws -> [CodingModel] {
    try await discoverCodexCatalog(bin, cwd, timeoutMs: timeoutMs).models
}

public func discoverCodexCatalog(_ bin: String, _ cwd: String, timeoutMs: Int = 15_000) async throws -> CodingModelCatalog {
    try await jsonLines(bin, ["app-server"], cwd, "Codex", CodexListing(), timeoutMs)
}

let claudeDiscoveryArgs = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence"]

public func discoverClaudeModels(_ bin: String, _ cwd: String, timeoutMs: Int = 15_000) async throws -> CodingModelCatalog {
    try await jsonLines(bin, claudeDiscoveryArgs, cwd, "Claude Code", ClaudeListing(), timeoutMs)
}

// MARK: - OpenCode

/// Connected providers and defaults are read from OpenCode, never from raw credential files.
public func parseOpenCodeProviders(_ value: JSON, _ configuredModel: String? = nil) throws -> CodingModelCatalog {
    let catalog = try Shape.object(value)
    struct Entry { var key: String; var id: String; var name: String?; var status: String?; var cost: (input: Double, output: Double)?; var textIn: Bool?; var textOut: Bool? }
    struct Provider { var id: String; var name: String?; var models: [Entry] }
    let providers = try Shape.array(catalog["all"]).map { item -> Provider in
        let item = try Shape.object(item)
        let listed = try Shape.object(item["models"])
        let entries = try jsKeys(listed.objectValue!).map { key -> Entry in
            let model = try Shape.object(listed[key])
            _ = try Shape.optString(model["release_date"])
            var textIn: Bool?, textOut: Bool?
            if let capabilities = model["capabilities"] {
                let capabilities = try Shape.object(capabilities)
                if let input = capabilities["input"] { textIn = try Shape.optBool(try Shape.object(input)["text"]) }
                if let output = capabilities["output"] { textOut = try Shape.optBool(try Shape.object(output)["text"]) }
            }
            return Entry(key: key, id: try Shape.string(model["id"]), name: try Shape.optString(model["name"]), status: try Shape.optString(model["status"]), cost: try Shape.optCost(model["cost"]), textIn: textIn, textOut: textOut)
        }
        return Provider(id: try Shape.string(item["id"]), name: try Shape.optString(item["name"]), models: entries)
    }
    let connectedIds = try Shape.array(catalog["connected"]).map { try Shape.string($0) }
    var defaultByProvider: [String: String] = [:]
    if let defaults = catalog["default"] {
        let defaults = try Shape.object(defaults)
        for key in defaults.objectValue!.keys { defaultByProvider[key] = try Shape.string(defaults[key]) }
    }
    func named(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }

    var models: [CodingModel] = []
    for provider in providers {
        for entry in provider.models {
            let id = "\(provider.id)/\(named(entry.id) ?? entry.key)"
            if !validModelId(id) { continue }
            let connected = connectedIds.contains(provider.id)
            let unsupported = entry.textIn == false || entry.textOut == false || entry.status == "deprecated"
            let providerName = named(provider.name) ?? provider.id
            var model = CodingModel(id: id, label: "\(named(entry.name) ?? entry.id) · \(providerName)")
            model.description = id
            model.free = entry.cost.map { $0.input == 0 && $0.output == 0 }
            model.access = !connected || unsupported ? "unavailable" : "listed"
            model.reason = !connected ? "Connect \(providerName) in OpenCode, then refresh." : unsupported ? "This model is retired or does not accept text." : nil
            models.append(model)
        }
    }
    // Honor a configured model. Otherwise prefer a free provider default, then a connected provider default.
    let eligible = models.indices.filter { models[$0].access != "unavailable" }
    let defaults = eligible.filter { i in
        let id = models[i].id
        return defaultByProvider[id.jsSplit("/")[0]] == id.jsSlice(id.jsIndexOf("/") + 1)
    }
    let recommended = eligible.first { models[$0].id == configuredModel }
        ?? defaults.first { models[$0].free == true }
        ?? eligible.first { models[$0].free == true }
        ?? defaults.first
    if let i = recommended {
        models[i].recommended = true
        models[i].recommendation = models[i].id == configuredModel ? "Your configured OpenCode model."
            : models[i].free == true ? "A model from a connected provider with reported free pricing."
            : "A default model from a connected provider. Provider charges may apply."
    }
    func rank(_ flag: Bool) -> Int { flag ? 1 : 0 }
    let sorted = models.enumerated().sorted { a, b in
        let byRecommended = rank(b.element.recommended == true) - rank(a.element.recommended == true)
        if byRecommended != 0 { return byRecommended < 0 }
        let byAccess = rank(a.element.access == "unavailable") - rank(b.element.access == "unavailable")
        if byAccess != 0 { return byAccess < 0 }
        let byLabel = localeCompare(a.element.label, b.element.label)
        if byLabel != .orderedSame { return byLabel == .orderedAscending }
        return a.offset < b.offset
    }.map(\.element)
    let count = connectedIds.count
    return CodingModelCatalog(
        models: sorted,
        note: "Unconnected providers are grayed out. Connected models still need an access check: subscriptions, credits and quotas vary. Free means the catalog reports zero input and output prices; provider limits still apply.",
        connection: count > 0 ? "OpenCode · \(count) connected provider\(count == 1 ? "" : "s")" : "OpenCode · no connected providers",
        defaultModel: configuredModel
    )
}

/// `a.localeCompare(b)`: dictionary order, not code-point order.
private func localeCompare(_ a: String, _ b: String) -> ComparisonResult {
    a.compare(b, options: [], range: nil, locale: Locale(identifier: "en_US"))
}

public func discoverOpenCodeModels(_ bin: String, _ cwd: String, timeoutMs: Int = 15_000) async throws -> CodingModelCatalog {
    // Use a private, authenticated local server with an OS-assigned port. It is closed after metadata is read.
    let password = newId()
    let config: JSON = ["permission": ["*": "deny"]]
    try config.stringify().write(toFile: Path.join(cwd, "opencode.json"), atomically: true, encoding: .utf8)
    let run = OpenCodeDiscovery(cwd: cwd, password: password)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            run.start(bin: bin, timeoutMs: timeoutMs, continuation)
        }
    } onCancel: {
        run.cancel()
    }
}

private final class OpenCodeDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private let cwd: String
    private let password: String
    private var continuation: CheckedContinuation<CodingModelCatalog, Error>?
    private var settled = false
    private var reading = false
    private var child: CliProcess?
    private var timer: DispatchWorkItem?
    private var fetch: Task<Void, Never>?
    private var buffer = Data()

    init(cwd: String, password: String) {
        self.cwd = cwd
        self.password = password
    }

    private func finish(_ result: Result<CodingModelCatalog, Error>) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true
        let waiting = continuation
        continuation = nil
        timer?.cancel()
        let running = child
        let fetching = fetch
        lock.unlock()
        fetching?.cancel()
        running?.kill()
        waiting?.resume(with: result)
    }

    func cancel() { finish(.failure(CancellationError())) }

    func start(bin: String, timeoutMs: Int, _ continuation: CheckedContinuation<CodingModelCatalog, Error>) {
        lock.withLock { self.continuation = continuation }
        let child: CliProcess
        do {
            child = try CliProcess(
                bin: bin, args: ["serve", "--hostname", "127.0.0.1", "--port", "0"], cwd: cwd,
                env: Exec.environment(adding: ["OPENCODE_SERVER_USERNAME": "merry", "OPENCODE_SERVER_PASSWORD": password]),
                onStdout: { [self] data in read(data) },
                onStderr: { _ in },
                onClose: { [self] _ in finish(.failure(MerryError("OpenCode stopped before listing models."))) }
            )
        } catch {
            finish(.failure(MerryError("Couldn’t start OpenCode.")))
            return
        }
        child.end()
        let work = DispatchWorkItem { [self] in finish(.failure(MerryError("OpenCode model discovery timed out."))) }
        let already: Bool = lock.withLock {
            self.child = child
            timer = work
            return settled
        }
        if already { child.kill(); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: work)
    }

    private func read(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let match = Rx("opencode server listening on http:\\/\\/127\\.0\\.0\\.1:(\\d+)").exec(line) else { continue }
            if lock.withLock({ reading || settled }) { continue }
            lock.withLock { reading = true }
            guard let port = Int(match[1] ?? ""), port >= 1, port <= 65535 else {
                finish(.failure(MerryError("Invalid local port.")))
                return
            }
            let task = Task { [self] in
                do {
                    async let providers = get(port, "/provider")
                    async let config = try? get(port, "/config")
                    let (listed, settings) = (try await providers, await config)
                    let configured = settings?["model"]?.stringValue.flatMap { validModelId($0) ? $0 : nil }
                    finish(.success(try parseOpenCodeProviders(listed, configured)))
                } catch {
                    finish(.failure(MerryError("Couldn’t read OpenCode providers.")))
                }
            }
            lock.withLock { fetch = task }
        }
    }

    private func get(_ port: Int, _ path: String) async throws -> JSON {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw MerryError("OpenCode metadata unavailable") }
        var request = URLRequest(url: url)
        request.setValue("Basic \(Data("merry:\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.setValue(cwd, forHTTPHeaderField: "x-opencode-directory")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw MerryError("OpenCode metadata unavailable") }
        return try JSON.parse(data)
    }
}

/// A redirect is an error here: the server is local and has no business sending one.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Fallback for older OpenCode CLIs: unknown prices and access remain unknown.
public func parseOpenCodeModels(_ output: String) -> [CodingModel] {
    var models = ModelList()
    var id = ""
    var metadata: [String] = []
    func flush() {
        if id.isEmpty { return }
        var model = CodingModel(id: id, label: id)
        model.access = "listed"
        // Keep IDs from older CLIs selectable.
        if let parsed = strictJSON(metadata.joined(separator: "\n")), parsed.objectValue != nil {
            do {
                let name = try Shape.optString(parsed["name"])
                let cost = try Shape.optCost(parsed["cost"])
                model.label = (name ?? "").isEmpty ? id : "\(name!) · \(id)"
                model.free = cost.map { $0.input == 0 && $0.output == 0 }
            } catch {}
        }
        models.set(model)
    }
    for line in Rx("\\r?\\n").split(Rx("\\u001b\\[[0-9;]*m").replaceAll(output, "")) {
        let value = line.jsTrimmed
        if validModelId(value), value.contains("/"), !value.hasPrefix("/"), !value.hasSuffix("/") {
            flush(); id = value; metadata = []
        } else if !id.isEmpty {
            metadata.append(line)
        }
    }
    flush()
    return models.models
}
