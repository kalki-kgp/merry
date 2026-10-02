import Foundation

private func exists(_ p: String) -> Bool {
    FileManager.default.fileExists(atPath: p)
}

private func posixFailure(_ call: String, _ path: String) -> MerryError {
    MerryError("\(call) failed for \(path): \(String(cString: strerror(errno)))")
}

/// Reverses the file operations from one task, newest first.
///
/// This is deliberately conservative. We only reverse operations we recorded
/// both sides of, and we refuse when the world has moved on: if the file is no
/// longer where we put it, or something now occupies its original path, we skip
/// it and say so. There is no universal undo, and pretending otherwise would be
/// worse than doing nothing.
///
/// App changes (`mac.*` entries) are reversed by `reverseMac`, which returns a
/// reason when it declines.
public func undoTask(store: Store, taskId: String, reverseMac: (UndoEntry) async -> (ok: Bool, reason: String)) async -> UndoReport {
    var report = UndoReport()
    let entries: [(id: String, undo: UndoEntry)]
    do {
        entries = try store.undoableActions(taskId)
    } catch {
        report.skipped.append(.init(path: taskId, reason: messageOf(error)))
        return report
    }

    for (id, undo) in entries {
        let from = undo.payload.from, to = undo.payload.to
        do {
            if undo.kind.isMac {
                // App items are removed by the id the app gave them; settings go back
                // to the value recorded before the change.
                let r = await reverseMac(undo)
                if r.ok {
                    try store.markReversed(id)
                    report.reversed += 1
                } else {
                    report.skipped.append(.init(path: "\(from): \(to)", reason: r.reason))
                    if r.reason.contains("already gone") { try store.markReversed(id) }
                }
                continue
            }
            if undo.kind == .folderCreate {
                if !exists(to) {
                    report.skipped.append(.init(path: to, reason: "folder is already gone"))
                    try store.markReversed(id)
                    continue
                }
                let remaining = try FileManager.default.contentsOfDirectory(atPath: to)
                if remaining.count > 0 {
                    // Removing a folder that now holds files would destroy data.
                    report.skipped.append(.init(path: to, reason: "folder is not empty (\(remaining.count) items)"))
                    continue
                }
                // rmdir itself refuses a folder that is not empty.
                if rmdir(to) != 0 { throw posixFailure("rmdir", to) }
                try store.markReversed(id)
                report.reversed += 1
                continue
            }

            // file.move / file.rename: put it back where it came from.
            if !exists(to) {
                report.skipped.append(.init(path: to, reason: "the file is no longer where Merry put it"))
                continue
            }
            if exists(from) {
                report.skipped.append(.init(path: from, reason: "something else now occupies the original path"))
                continue
            }
            try FileManager.default.createDirectory(atPath: Path.dirname(from), withIntermediateDirectories: true)
            if rename(to, from) != 0 { throw posixFailure("rename", to) }
            // Confirm the reversal actually landed before recording it as done.
            if !exists(from) {
                report.skipped.append(.init(path: from, reason: "move back did not take effect"))
                continue
            }
            try store.markReversed(id)
            report.reversed += 1
        } catch {
            report.skipped.append(.init(path: to, reason: messageOf(error)))
        }
    }

    return report
}
