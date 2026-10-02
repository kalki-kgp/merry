import Foundation

// Capability-based access to the operating system.
//
// The task loop and the tools never call macOS directly. They ask for
// capabilities through this protocol, and an adapter either provides them or
// reports them unsupported, which is also what lets tests run against a fake.

public enum AutomationStatus: String, Codable, Sendable {
    case granted, denied
    case notAsked = "not-asked"
    case notRunning = "not-running"
    case notInstalled = "not-installed"
    case unknown
}

public enum Capability: String, Sendable {
    case appsList = "apps.list"
    case windowInspect = "window.inspect"
    case windowFocus = "window.focus"
    case windowCapture = "window.capture"
    case elementAct = "element.act"
    case inputSynthetic = "input.synthetic"
    case displayInfo = "display.info"
}

public struct Frame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public struct ScreenPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct AppInfo: Codable, Equatable, Sendable {
    public var bundleId: String
    public var name: String
    public var pid: Int
    public var active: Bool
    public var windowCount: Int
    public init(bundleId: String, name: String, pid: Int, active: Bool, windowCount: Int) {
        self.bundleId = bundleId; self.name = name; self.pid = pid; self.active = active; self.windowCount = windowCount
    }
}

public struct DisplayInfo: Codable, Equatable, Sendable {
    public var id: Int
    /// Logical (point) bounds, origin at the top-left of the primary display.
    public var bounds: Frame
    /// Backing scale factor: 2 on Retina. All synthetic input uses points.
    public var scaleFactor: Double
    public var primary: Bool
    public init(id: Int, bounds: Frame, scaleFactor: Double, primary: Bool) {
        self.id = id; self.bounds = bounds; self.scaleFactor = scaleFactor; self.primary = primary
    }
}

public struct ElementStamp: Codable, Equatable, Sendable {
    public var role: String
    public var title: String
    /// Logical-point frame at observation time.
    public var frame: Frame
    public init(role: String, title: String, frame: Frame) { self.role = role; self.title = title; self.frame = frame }
}

/// A reference to a UI element, valid only for the observation that produced
/// it. `stamp` lets the adapter confirm the element still matches before
/// acting; a mismatch means the window changed and the caller must re-observe.
public struct ElementRef: Codable, Equatable, Sendable {
    public var id: String
    public var pid: Int
    public var windowId: String
    /// Index path through the accessibility tree.
    public var path: [Int]
    public var stamp: ElementStamp
    public init(id: String, pid: Int, windowId: String, path: [Int], stamp: ElementStamp) {
        self.id = id; self.pid = pid; self.windowId = windowId; self.path = path; self.stamp = stamp
    }
}

public struct UiElement: Codable, Equatable, Sendable {
    public var ref: ElementRef
    public var role: String
    public var subrole: String?
    public var title: String
    public var value: String?
    public var enabled: Bool
    public var focused: Bool
    public var frame: Frame
    /// Accessibility actions this element genuinely supports.
    public var actions: [String]
    public var children: [UiElement]?
    public init(ref: ElementRef, role: String, subrole: String? = nil, title: String, value: String? = nil, enabled: Bool, focused: Bool, frame: Frame, actions: [String], children: [UiElement]? = nil) {
        self.ref = ref; self.role = role; self.subrole = subrole; self.title = title; self.value = value
        self.enabled = enabled; self.focused = focused; self.frame = frame; self.actions = actions; self.children = children
    }
}

public struct WindowSnapshot: Codable, Equatable, Sendable {
    public var app: AppInfo
    public var windowId: String
    public var title: String
    public var frame: Frame
    public var displayId: Int
    public var elements: [UiElement]
    public var observedAt: Double
    public init(app: AppInfo, windowId: String, title: String, frame: Frame, displayId: Int, elements: [UiElement], observedAt: Double) {
        self.app = app; self.windowId = windowId; self.title = title; self.frame = frame
        self.displayId = displayId; self.elements = elements; self.observedAt = observedAt
    }
}

public struct CaptureResult: Codable, Equatable, Sendable {
    /// Absolute path to a PNG in the temp directory.
    public var path: String
    public var width: Int
    public var height: Int
    public var scaleFactor: Double
    public init(path: String, width: Int, height: Int, scaleFactor: Double) {
        self.path = path; self.width = width; self.height = height; self.scaleFactor = scaleFactor
    }
}

public struct UnsupportedCapabilityError: Error, LocalizedError, Sendable {
    public let capability: Capability
    public init(_ capability: Capability) { self.capability = capability }
    public var errorDescription: String? { "Capability not supported on this platform: \(capability.rawValue)" }
}

public struct StaleElementError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A failure with a message meant to be read, by the model or by the person.
public struct MerryError: Error, LocalizedError, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// The text of any error, the way `err instanceof Error ? err.message : String(err)` reads it.
public func messageOf(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    if type(of: error) is NSError.Type { return error.localizedDescription }
    return String(describing: error)
}

public protocol OsAdapter: AnyObject, Sendable {
    func supports(_ capability: Capability) -> Bool

    /// OS permission grants. Checking must never itself trigger a prompt.
    func getPermissions() async throws -> [PermissionStatus]
    /// Triggers the system prompt, or opens the relevant Settings pane.
    func requestPermission(_ permission: OsPermission) async throws -> PermissionStatus
    /// Whether Merry may script another app. Without `ask` this never prompts;
    /// with it, the system asks the person if they have not answered yet.
    func automationPermission(bundleId: String, ask: Bool) async throws -> AutomationStatus

    func listApps() async throws -> [AppInfo]
    func getFrontmostWindow() async throws -> WindowSnapshot?
    func focusWindow(pid: Int, windowId: String?) async throws
    func inspectWindow(pid: Int, maxDepth: Int?, maxNodes: Int?) async throws -> WindowSnapshot

    func pressElement(_ ref: ElementRef, action: String?) async throws
    func setElementValue(_ ref: ElementRef, value: String) async throws

    func click(_ point: ScreenPoint, button: String?, count: Int?) async throws
    func typeText(_ text: String) async throws
    func shortcut(_ keys: String) async throws
    func scroll(_ point: ScreenPoint, dx: Double, dy: Double) async throws

    func captureWindow(pid: Int, windowId: String?) async throws -> CaptureResult
    func listDisplays() async throws -> [DisplayInfo]

    func dispose() async
}

/// An adapter that can do nothing, and says so. Used where no desktop access
/// exists, so the runtime degrades to file work instead of failing confusingly.
public final class UnavailableOsAdapter: OsAdapter {
    public init() {}
    public func supports(_ capability: Capability) -> Bool { false }
    public func getPermissions() async throws -> [PermissionStatus] { [] }
    public func requestPermission(_ permission: OsPermission) async throws -> PermissionStatus {
        PermissionStatus(permission: permission, granted: false, purpose: "Not available.")
    }
    public func automationPermission(bundleId: String, ask: Bool) async throws -> AutomationStatus { .notInstalled }
    public func listApps() async throws -> [AppInfo] { throw UnsupportedCapabilityError(.appsList) }
    public func getFrontmostWindow() async throws -> WindowSnapshot? { throw UnsupportedCapabilityError(.windowInspect) }
    public func focusWindow(pid: Int, windowId: String?) async throws { throw UnsupportedCapabilityError(.windowFocus) }
    public func inspectWindow(pid: Int, maxDepth: Int?, maxNodes: Int?) async throws -> WindowSnapshot { throw UnsupportedCapabilityError(.windowInspect) }
    public func pressElement(_ ref: ElementRef, action: String?) async throws { throw UnsupportedCapabilityError(.elementAct) }
    public func setElementValue(_ ref: ElementRef, value: String) async throws { throw UnsupportedCapabilityError(.elementAct) }
    public func click(_ point: ScreenPoint, button: String?, count: Int?) async throws { throw UnsupportedCapabilityError(.inputSynthetic) }
    public func typeText(_ text: String) async throws { throw UnsupportedCapabilityError(.inputSynthetic) }
    public func shortcut(_ keys: String) async throws { throw UnsupportedCapabilityError(.inputSynthetic) }
    public func scroll(_ point: ScreenPoint, dx: Double, dy: Double) async throws { throw UnsupportedCapabilityError(.inputSynthetic) }
    public func captureWindow(pid: Int, windowId: String?) async throws -> CaptureResult { throw UnsupportedCapabilityError(.windowCapture) }
    public func listDisplays() async throws -> [DisplayInfo] { throw UnsupportedCapabilityError(.displayInfo) }
    public func dispose() async {}
}
