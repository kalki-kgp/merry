import AppKit

/// One coordinate space for window placement: global points with the origin at
/// the top-left of the primary display, y growing downwards. Saved positions,
/// Accessibility frames and the reference's window logic all use it; AppKit's
/// own space has its origin at the bottom-left, so the conversion happens
/// here and nowhere else.
@MainActor
enum ScreenSpace {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func fromAppKit(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height, width: rect.width, height: rect.height)
    }

    static func toAppKit(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height, width: rect.width, height: rect.height)
    }

    static func fromAppKit(_ point: NSPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }

    /// Where the mouse is.
    static var cursor: CGPoint { fromAppKit(NSEvent.mouseLocation) }

    private static func distance(_ rect: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private static func screen(nearest point: CGPoint) -> NSScreen? {
        NSScreen.screens.min { distance(fromAppKit($0.frame), point) < distance(fromAppKit($1.frame), point) }
    }

    /// The usable area (no menu bar, no Dock) of the display nearest a point.
    static func workArea(nearest point: CGPoint) -> CGRect {
        screen(nearest: point).map { fromAppKit($0.visibleFrame) } ?? .zero
    }

    /// The full bounds of the display nearest a point.
    static func bounds(nearest point: CGPoint) -> CGRect {
        screen(nearest: point).map { fromAppKit($0.frame) } ?? .zero
    }

    /// The usable area of the display a rectangle mostly sits on.
    static func workArea(matching rect: CGRect) -> CGRect {
        let best = NSScreen.screens.max { a, b in
            let ia = fromAppKit(a.frame).intersection(rect), ib = fromAppKit(b.frame).intersection(rect)
            return ia.width * ia.height < ib.width * ib.height
        }
        if let best, !fromAppKit(best.frame).intersection(rect).isEmpty { return fromAppKit(best.visibleFrame) }
        return workArea(nearest: CGPoint(x: rect.midX, y: rect.midY))
    }

    static var primaryWorkArea: CGRect { NSScreen.screens.first.map { fromAppKit($0.visibleFrame) } ?? .zero }

    /// Keeps a window inside the display it is closest to.
    static func onScreen(_ bounds: CGRect) -> CGRect {
        let area = workArea(matching: bounds)
        var out = bounds
        out.origin.x = max(area.minX, min(bounds.minX, area.maxX - bounds.width))
        out.origin.y = max(area.minY, min(bounds.minY, area.maxY - bounds.height))
        return out
    }
}
