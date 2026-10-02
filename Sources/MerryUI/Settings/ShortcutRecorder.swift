import AppKit
import SwiftUI

/// The keys of a shortcut as a Mac keyboard labels them.
struct ShortcutKeys: View {
    let accelerator: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Accelerator.display(accelerator).enumerated()), id: \.offset) { index, key in
                if index > 0 { Text(verbatim: "+").font(Chrome.mono(11)).foregroundStyle(Chrome.tertiaryText) }
                Text(verbatim: key)
                    .font(Chrome.mono(11))
                    .foregroundStyle(Chrome.primaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Chrome.overlay(0.1)))
            }
        }
        .fixedSize()
    }
}

/// The shortcut, shown as keys; click it and press a new chord to change it.
/// A chord needs ⌘, ⌥ or ⌃, so ordinary typing can never be taken over.
struct ShortcutRecorder: View {
    /// The shortcut that is registered now. After a save this is whatever the
    /// backend reports, which may be a free one it fell back to.
    let value: String
    let onChange: (String) -> Void

    /// How many recorders are listening, so other key handling can stand aside.
    @MainActor static var recordingCount = 0
    @MainActor static var isRecordingAnywhere: Bool { recordingCount > 0 }

    @State private var recording = false
    @State private var refusal: String?
    @State private var monitor: Any?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button { recording ? stop() : start() } label: {
                Group {
                    if recording {
                        Text(verbatim: "Press keys…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Chrome.lime).padding(.horizontal, 4)
                    } else {
                        ShortcutKeys(accelerator: value)
                    }
                }
                .frame(minHeight: 26)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(recording ? Chrome.lime.opacity(0.1) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(recording ? Chrome.lime : isHovering ? Chrome.lime.opacity(0.3) : Chrome.overlay(0.14), lineWidth: 1))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(Text(verbatim: recording ? "Press the new shortcut, or Escape to keep this one" : "Shortcut \(Accelerator.display(value).joined(separator: " ")). Click to change"))
            if let refusal {
                Text(verbatim: refusal)
                    .font(.system(size: 11))
                    .foregroundStyle(Chrome.red)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        guard !recording else { return }
        recording = true
        refusal = nil
        Self.recordingCount += 1
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Accelerator.capture(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            case .cancelled: stop()
            case .ignored: break
            case .refused(let message): refusal = message
            case .accepted(let accelerator):
                stop()
                onChange(accelerator)
            }
            // Nothing pressed while listening reaches anything else.
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        Self.recordingCount = max(0, Self.recordingCount - 1)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
