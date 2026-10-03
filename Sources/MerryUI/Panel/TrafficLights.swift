import SwiftUI

/// The three window buttons, as on any Mac window: close, minimize to the
/// island, and keep in front.
struct TrafficLights: View {
    var pinned: Bool
    var close: () -> Void
    var minimize: () -> Void
    var pin: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            light("#ff5f57", "xmark", "Close", close)
            light("#febc2e", "minus", "Minimize to the island", minimize)
            light("#28c840", pinned ? "pin.slash.fill" : "pin.fill", pinned ? "Stop keeping in front" : "Keep in front", pin)
        }
        .onHover { hovering = $0 }
    }

    private func light(_ colour: String, _ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(Color(hex: colour))
                .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                .overlay {
                    if hovering { Image(systemName: symbol).font(.system(size: 6.5, weight: .heavy)).foregroundStyle(.black.opacity(0.6)) }
                }
                .frame(width: 12, height: 12)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}
