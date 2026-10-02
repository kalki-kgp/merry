import SwiftUI
import MerryCore

/// Every mood side by side, for checking the drawing.
public struct SpriteSheet: View {
    public init() {}

    public var body: some View {
        let columns = Array(repeating: GridItem(.fixed(120), spacing: 8), count: 7)
        VStack(spacing: 18) {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Mood.allCases, id: \.self) { mood in
                    VStack(spacing: 4) {
                        SpriteView(state: .idle, mood: mood, size: 96)
                        Text(mood.rawValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            HStack(spacing: 24) {
                SpriteView(state: .idle, size: 96, timer: SpriteTimer(remainingMs: 24 * 60_000 + 37_000, progress: 0.82, status: "running"))
                SpriteView(state: .idle, size: 96, timer: SpriteTimer(remainingMs: 65 * 60_000, progress: 0.4, status: "paused"))
                SpriteView(state: .idle, size: 96, timer: SpriteTimer(remainingMs: 0, progress: 0, status: "ringing"))
                SpriteView(state: .working, size: 46, quiet: true)
                SpriteView(state: .idle, size: 32, quiet: true)
            }
        }
        .padding(24)
        .background(Color(hex: "#1c1d21"))
    }
}
