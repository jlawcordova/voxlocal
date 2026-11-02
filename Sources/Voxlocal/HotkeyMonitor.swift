import AppKit
import VoxlocalCore

/// Watches a single modifier key system-wide and reports press and release.
/// Global monitoring of key events needs the Accessibility permission.
final class HotkeyMonitor {
    var hotkey: HotkeyChoice
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// Called when another key is typed while the hotkey is held (e.g. Option+Arrow), so the
    /// hold is a shortcut rather than dictation.
    var onInterrupt: () -> Void = {}

    private var monitors: [Any] = []
    private var isDown = false

    init(hotkey: HotkeyChoice) {
        self.hotkey = hotkey
    }

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] in self?.handleFlags($0) }
        let keys: (NSEvent) -> Void = { [weak self] _ in self?.handleKeyDown() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isDown = false
    }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else {
            // A different modifier joined in (e.g. Shift): treat as a shortcut, not dictation.
            if isDown { handleKeyDown() }
            return
        }
        let pressed = event.modifierFlags.contains(modifierFlag)
        if pressed, !isDown {
            isDown = true
            onPress()
        } else if !pressed, isDown {
            isDown = false
            onRelease()
        }
    }

    private func handleKeyDown() {
        guard isDown else { return }
        isDown = false
        onInterrupt()
    }

    private var modifierFlag: NSEvent.ModifierFlags {
        switch hotkey {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        }
    }
}
