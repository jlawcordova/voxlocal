import AppKit
import ApplicationServices
import Carbon.HIToolbox
import VoxlocalCore

/// Finds where the text caret is in the focused app, via the Accessibility API.
///
/// It reads only the selection range and the on-screen bounds of that range, never the field's
/// text. Secure (password) fields are detected and reported as such so nothing is drawn there.
enum CaretLocator {
    enum Result: Equatable {
        /// Caret rect in AppKit screen coordinates.
        case caret(CGRect)
        /// The focused element is a password field, or secure input is on.
        case secure
        /// No usable caret (terminals, many Electron/Chromium views, AX errors).
        case unavailable
    }

    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        // Keep a hung app from stalling the poll.
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }()

    /// Synchronous AX IPC: call from a background queue.
    static func locate(primaryHeight: CGFloat, screens: [CGRect]) -> Result {
        if IsSecureEventInputEnabled() { return .secure }

        guard let focused: AXUIElement = copy(systemWide, kAXFocusedUIElementAttribute) else { return .unavailable }
        AXUIElementSetMessagingTimeout(focused, 0.05)

        let role: String? = copy(focused, kAXRoleAttribute)
        let subrole: String? = copy(focused, kAXSubroleAttribute)
        if subrole == kAXSecureTextFieldSubrole || role == "AXSecureTextField" { return .secure }

        guard let rangeValue: AXValue = copy(focused, kAXSelectedTextRangeAttribute) else { return .unavailable }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return .unavailable }

        guard let axRect = caretBounds(in: focused, range: range) else { return .unavailable }
        let rect = ScreenGeometry.appKitRect(fromAX: axRect, primaryHeight: primaryHeight)
        return ScreenGeometry.isUsableCaret(rect, screens: screens) ? .caret(rect) : .unavailable
    }

    /// For an insertion point (empty selection), derive the caret from the neighbouring
    /// characters' rects rather than the empty range's own rect: some apps return nothing for it,
    /// and TextEdit on macOS 27 returns it one line too high. Character rects are reliable.
    /// Only geometry is compared; no text is read.
    private static func caretBounds(in element: AXUIElement, range: CFRange) -> CGRect? {
        if range.length > 0 {
            return bounds(element, range).flatMap { $0.height > 0 ? $0 : nil }
        }
        let before = range.location > 0 ? bounds(element, CFRange(location: range.location - 1, length: 1)) : nil
        let after = bounds(element, CFRange(location: range.location, length: 1))
        let prev = before.flatMap { $0.height > 0 ? $0 : nil }
        let next = after.flatMap { $0.height > 0 ? $0 : nil }

        if let prev, let next, abs(prev.minY - next.minY) > prev.height / 2 {
            // Neighbours on different lines: the caret is at the start of the next one.
            return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        if let prev, next == nil, prev.width > prev.height * 2 {
            // The only neighbour is a line break (reported as a box running to the end of its
            // line), so the caret is at the start of the empty line below it. The empty range's
            // own x is reliable even where its y isn't.
            let x = bounds(element, range).map(\.minX) ?? prev.minX
            return CGRect(x: x, y: prev.maxY, width: 0, height: prev.height)
        }
        if let prev {
            return CGRect(x: prev.maxX, y: prev.minY, width: 0, height: prev.height)
        }
        if let next {
            return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        return bounds(element, range).flatMap { $0.height > 0 ? CGRect(x: $0.minX, y: $0.minY, width: 0, height: $0.height) : nil }
    }

    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var cfRange = range
        guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out)
        guard err == .success, let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
