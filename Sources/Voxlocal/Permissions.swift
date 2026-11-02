import AppKit
import AVFoundation
import ApplicationServices

/// Microphone and Accessibility permission checks, with plain-language first-run prompts.
enum Permissions {
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Shows macOS's own "would like to control this computer" prompt, which links to Settings.
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    /// Explains why each permission is needed before macOS asks.
    @MainActor
    static func runFirstRunFlow() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            explain(
                title: "Voxlocal needs your microphone",
                body: "Audio is recorded only while you hold the hotkey, kept in memory, transcribed on this Mac, and then discarded. It is never saved to disk or sent anywhere."
            )
            _ = await requestMicrophone()
        }
        if !accessibilityGranted {
            explain(
                title: "Voxlocal needs Accessibility access",
                body: "This lets Voxlocal notice the hotkey from any app and paste the transcript at your cursor by pressing ⌘V for you.\n\nIn the next window, open System Settings and turn on Voxlocal under Privacy & Security → Accessibility. Voxlocal starts working as soon as it's on."
            )
            promptAccessibility()
        }
    }

    @MainActor
    private static func explain(title: String, body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }
}
