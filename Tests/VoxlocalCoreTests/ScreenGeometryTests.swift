import CoreGraphics
import Testing
@testable import VoxlocalCore

@Suite struct ScreenGeometryTests {
    // Primary laptop screen, AppKit frame origin (0, 0).
    let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func convertsOnPrimaryScreen() {
        // AX: 100 pt from the top. AppKit: 900 - 100 - 20 = 780 from the bottom.
        let r = ScreenGeometry.appKitRect(fromAX: CGRect(x: 50, y: 100, width: 2, height: 20), primaryHeight: 900)
        #expect(r == CGRect(x: 50, y: 780, width: 2, height: 20))
    }

    @Test func convertsOnScreenToTheLeft() {
        // External 1920×1080 to the left, bottoms aligned.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        // Its top edge is 180 pt above the primary's top, so AX y = -180 at that edge.
        let ax = CGRect(x: -1000, y: 100, width: 2, height: 18)
        let r = ScreenGeometry.appKitRect(fromAX: ax, primaryHeight: primary.height)
        #expect(r == CGRect(x: -1000, y: 782, width: 2, height: 18))
        #expect(ScreenGeometry.isUsableCaret(r, screens: [primary, left]))
        #expect(ScreenGeometry.screen(containing: CGPoint(x: r.midX, y: r.midY), screens: [primary, left]) == left)
    }

    @Test func convertsOnScreenAbove() {
        // External screen stacked above the primary: AX y is negative there.
        let above = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let ax = CGRect(x: 100, y: -500, width: 2, height: 20)
        let r = ScreenGeometry.appKitRect(fromAX: ax, primaryHeight: primary.height)
        #expect(r == CGRect(x: 100, y: 1380, width: 2, height: 20))
        #expect(ScreenGeometry.screen(containing: CGPoint(x: r.midX, y: r.midY), screens: [primary, above]) == above)
    }

    @Test func rejectsUnusableCarets() {
        #expect(!ScreenGeometry.isUsableCaret(.zero, screens: [primary]))
        #expect(!ScreenGeometry.isUsableCaret(CGRect(x: 10, y: 10, width: 0, height: 0), screens: [primary]))
        // Whole text view reported instead of a caret.
        #expect(!ScreenGeometry.isUsableCaret(CGRect(x: 0, y: 0, width: 1400, height: 800), screens: [primary]))
        // Off every screen.
        #expect(!ScreenGeometry.isUsableCaret(CGRect(x: 5000, y: 5000, width: 2, height: 18), screens: [primary]))
        // A zero-width insertion point is fine.
        #expect(ScreenGeometry.isUsableCaret(CGRect(x: 10, y: 10, width: 0, height: 18), screens: [primary]))
    }

    @Test func placesPanelBelowAndFlipsAboveNearBottom() {
        let size = CGSize(width: 200, height: 40)
        let caret = CGRect(x: 500, y: 400, width: 2, height: 18)
        let below = ScreenGeometry.panelOrigin(below: caret, size: size, visibleFrame: primary)
        #expect(below == CGPoint(x: 401, y: 352))

        let nearBottom = CGRect(x: 500, y: 20, width: 2, height: 18)
        let flipped = ScreenGeometry.panelOrigin(below: nearBottom, size: size, visibleFrame: primary)
        #expect(flipped.y == 46)
    }

    @Test func clampsPanelInsideScreenEdges() {
        let size = CGSize(width: 200, height: 40)
        let atLeftEdge = ScreenGeometry.panelOrigin(below: CGRect(x: 5, y: 400, width: 2, height: 18), size: size, visibleFrame: primary)
        #expect(atLeftEdge.x == 0)
        let atRightEdge = ScreenGeometry.panelOrigin(below: CGRect(x: 1435, y: 400, width: 2, height: 18), size: size, visibleFrame: primary)
        #expect(atRightEdge.x == 1240)
    }

    @Test func topCenterFallback() {
        let o = ScreenGeometry.topCenterOrigin(size: CGSize(width: 200, height: 40), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        #expect(o == CGPoint(x: 620, y: 823))
    }
}
