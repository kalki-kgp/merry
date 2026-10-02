import AppKit
import SwiftUI

// Small pieces the settings and tour views share, for the few things Chrome
// has no ready-made control for.

/// A one-line text or secret field on the card surface.
struct SettingsField: View {
    @Binding var text: String
    var placeholder: String
    var secure = false
    var mono = true
    var readOnly = false
    var onSubmit: () -> Void = {}

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: Text(verbatim: placeholder))
            } else {
                TextField("", text: $text, prompt: Text(verbatim: placeholder))
            }
        }
        .textFieldStyle(.plain)
        .font(mono ? Chrome.mono(12, weight: .regular) : .system(size: 12.5))
        .foregroundStyle(Chrome.primaryText)
        .disabled(readOnly)
        .onSubmit(onSubmit)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Chrome.overlay(0.07)))
    }
}

/// A line of feedback under a control: plain words, coloured only for a failure or a success.
struct SettingsNote: View {
    enum Tone { case dim, bad, ok }
    let text: String
    var tone: Tone = .dim

    init(_ text: String, tone: Tone = .dim) { self.text = text; self.tone = tone }

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(tone == .bad ? Chrome.red : tone == .ok ? Chrome.lime : Chrome.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The primary action: lime, with dark ink on it.
struct SettingsPrimaryButton: View {
    let title: String
    var symbol: String?
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(verbatim: title).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                if let symbol { Image(systemName: symbol).font(Chrome.inlineIconFont) }
            }
            .foregroundStyle(Chrome.limeInk)
            .padding(.horizontal, 14)
            .frame(height: Chrome.capsuleHeight)
            .background(Capsule(style: .continuous).fill(Chrome.lime.opacity(isEnabled ? (isHovering ? 1 : 0.92) : 0.35)))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .fixedSize()
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
    }
}

/// A section that folds away, as the reference's `<details>` do.
struct SettingsDisclosure<Content: View>: View {
    let title: String
    @Binding var isOpen: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(Chrome.chevronFont)
                        .foregroundStyle(Chrome.tertiaryText)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Spacer()
                }
                .padding(.horizontal, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: isOpen ? "expanded" : "collapsed"))
            if isOpen { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small capitals in the mono face, for a heading inside a card or above a list.
struct SettingsCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text.uppercased())
            .font(Chrome.mono(10, weight: .bold))
            .kerning(1)
            .foregroundStyle(Chrome.secondaryText)
    }
}

/// Finds the window a view is in, so key handling can be kept to that window.
struct SettingsWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    final class Probe: NSView {
        var onWindow: (NSWindow?) -> Void = { _ in }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow(window) }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: Probe, context: Context) { view.onWindow = onWindow }
}

// Liquid Glass cannot be captured offscreen: one glass surface blanks the whole
// snapshot. Screens rendered by `Merry --snapshot` set this, and the two glass
// controls below draw a flat stand-in of the same size instead. The app never sets it.
private struct SettingsFlatGlassKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var settingsFlatGlass: Bool {
        get { self[SettingsFlatGlassKey.self] }
        set { self[SettingsFlatGlassKey.self] = newValue }
    }
}

/// `ChromeTextButton`, except in a snapshot.
struct SettingsButton: View {
    let symbol: String
    let title: String
    let help: String
    var isEnabled = true
    var isDestructive = false
    let action: () -> Void

    @Environment(\.settingsFlatGlass) private var flat

    var body: some View {
        if flat {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(Chrome.inlineIconFont)
                Text(verbatim: title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(!isEnabled ? Chrome.primaryText.opacity(0.32) : isDestructive ? Chrome.danger.opacity(0.92) : Chrome.primaryText.opacity(0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleHeight)
            .background(Capsule(style: .continuous).fill(Chrome.overlay(0.09)))
            .fixedSize()
        } else {
            ChromeTextButton(symbol: symbol, title: title, help: help, isEnabled: isEnabled, isDestructive: isDestructive, action: action)
        }
    }
}

/// `GlassPickerButton`, except in a snapshot.
struct SettingsPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    @Environment(\.settingsFlatGlass) private var flat

    var body: some View {
        if flat {
            HStack(spacing: 6) {
                Text(verbatim: options.first { $0.value == selection }?.title ?? "—").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(Chrome.chevronFont).foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .background(Capsule(style: .continuous).fill(Chrome.overlay(0.09)))
            .fixedSize()
        } else {
            GlassPickerButton(options: options, selection: $selection)
        }
    }
}
