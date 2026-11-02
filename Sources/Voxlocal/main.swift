import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // Menu-bar only: no Dock icon, no app menu. (Info.plist also sets LSUIElement.)
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
