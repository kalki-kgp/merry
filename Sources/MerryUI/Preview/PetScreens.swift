import SwiftUI
import MerryCore

/// Screens of this area that can be rendered with `Merry --snapshot`.
@MainActor
enum PetScreens {
    private static func pet(_ prepare: (PreviewBridge, PetModel) -> Void) -> some View {
        let bridge = PreviewBridge()
        let model = PetModel(bridge: bridge)
        model.start()
        prepare(bridge, model)
        return PetView(model: model)
    }

    private static func task(_ request: String, _ status: TaskStatus, _ line: String) -> TaskState {
        var task = TaskState(id: "preview", request: request)
        task.status = status
        task.statusLine = line
        return task
    }

    private static func reminder(_ title: String) -> BrainItem {
        let now = nowMs()
        let json: JSON = ["kind": "reminder", "title": .string(title), "body": "", "projectId": nil, "dueAt": .number(now - 60_000), "repeat": "none",
                          "estimateMinutes": nil, "sources": [], "id": "r1", "status": "open", "createdAt": .number(now - 3_600_000),
                          "updatedAt": .number(now - 3_600_000), "notifiedAt": .number(now - 60_000), "acknowledgedAt": nil, "checks": []]
        return try! JSONDecoder().decode(BrainItem.self, from: Data(json.stringify().utf8))
    }

    static func register() {
        Snapshot.register("pet-idle") { pet { _, _ in } }
        Snapshot.register("pet-chat") {
            pet { _, model in
                model.say(Line("Want me to tidy your Downloads?", .curious, action: .init(label: "Sure", compose: "Organize my Downloads folder")), 60_000)
            }
        }
        Snapshot.register("pet-working") {
            pet { bridge, model in
                bridge.events.petState.send(.working)
                bridge.events.taskUpdate.send(task("Organize my Downloads folder", .planning, "Getting started"))
                bridge.events.taskUpdate.send(task("Organize my Downloads folder", .executing, "Moving 14 files into Documents"))
                model.previewQuiet()
            }
        }
        Snapshot.register("pet-asking") {
            pet { bridge, model in
                bridge.events.petState.send(.waiting)
                var asking = task("Rename these", .awaitingUser, "Which folder did you mean?")
                asking.question = UserQuestion(id: "q1", reason: .ambiguous, prompt: "Which folder did you mean?", allowFreeText: true)
                bridge.events.taskUpdate.send(asking)
                model.previewQuiet()
            }
        }
        Snapshot.register("pet-finished") {
            pet { bridge, _ in
                bridge.events.petState.send(.working)
                bridge.events.taskUpdate.send(task("Organize my Downloads folder", .executing, "Moving 14 files"))
                var done = task("Organize my Downloads folder", .succeeded, "Done")
                done.summary = TaskSummary(headline: "Sorted **14 files** into 3 folders.", undoable: true)
                bridge.events.petState.send(.finished)
                bridge.events.taskUpdate.send(done)
            }
        }
        Snapshot.register("pet-failed") {
            pet { bridge, _ in
                var failed = task("Find my passport scan", .failed, "Couldn’t reach that folder.")
                failed.summary = TaskSummary(headline: "Couldn’t reach that folder.")
                bridge.events.petState.send(.failed)
                bridge.events.taskUpdate.send(failed)
            }
        }
        Snapshot.register("pet-reminder") {
            pet { bridge, _ in
                bridge.events.brainChanged.send(BrainSnapshot(items: [reminder("Call the dentist about Thursday")]))
            }
        }
        Snapshot.register("pet-timer") {
            pet { bridge, model in
                let now = nowMs()
                bridge.events.brainChanged.send(BrainSnapshot(timer: BrainTimer(id: "t1", label: "Deep work", durationMs: 1_500_000, remainingMs: 1_117_000,
                                                                                endsAt: now + 1_117_000, status: "running", notifiedAt: nil)))
                model.previewHover(true)
            }
        }
        Snapshot.register("pet-ringing") {
            pet { bridge, _ in
                bridge.events.brainChanged.send(BrainSnapshot(timer: BrainTimer(id: "t1", label: "Deep work", durationMs: 1_500_000, remainingMs: 0,
                                                                                endsAt: nil, status: "ringing", notifiedAt: nil)))
            }
        }
        Snapshot.register("pet-drop") {
            pet { _, model in
                model.dragEntered()
                model.dragOver()
            }
        }
    }
}
