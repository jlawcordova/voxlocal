import Foundation

/// The single modifier keys that can act as the push-to-talk key.
public enum HotkeyChoice: String, CaseIterable, Codable, Sendable {
    case rightOption
    case rightCommand
    case rightControl
    case fn

    public static let `default` = HotkeyChoice.rightOption

    /// macOS virtual key code reported in flagsChanged events.
    public var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    public var displayName: String {
        switch self {
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .rightControl: return "Right Control ⌃"
        case .fn: return "Fn / Globe"
        }
    }
}
