import SwiftUI

/// Whether a window is on screen. Views use it to stop animating when nobody
/// can see them: a hidden window's views otherwise keep drawing every frame.
@MainActor
final class WindowActivity: ObservableObject {
    @Published var visible = false
}

private struct WindowVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the window holding this view is hidden.
    var windowVisible: Bool {
        get { self[WindowVisibleKey.self] }
        set { self[WindowVisibleKey.self] = newValue }
    }
}

/// Passes a window's visibility down to its content.
struct ActivityRoot<Content: View>: View {
    @ObservedObject var activity: WindowActivity
    let content: Content

    var body: some View {
        content.environment(\.windowVisible, activity.visible)
    }
}
