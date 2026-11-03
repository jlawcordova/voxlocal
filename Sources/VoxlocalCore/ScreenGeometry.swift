import CoreGraphics

/// Coordinate math for placing the overlay. Kept free of AppKit so it can be tested.
///
/// The Accessibility API reports rects in "global display" coordinates: origin at the
/// top-left of the primary screen, y growing downward. AppKit uses origin at the bottom-left
/// of the primary screen, y growing upward. Both span every connected screen.
public enum ScreenGeometry {
    /// Converts an AX rect to AppKit screen coordinates. `primaryHeight` is the height of the
    /// screen whose AppKit frame origin is (0, 0).
    public static func appKitRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A caret rect is usable when it has height, isn't absurdly large (some apps report the
    /// whole text view), and sits on a screen. Width may be 0: an insertion point is a line.
    public static func isUsableCaret(_ rect: CGRect, screens: [CGRect]) -> Bool {
        guard rect.height >= 4, rect.height <= 200, rect.width >= 0, rect.width <= 2000,
              rect.minX.isFinite, rect.minY.isFinite
        else { return false }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return screens.contains { $0.contains(center) }
    }

    /// The screen frame containing `point`, else the nearest one.
    public static func screen(containing point: CGPoint, screens: [CGRect]) -> CGRect? {
        if let hit = screens.first(where: { $0.contains(point) }) { return hit }
        return screens.min { distance($0, point) < distance($1, point) }
    }

    /// Origin (AppKit coordinates) for a panel of `size` centered under `anchor`, `gap` points
    /// below it; flipped above when there's no room below, then clamped inside `visibleFrame`.
    public static func panelOrigin(below anchor: CGRect, size: CGSize, visibleFrame: CGRect, gap: CGFloat = 8) -> CGPoint {
        var y = anchor.minY - gap - size.height
        if y < visibleFrame.minY {
            y = anchor.maxY + gap
        }
        var x = anchor.midX - size.width / 2
        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - size.width)
        y = min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGPoint(x: x, y: y)
    }

    /// Fallback position: centered near the top of `visibleFrame`.
    public static func topCenterOrigin(size: CGSize, visibleFrame: CGRect, inset: CGFloat = 12) -> CGPoint {
        CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.maxY - inset - size.height)
    }

    private static func distance(_ rect: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
