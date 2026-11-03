import AppKit
import SwiftUI
import VoxlocalCore

/// What the Settings window asks the app to do; the app owns the model and the hotkey.
@MainActor
struct SettingsActions {
    var deleteModel: (ModelChoice) -> Void
    var showModelsFolder: () -> Void
    var openPrivacy: () -> Void
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let actions: SettingsActions

    var body: some View {
        Form {
            Section("Speech model (runs on this Mac)") {
                Picker("Model", selection: $settings.model) {
                    ForEach(ModelChoice.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .disabled(settings.modelBusy)
                LabeledContent("Status", value: settings.modelStatus)
                ForEach(ModelChoice.allCases.filter { settings.downloadedModels.contains($0) }, id: \.self) { model in
                    HStack {
                        Text(model.rawValue)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Transcriber.diskSize(of: model), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("Delete") { actions.deleteModel(model) }
                            .disabled(model == settings.model || settings.modelBusy)
                            .help(model == settings.model ? "In use" : "Remove this model from disk")
                    }
                }
                Text("A model is downloaded once from Hugging Face the first time you choose it. After that, transcription never uses the network.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show Models Folder", action: actions.showModelsFolder)
            }

            Section("Hotkey") {
                Picker("Hold to dictate", selection: $settings.hotkey) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                Text("Hold the key, speak, release. Typing another key while holding it cancels, so shortcuts like ⌥← still work.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Grammar cleanup") {
                Toggle("Clean up grammar with Claude", isOn: $settings.cleanupEnabled)
                Text(settings.cleanupEnabled
                     ? "☁︎ On: after transcription, the transcript text (never audio) is sent to Anthropic through your Claude Code login. If it fails or takes over 5 s, the raw transcript is pasted."
                     : "Off: nothing leaves this Mac.")
                    .font(.caption).foregroundStyle(settings.cleanupEnabled ? .orange : .secondary)
                LabeledContent("claude CLI", value: settings.claudePath ?? "Not found")
            }

            Section("Overlay") {
                Toggle("Show overlay pill", isOn: $settings.showPill)
                Toggle("Show caret indicator", isOn: $settings.showCaret)
                Toggle("Show live partial text", isOn: $settings.showPartialText)
                Text("Live text transcribes on-device while you speak and uses more processing. It's skipped when the pill is hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { _ = settings.launchAtLoginTick; return settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("What leaves this Mac (Privacy)…", action: actions.openPrivacy)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings
    private let actions: SettingsActions

    init(settings: AppSettings, actions: SettingsActions) {
        self.settings = settings
        self.actions = actions
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, actions: actions))
            let w = NSWindow(contentViewController: host)
            w.title = "Voxlocal Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // Menu-bar apps aren't active by default; bring the window forward.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
