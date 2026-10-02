import Testing
@testable import MerryCore

/// A scratch home folder laid out like the one the shell fixtures were recorded against.
private func makeHome() throws -> String {
    let fm = FileManager.default
    let made = Path.join(Path.tmp, "merry-shell-home-\(newId())")
    try fm.createDirectory(atPath: made, withIntermediateDirectories: true)
    let home = try NodeFS.realpath(made)
    try fm.createDirectory(atPath: "\(home)/bin", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: "\(home)/proj", withIntermediateDirectories: true)
    try Data("notes".utf8).write(to: URL(fileURLWithPath: "\(home)/notes.txt"))
    try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: "\(home)/bin/tool-x"))
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(home)/bin/tool-x")
    try Data("plain".utf8).write(to: URL(fileURLWithPath: "\(home)/bin/plain"))
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(home)/bin/plain")
    try fm.createSymbolicLink(atPath: "\(home)/bin/link-x", withDestinationPath: "\(home)/bin/tool-x")
    return home
}

private func scopeJSON(_ scope: ScopeRequest) -> JSON {
    switch scope {
    case .read(let path): return ["kind": "read", "path": .string(path)]
    case .write(let path): return ["kind": "write", "path": .string(path)]
    case .app(let name): return ["kind": "app", "name": .string(name)]
    case .origin(let url): return ["kind": "origin", "url": .string(url)]
    case .capability(let name): return ["kind": "capability", "name": .string(name)]
    }
}

private func context(_ auth: Authorization = Authorization()) -> ToolContext {
    let task = TaskState(request: "test", authorization: auth)
    return ToolContext(task: { task }, os: UnavailableOsAdapter(), browser: NoBrowser())
}

@Test func theCommandLineBoundaryMatchesTheOriginal() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let text = try String(contentsOf: Fixture.directory.appendingPathComponent("shell-cases.json"), encoding: .utf8)
    let fixture = try JSON.parse(text.replacingOccurrences(of: "$HOME", with: home))
    let cases = fixture.list("cases")
    #expect(cases.count >= 150)
    try Path.$scopedHome.withValue(home) {
        for row in cases {
            let label = "\(row.str("program")) \(row.strings("args")) cwd=\(row.optStr("cwd") ?? "-")"
            do {
                let vetted = try vetCommandBaseline(row.str("program"), row.strings("args"), row.optStr("cwd"))
                guard let expected = row["vetted"] else {
                    Issue.record("\(label): accepted, but the reference refuses with: \(row.str("refused"))")
                    continue
                }
                let got: JSON = [
                    "program": .string(vetted.program), "args": JSON(vetted.args), "mutates": .bool(vetted.mutates),
                    "runsCode": .bool(vetted.runsCode), "cwd": .string(vetted.cwd), "paths": JSON(vetted.paths)
                ]
                #expect(got.firstDifference(from: expected) == nil, "\(label): \(got.firstDifference(from: expected) ?? "")")
                let scopes = JSON.array(commandScopes(vetted).map(scopeJSON))
                #expect(scopes.firstDifference(from: row["scopes"] ?? .null) == nil, "\(label) scopes: \(scopes.firstDifference(from: row["scopes"] ?? .null) ?? "")")
            } catch let refusal as RefusedCommand {
                #expect(row.optStr("refused") == refusal.message, "\(label): refused with \"\(refusal.message)\", expected \(row.optStr("refused") ?? "to be accepted")")
            }
        }
        for row in fixture.list("launches") {
            #expect(wouldLaunch(row.str("path")) == row.flag("launches"), "wouldLaunch \(row.str("path"))")
        }
    }
}

@Test func shellRunRunsVettedCommandsAndNothingElse() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    try await Path.$scopedHome.withValue(home) {
        let ctx = context()
        // An ordinary command: scopes cover the folder it runs in, and it runs.
        let echo = try shellRun.input.parse(["program": "echo", "args": ["hello", "$(id)", "; ls"]])
        #expect(shellRun.scopes(echo) == [.read(path: home)])
        #expect(shellRun.confirm?(echo) == nil)
        let out = try await shellRun.execute(echo, ctx)
        #expect(out.result.str("stdout") == "hello $(id) ; ls\n")
        #expect(out.result.int("code") == 0)
        #expect(try await shellRun.verify?(echo, out, ctx) == VerificationResult(verified: true, method: "exit-code", detail: "echo exited cleanly"))

        // It runs in the folder asked for.
        let pwd = try shellRun.input.parse(["program": "pwd", "cwd": .string("\(home)/proj")])
        #expect(try await shellRun.execute(pwd, ctx).result.str("stdout") == "\(home)/proj\n")

        // A real change, with the scopes a move needs.
        let mv = try shellRun.input.parse(["program": "mv", "args": ["notes.txt", "proj/moved.txt"]])
        #expect(shellRun.scopes(mv) == [.read(path: home), .write(path: "\(home)/proj/moved.txt")])
        _ = try await shellRun.execute(mv, ctx)
        #expect(FileManager.default.fileExists(atPath: "\(home)/proj/moved.txt"))

        // A failing command reports what the program said.
        let missing = try shellRun.input.parse(["program": "cat", "args": ["nope.txt"]])
        await #expect(throws: MerryError.self) { try await shellRun.execute(missing, ctx) }

        // Code runners are confirmed every time, in these words.
        let node = try shellRun.input.parse(["program": "node", "args": ["-e", "1"], "cwd": .string("\(home)/proj")])
        #expect(shellRun.confirm?(node) == "run `node -e 1` in \(home)/proj, which can change anything your account can")
        #expect(shellRun.scopes(node) == [.write(path: "\(home)/proj")])

        // A refused command asks for nothing, confirms nothing, and does not run.
        for refused: JSON in [
            ["program": "rm", "args": ["-rf", "proj"]],
            ["program": "git", "args": ["config", "core.pager", "sh"]],
            ["program": "cat", "args": ["/etc/passwd"]],
            ["program": "node", "args": ["x.js"], "cwd": "/tmp"],
            ["program": "open", "args": ["bin/tool-x"]]
        ] {
            let input = try shellRun.input.parse(refused)
            #expect(shellRun.scopes(input).isEmpty)
            #expect(shellRun.confirm?(input) == nil)
            await #expect(throws: RefusedCommand.self) { try await shellRun.execute(input, ctx) }
        }
        #expect(FileManager.default.fileExists(atPath: "\(home)/proj"))

        // An argument holding a NUL would reach the program cut short, so it never starts.
        let nul = try shellRun.input.parse(["program": "echo", "args": ["a\u{0}b"]])
        await #expect(throws: MerryError.self) { try await shellRun.execute(nul, ctx) }
    }
}

@Test func appOpenRefusesWhatWouldRun() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let ctx = context()
    for path in ["\(home)/bin/tool-x", "\(home)/bin/link-x", "\(home)/Thing.app", "\(home)/setup.pkg"] {
        let input = try appOpen.input.parse(["path": .string(path)])
        #expect(appOpen.scopes(input) == [.read(path: path)])
        do {
            _ = try await appOpen.execute(input, ctx)
            Issue.record("\(path) should not open")
        } catch {
            #expect(messageOf(error) == "Opening \(Path.basename(path)) would run it, so I will not. Open it yourself if you trust it.")
        }
    }
    let protected = try appOpen.input.parse(["path": "/System/Library/CoreServices"])
    do {
        _ = try await appOpen.execute(protected, ctx)
        Issue.record("a protected location should not open")
    } catch {
        #expect(messageOf(error) == "/System/Library/CoreServices is in a protected location.")
    }
}


/// Ways round the reference's check, each of which it accepts. None may pass here.
@Test func knownWaysRoundTheOriginalCheckAreClosed() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let escapes: [[String]] = [
        ["git", "clone", "-usth", "x"],
        ["git", "-ccore.pager=sh", "log"],
        ["git", "log", "-ccore.pager=sh"],
        ["git", "grep", "-Osh", "x"],
        ["git", "grep", "--open-files-in-pager=sh", "x"],
        ["git", "--git-dir", "status", "config", "alias.x", "!sh"],
        ["git", "-C", "status", "config", "alias.x", "!sh"],
        ["git", "", "config", "alias.x", "!sh"],
        ["git", "clone", "--upload-pack=sh\n", "x"],
        ["git", "clone", "-u\n", "x"],
        ["git", "clone", "ext::sh\n"],
        ["git", "clone", "EXT::sh -c id"],
        ["git", "log", "--output=/etc/x"],
        ["git", "--git-dir=/etc/x", "status"],
        ["git", "-C/etc", "status"],
        ["git", "-C", "/etc", "status"],
        ["cat", "--file=/etc/passwd"],
        ["cp", "notes.txt", "--target-directory=/etc"],
        ["ls", "-I/etc"],
        ["git", "--no-pager"],
        ["git", "--work-tree", "/tmp", "status"]
    ]
    try Path.$scopedHome.withValue(home) {
        for command in escapes {
            let label = command.map { $0.debugDescription }.joined(separator: " ")
            #expect(throws: RefusedCommand.self, "\(label) should be refused") { try vetCommand(command[0], Array(command.dropFirst()), nil) }
        }
        // Ordinary commands still pass.
        for command in [["git", "status"], ["git", "log", "--oneline"], ["git", "add", "-A"], ["git", "commit", "-m", "x=y"],
                        ["git", "log", "--output=proj/log.txt"], ["ls", "-la", "proj"], ["mkdir", "-p", "proj/a/b"], ["cp", "notes.txt", "proj/"], ["git"]] {
            _ = try vetCommand(command[0], Array(command.dropFirst()), nil)
        }
    }
}

/// The hardened check never accepts what the reference refuses.
@Test func hardeningOnlyEverRefusesMore() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let text = try String(contentsOf: Fixture.directory.appendingPathComponent("shell-cases.json"), encoding: .utf8)
    let fixture = try JSON.parse(text.replacingOccurrences(of: "$HOME", with: home))
    Path.$scopedHome.withValue(home) {
        for row in fixture.list("cases") where row["vetted"] == nil {
            #expect((try? vetCommand(row.str("program"), row.strings("args"), row.optStr("cwd"))) == nil, "\(row.str("program")) \(row.strings("args"))")
        }
    }
}
