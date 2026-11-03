import Foundation
import ServiceManagement
import VoxlocalCore

/// Every user preference, persisted in UserDefaults (com.jlawcordova.voxlocal), plus a little
/// live status the Settings window shows. Read by the menu, the overlay, and Settings.
@MainActor
@Observable
final class AppSettings {
    // MARK: Persisted

    var model: ModelChoice { didSet { defaults.set(model.rawValue, forKey: Keys.model) } }
    var hotkey: HotkeyChoice { didSet { defaults.set(hotkey.rawValue, forKey: Keys.hotkey) } }
    /// Optional cleanup step; on by default. When on, transcript text (never audio) goes to Anthropic.
    var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanup) } }
    var showPill: Bool { didSet { defaults.set(showPill, forKey: Keys.showPill) } }
    var showCaret: Bool { didSet { defaults.set(showCaret, forKey: Keys.showCaret) } }
    var showPartialText: Bool { didSet { defaults.set(showPartialText, forKey: Keys.showPartialText) } }

    // MARK: Live status (not persisted)

    /// e.g. "Ready" or "Downloading large-v3-turbo… 42%".
    var modelStatus = "Starting…"
    var modelBusy = true
    var downloadedModels: Set<ModelChoice> = []
    /// Where `claude` was found, if anywhere.
    var claudePath: String?

    private let defaults = UserDefaults.standard

    init() {
        let d = defaults
        model = d.string(forKey: Keys.model).flatMap(ModelChoice.init(rawValue:)) ?? .default
        hotkey = d.string(forKey: Keys.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? .default
        cleanupEnabled = d.object(forKey: Keys.cleanup) as? Bool ?? true
        showPill = d.object(forKey: Keys.showPill) as? Bool ?? true
        showCaret = d.object(forKey: Keys.showCaret) as? Bool ?? true
        showPartialText = d.object(forKey: Keys.showPartialText) as? Bool ?? true
    }

    // MARK: Launch at login (stored by macOS, not by us)

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLoginError = error.localizedDescription
            }
            launchAtLoginTick += 1
        }
    }
    var launchAtLoginError: String?
    /// Bumped so SwiftUI re-reads `launchAtLogin`, whose truth lives in macOS.
    private(set) var launchAtLoginTick = 0

    private enum Keys {
        static let model = "model"
        static let hotkey = "hotkey"
        static let cleanup = "cleanupEnabled"
        static let showPill = "overlay.showPill"
        static let showCaret = "overlay.showCaret"
        static let showPartialText = "overlay.showPartialText"
    }
}
