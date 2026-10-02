import Foundation

/// The shapes Merry's own workspace accepts: notes, tasks, reminders, projects,
/// bookmarks, sessions, trackers, and the focus timer.
public enum BrainSchema {
    public static let kinds = ["note", "task", "reminder", "project", "bookmark", "session", "tracker"]
    public static let kind = S.oneOf(kinds)

    public static let source = S.object([
        "kind": S.oneOf("path", "url"),
        "label": S.string().max(300),
        "value": S.string().min(1).max(4000)
    ]).strict()

    public static let fields = S.object([
        "kind": kind,
        "title": S.string().trim().min(1).max(300),
        "body": S.string().max(40000).default(""),
        "projectId": S.string().max(100).nullable().default(nil),
        "dueAt": S.number().int().min(0).max(8640000000000000).nullable().default(nil),
        "repeat": S.oneOf("none", "daily", "weekly").default("none"),
        "estimateMinutes": S.number().int().min(1).max(1440).nullable().default(nil),
        "sources": S.array(source).max(100).default([])
    ]).strict()

    private static let id = S.string().min(1).max(100)

    public static let request = S.union(on: "op", [
        S.object(["op": S.literal("list"), "id": id.optional(), "query": S.string().max(300).optional(), "kind": kind.optional(), "projectId": id.optional()]).strict(),
        S.object(["op": S.literal("create"), "item": fields]).strict(),
        S.object(["op": S.literal("update"), "id": id, "changes": S.object([
            "kind": kind.optional(),
            "title": fields.field("title").optional(),
            "body": fields.field("body").removeDefault().optional(),
            "projectId": fields.field("projectId").removeDefault().optional(),
            "dueAt": fields.field("dueAt").removeDefault().optional(),
            "repeat": fields.field("repeat").removeDefault().optional(),
            "estimateMinutes": fields.field("estimateMinutes").removeDefault().optional(),
            "sources": fields.field("sources").removeDefault().optional()
        ]).strict()]).strict(),
        S.object(["op": S.literal("complete"), "id": id]).strict(),
        S.object(["op": S.literal("reopen"), "id": id]).strict(),
        S.object(["op": S.literal("archive"), "id": id]).strict(),
        S.object(["op": S.literal("acknowledge"), "id": id]).strict(),
        S.object(["op": S.literal("snooze"), "id": id, "minutes": S.number().int().min(1).max(10080)]).strict(),
        S.object(["op": S.literal("check"), "id": id]).strict(),
        S.object(["op": S.literal("timer"), "action": S.oneOf("start", "pause", "resume", "cancel"), "minutes": S.number().min(1.0 / 60).max(1440).optional(), "label": S.string().trim().min(1).max(100).optional()]).strict()
    ])
}
