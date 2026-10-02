import Combine
import Foundation
import MerryCore

/// Everything the interface can ask of the rest of the app, and everything it
/// is told. Views talk to this and nothing else, which keeps them free of
/// stores, models and windows, and lets them be exercised against a fake.
@MainActor
public protocol MerryBridge: AnyObject {
    var events: BridgeEvents { get }

    // Workspace
    func getBrain() async -> BrainSnapshot
    /// A request matching `BrainSchema.request`.
    func brainRequest(_ request: JSON) async throws -> BrainSnapshot
    func openBrain()

    // Tasks
    func startTask(_ request: StartTaskRequest) async throws -> TaskState
    func pauseTask(_ taskId: String)
    func resumeTask(_ taskId: String)
    func cancelTask(_ taskId: String)
    func answerQuestion(taskId: String, answer: AnswerPayload) async throws
    func undoTask(_ taskId: String) async throws -> UndoReport
    func getTask(_ taskId: String) async -> TaskState?
    /// Deletes the whole chat this turn belongs to. Files are never touched.
    func deleteTask(_ taskId: String) async throws
    func clearHistory() async throws
    func listHistory(limit: Int) async -> [TaskSummaryRow]
    /// Shows a file picker and returns what was chosen.
    func choosePaths() async -> [String]

    // Permissions
    func getPermissions() async -> [PermissionStatus]
    func requestPermission(_ permission: OsPermission) async throws -> PermissionStatus
    /// Everything Merry can be allowed to do on this Mac, and whether it is. Never prompts.
    func getSetup() async -> [SetupItem]
    /// Asks macOS for one of them: its own dialog where there is one, else its Settings pane.
    func requestSetup(_ id: String) async throws -> SetupItem
    /// Opens the System Settings pane where an answer can be changed.
    func openSetupSettings(_ id: String) async

    // Connections
    func setApiKey(_ key: String) async -> Bool
    func hasApiKey() async -> Bool
    func setJevKey(_ key: String) async -> Bool
    func hasJevKey() async -> Bool
    /// Which coding apps are installed, so settings offers only what works.
    func codingApps() async -> [CodingAppStatus]
    func codingModels(_ app: CodingApp, refresh: Bool) async throws -> CodingModelCatalog
    func checkCodingModel(_ app: CodingApp, model: String) async throws -> CodingModelCheck
    /// Whether any planning route is configured: a key, or a coding app.
    func canWork() async -> Bool
    /// Times each route a request can take on this machine.
    func runBench() async throws -> [BenchRow]

    // Settings
    func getSettings() -> Settings
    /// Applies a change to the settings, validates it, saves it and returns the result.
    func setSettings(_ change: (inout Settings) -> Void) async throws -> Settings
    func canUninstallApp() -> Bool
    /// Asks before stopping Merry and moving its installed app to the Trash.
    func uninstallApp() async throws -> Bool

    // Opening things
    func revealPath(_ path: String) throws
    func openPath(_ path: String) async throws
    func openUrl(_ url: String) async throws

    // The panel window
    func resizePanel(height: CGFloat)
    func closePanel()
    /// Puts the panel back in its default spot and forgets where it was dragged.
    func centerPanel()
    /// Collapses the panel to the island, or opens it back out.
    func minimizePanel()
    /// Whether the panel should float above other applications.
    func pinPanel(_ pinned: Bool)
    func getPanelState() -> PanelState

    // The pet window
    /// Opens the panel with a request typed in but not sent. Empty just opens it.
    func petCompose(_ text: String)
    /// The pet's right-click menu. `napping` swaps Little nap for Wake up.
    func showPetMenu(napping: Bool)
    /// `pressedAt` is when the button went down: the panel's state is judged as it was then.
    func petClicked(pressedAt: Date?)
    /// Holds the pet solid through a drag or a file drop, whatever the cursor does.
    func setPetInteractive(_ interactive: Bool)
    /// The creature and its bubble, in window coordinates, where the pet catches the mouse.
    func setPetHitRects(_ rects: [CGRect])
    func dragPet(dx: CGFloat, dy: CGFloat)
    func reportDroppedPaths(_ paths: [String])

    // Memory
    func listMemories() async -> [Memory]
    func deleteMemory(_ id: String) async -> [Memory]
    func clearMemories() async -> [Memory]

    func stopDesktopSession()
    func getFrontWindow() -> FrontWindow?
}

/// What the interface is told as things happen.
@MainActor
public final class BridgeEvents {
    public let taskUpdate = PassthroughSubject<TaskState, Never>()
    public let petState = PassthroughSubject<PetState, Never>()
    public let log = PassthroughSubject<LogEntry, Never>()
    public let historyDeleted = PassthroughSubject<[String], Never>()
    public let brainChanged = PassthroughSubject<BrainSnapshot, Never>()
    /// The panel should show the workspace.
    public let brainOpen = PassthroughSubject<Void, Never>()
    public let memoriesChanged = PassthroughSubject<[Memory], Never>()
    /// Files were dropped on the pet and belong in the composer.
    public let droppedPaths = PassthroughSubject<[String], Never>()
    /// The panel was summoned: put the cursor in the composer.
    public let focusInput = PassthroughSubject<Void, Never>()
    /// A request to place in the composer without sending it.
    public let seed = PassthroughSubject<String, Never>()
    public let panelState = PassthroughSubject<PanelState, Never>()
    public let desktopSession = PassthroughSubject<Bool, Never>()
    /// Where the mouse is, relative to the pet's centre, in points.
    public let cursor = PassthroughSubject<CGPoint, Never>()
    public let petPlay = PassthroughSubject<PetPlay, Never>()
    /// The pet is about to appear (true) or leave (false), so it can slide in and out.
    public let petPresence = PassthroughSubject<Bool, Never>()
    public let settingsChanged = PassthroughSubject<Settings, Never>()

    public init() {}
}
