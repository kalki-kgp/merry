// Building blocks from Droppy Code (gitlab.com/droppyformac1/droppy-code),
// DroppyCode/Views/Chrome/Chrome.swift and Popovers.swift, as trimmed for the
// Buds menu bar app. They give Merry's panel the same Liquid Glass language.
//
// MIT License. Copyright (c) 2026 T3 Tools Inc. Copyright (c) 2026 Jordy Spruit.
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software
// and associated documentation files, to deal in the Software without restriction. THE SOFTWARE
// IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND. (Full text: licenses/LICENSE-droppy-code.)

import AppKit
import SwiftUI

enum Chrome {
    static let windowCornerRadius: CGFloat = 26
    static let islandCornerRadius: CGFloat = 23

    static let iconFont: Font = .system(size: 12, weight: .semibold)
    static let inlineIconFont: Font = .system(size: 11, weight: .semibold)
    static let chevronFont: Font = .system(size: 8, weight: .bold)
    static let capsuleContentHeight: CGFloat = 28
    static let capsuleVerticalPadding: CGFloat = 2
    static let capsuleHorizontalPadding: CGFloat = 12
    static var capsuleHeight: CGFloat { capsuleContentHeight + capsuleVerticalPadding * 2 }

    static let cardCornerRadius: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    static let sectionHeaderSpacing: CGFloat = 10
    static let contentHorizontalPadding: CGFloat = 16
    static let rowControlTrailingPadding: CGFloat = 10

    static func overlay(_ opacity: Double) -> Color { primaryText.opacity(opacity) }

    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let glassTint = Color.clear

    /// Merry's one signal colour: the lime of its face. Used for the primary
    /// action and for what is live, never for decoration.
    static let lime = Color(hex: "#d4ff3a")
    /// Text and icons that sit on lime.
    static let limeInk = Color(hex: "#0b0b0c")
    static let amber = Color(hex: "#ffb23e")
    static let red = Color(hex: "#ff5a4e")
    static let ice = Color(hex: "#8fb4ff")
    static let accent = lime

    /// Monospaced micro-type, for anything that is status rather than content.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    static var hover: Animation { .easeOut(duration: 0.1) }
    static var panelSlide: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.32, dampingFraction: 0.9)
    }

    /// The section tile hues Droppy's settings sidebar uses.
    static let tileHues: [Color] = [
        Color(red: 0.345, green: 0.337, blue: 0.839),
        Color(red: 1.000, green: 0.584, blue: 0.000),
        Color(red: 0.188, green: 0.690, blue: 0.780),
        Color(red: 0.686, green: 0.322, blue: 0.871),
        Color(red: 0.204, green: 0.780, blue: 0.349),
        Color(red: 0.040, green: 0.478, blue: 1.000),
        Color(red: 0.925, green: 0.282, blue: 0.600),
        Color(red: 0.800, green: 0.565, blue: 0.145),
        Color(red: 0.353, green: 0.400, blue: 0.459),
    ]
}

// MARK: - Surfaces

extension View {
    func chromeGlassCapsule() -> some View {
        glassEffect(.regular.tint(Chrome.glassTint.opacity(0.3)).interactive(), in: Capsule(style: .continuous))
    }

    func chromeGlassCircle() -> some View {
        glassEffect(.regular.tint(Chrome.glassTint.opacity(0.3)).interactive(), in: Circle())
    }
}

/// One Liquid Glass surface for a whole window or panel, clipped to its 26pt radius, with a
/// legibility scrim. The window's background is clear, so this shape is all there is.
struct WindowGlass: View {
    var cornerRadius: CGFloat = Chrome.windowCornerRadius
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        shape
            .fill(.clear)
            .glassEffect(in: shape)
            .overlay { shape.fill(isDark ? Color.black : Color.white).opacity(isDark ? 0.26 : 0.18) }
            .allowsHitTesting(false)
    }
}

// MARK: - Chrome controls

struct ChromeCircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Chrome.iconFont)
                .foregroundStyle(Chrome.primaryText.opacity(isHovering ? 1 : 0.92))
                .frame(width: Chrome.capsuleHeight, height: Chrome.capsuleHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .chromeGlassCircle()
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

struct ChromeTextButton: View {
    let symbol: String
    let title: String
    let help: String
    var isEnabled = true
    var isDestructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(Chrome.inlineIconFont)
                Text(verbatim: title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .padding(.vertical, Chrome.capsuleVerticalPadding)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private var foreground: Color {
        guard isEnabled else { return Chrome.primaryText.opacity(0.32) }
        if isDestructive { return Chrome.danger.opacity(isHovering ? 1 : 0.92) }
        return Chrome.primaryText.opacity(isHovering ? 1 : 0.92)
    }
}

/// A text button shaped like a chrome capsule that opens a popover.
struct ChromeTextMenu<Content: View>: View {
    let symbol: String
    let title: String
    let help: String
    @ViewBuilder var content: Content

    @State private var isHovering = false
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(Chrome.inlineIconFont)
                Text(verbatim: title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(Chrome.chevronFont).foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .padding(.vertical, Chrome.capsuleVerticalPadding)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
        .help(help)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu { content }
        }
    }
}

struct PopoverSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(verbatim: title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A glass capsule showing the current choice; clicking it opens the choices in a native popover.
struct GlassPickerButton<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var placeholder = "—"

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        let title = options.first { $0.value == selection }?.title ?? placeholder
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(Chrome.chevronFont).foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    PopoverItem(option.title, isChecked: option.value == selection) {
                        selection = option.value
                    }
                }
            }
        }
    }
}

// MARK: - Popovers

struct PopoverMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(6)
            .frame(minWidth: 190, maxWidth: 320, alignment: .leading)
    }
}

struct PopoverItem: View {
    let title: String
    var isChecked: Bool?
    let action: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isHovering = false

    init(_ title: String, isChecked: Bool? = nil, action: @escaping () -> Void) {
        self.title = title
        self.isChecked = isChecked
        self.action = action
    }

    var body: some View {
        Button {
            dismiss()
            Task { @MainActor in action() }
        } label: {
            HStack(spacing: 8) {
                if let isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(isChecked ? 1 : 0)
                        .frame(width: 14)
                }
                Text(verbatim: title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 16)
            }
            .foregroundStyle(Chrome.primaryText)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Chrome.overlay(0.1) : Color.clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
    }
}

// MARK: - Cards

struct ChromeCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                    .fill(Chrome.overlay(0.05))
            )
    }
}

struct ChromeSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            HStack {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, 4)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChromeRow<Leading: View, Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 13))
                    .foregroundStyle(Chrome.primaryText)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.leading, 12)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 9)
    }
}

extension ChromeRow where Leading == EmptyView {
    init(title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.leading = EmptyView()
        self.control = control()
    }
}

struct ChromeRowDivider: View {
    var inset: CGFloat = 16
    var body: some View { Divider().padding(.leading, inset) }
}

struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

extension AnyTransition {
    static var softAppear: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 4)).animation(.smooth(duration: 0.32)),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }
}

// MARK: - Tiles

/// The rounded gradient tile Droppy's settings put beside a row or a sidebar item.
struct IconTile: View {
    let symbol: String
    let hue: Int
    var size: CGFloat = 26

    var body: some View {
        let color = Chrome.tileHues[hue % Chrome.tileHues.count]
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

/// Equal cells in one card with a highlight that slides between them — the
/// "Menu bar icon | Dock icon | Launch at login" strip from Droppy's General page.
struct TileSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String, symbol: String)]
    let selection: Value?
    var vertical = false
    let onSelect: (Value) -> Void

    @Namespace private var highlight
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 && selection != option.value && selection != options[index - 1].value {
                    Rectangle().fill(Chrome.overlay(0.1)).frame(width: 1, height: 16)
                } else if index > 0 {
                    Color.clear.frame(width: 1, height: 16)
                }
                cell(option)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Chrome.overlay(0.05)))
        .animation(Chrome.panelSlide, value: selection)
    }

    @ViewBuilder
    private func cell(_ option: (value: Value, title: String, symbol: String)) -> some View {
        let isSelected = option.value == selection
        Button { onSelect(option.value) } label: {
            Group {
                if vertical {
                    VStack(spacing: 5) {
                        Image(systemName: option.symbol).font(.system(size: 15, weight: .medium))
                        Text(verbatim: option.title).font(.system(size: 11, weight: .medium))
                    }
                    .frame(height: 50)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: option.symbol).font(.system(size: 11, weight: .medium))
                        Text(verbatim: option.title).font(.system(size: 12, weight: .medium))
                    }
                    .frame(height: 30)
                }
            }
            .lineLimit(1)
            .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 1 : 0.72))
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Chrome.overlay(0.13))
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                } else if hovered == option.value {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.overlay(0.05))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { hovered = h ? option.value : nil } }
    }
}
