import AppKit
import VoxlocalCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum State: Equatable {
        case preparing(String)
        case idle
        case recording
        case transcribing
        case cleaning
        case error(String)
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let permissionsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cleanupItem = NSMenuItem(title: "Clean Up Grammar with Claude", action: nil, keyEquivalent: "")
    private let cleanupNote = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastResultItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private lazy var hotkeyMonitor = HotkeyMonitor(hotkey: hotkey)
    private var accessibilityPoll: Timer?
    private var recordingStartedAt: Date?
    private var cleaner = TranscriptCleaner(runner: ProcessRunner(), claudePath: nil)

    /// Holds shorter than this are treated as accidental taps.
    private let minimumHold: TimeInterval = 0.3

    private var state: State = .preparing("Starting…") {
        didSet { refreshUI() }
    }

    private var model: ModelChoice {
        UserDefaults.standard.string(forKey: "model").flatMap(ModelChoice.init(rawValue:)) ?? .default
    }

    /// Optional cleanup step; on by default. When on, transcript text (never audio) goes to Anthropic.
    private var cleanupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "cleanupEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cleanupEnabled") }
    }

    private var hotkey: HotkeyChoice {
        UserDefaults.standard.string(forKey: "hotkey").flatMap(HotkeyChoice.init(rawValue:)) ?? .default
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        refreshUI()

        hotkeyMonitor.onPress = { [weak self] in self?.startRecording() }
        hotkeyMonitor.onRelease = { [weak self] in self?.finishRecording() }
        hotkeyMonitor.onInterrupt = { [weak self] in self?.cancelRecording() }

        Task.detached {
            let path = ClaudeLocator.find()
            await MainActor.run { self.cleaner = TranscriptCleaner(runner: ProcessRunner(), claudePath: path) }
        }
        // Download/load the model while the permission prompts are up.
        Task { await loadModel() }
        Task {
            await Permissions.runFirstRunFlow()
            startHotkeyWhenTrusted()
        }
    }

    // MARK: - Model

    private func loadModel() async {
        let model = self.model
        await transcriber.prepare(model) { phase in
            Task { @MainActor [weak self] in self?.apply(phase) }
        }
    }

    private func apply(_ phase: Transcriber.Phase) {
        switch phase {
        case .idle: break
        case .downloading(let fraction):
            state = .preparing("Downloading \(model.rawValue) model… \(Int(fraction * 100))%")
        case .loading:
            state = .preparing("Loading \(model.rawValue) model…")
        case .ready:
            state = .idle
        case .failed(let message):
            state = .error("Model failed to load: \(message)")
        }
    }

    // MARK: - Hotkey

    /// Global key monitoring silently receives nothing until Accessibility is granted, so poll
    /// until it is and (re)start the monitor then.
    private func startHotkeyWhenTrusted() {
        hotkeyMonitor.start()
        refreshUI()
        guard !Permissions.accessibilityGranted else { return }
        accessibilityPoll?.invalidate()
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, Permissions.accessibilityGranted else { return }
                timer.invalidate()
                self.hotkeyMonitor.start()
                self.refreshUI()
            }
        }
    }

    // MARK: - Dictation

    private func startRecording() {
        guard state == .idle else { return }
        guard Permissions.microphoneGranted else {
            state = .error("Microphone access is off")
            return
        }
        do {
            try recorder.start()
            recordingStartedAt = Date()
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()
        state = .idle
    }

    private func finishRecording() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        let held = Date().timeIntervalSince(recordingStartedAt ?? Date())
        guard held >= minimumHold, samples.count > Int(AudioRecorder.sampleRate * minimumHold) else {
            state = .idle
            return
        }
        state = .transcribing
        Task {
            do {
                guard let raw = try await transcriber.transcribe(samples) else {
                    state = .idle
                    return
                }
                if cleanupEnabled { state = .cleaning }
                // Bounded by the cleaner's 5 s timeout; any failure yields the raw transcript.
                let outcome = await cleaner.clean(raw, enabled: cleanupEnabled)
                Paster.paste(outcome.text)
                lastResultItem.title = Self.describe(outcome)
                lastResultItem.isHidden = false
                state = .idle
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        cleanupItem.target = self
        cleanupItem.action = #selector(toggleCleanup)
        menu.addItem(cleanupItem)
        cleanupNote.isEnabled = false
        menu.addItem(cleanupNote)
        lastResultItem.isEnabled = false
        lastResultItem.isHidden = true
        menu.addItem(lastResultItem)
        menu.addItem(.separator())

        permissionsItem.target = self
        permissionsItem.action = #selector(fixPermissions)
        menu.addItem(permissionsItem)

        let modelsFolder = NSMenuItem(title: "Show Models Folder", action: #selector(showModelsFolder), keyEquivalent: "")
        modelsFolder.target = self
        menu.addItem(modelsFolder)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Voxlocal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func refreshUI() {
        let symbol: String
        let status: String
        switch state {
        case .preparing(let message):
            symbol = "arrow.down.circle"
            status = message
        case .idle:
            symbol = "mic"
            status = "Ready. Hold \(hotkey.displayName) to dictate"
        case .recording:
            symbol = "mic.fill"
            status = "Listening…"
        case .transcribing:
            symbol = "waveform"
            status = "Transcribing on-device…"
        case .cleaning:
            symbol = "text.badge.checkmark"
            status = "Cleaning up with Claude…"
        case .error(let message):
            symbol = "exclamationmark.triangle"
            status = message
        }

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Voxlocal: \(status)")
            image?.isTemplate = state != .recording
            button.image = state == .recording ? image?.tinted(.systemRed) : image
            // Visible reminder that transcript text leaves the Mac while cleanup is on.
            button.title = cleanupEnabled ? " ☁︎" : ""
            button.imagePosition = .imageLeft
            button.toolTip = "Voxlocal: \(status)" + (cleanupEnabled ? "\nCleanup ON: transcript text is sent to Anthropic" : "")
        }
        statusLine.title = status

        cleanupItem.state = cleanupEnabled ? .on : .off
        cleanupNote.title = cleanupEnabled
            ? "☁︎ On: transcript text (never audio) is sent to Anthropic"
            : "Off: nothing leaves this Mac"

        let missing = [
            Permissions.microphoneGranted ? nil : "Microphone",
            Permissions.accessibilityGranted ? nil : "Accessibility",
        ].compactMap { $0 }
        permissionsItem.isHidden = missing.isEmpty
        permissionsItem.title = "Grant \(missing.joined(separator: " & ")) Access…"
    }

    @objc private func toggleCleanup() {
        cleanupEnabled.toggle()
        refreshUI()
    }

    private static func describe(_ outcome: CleanupOutcome) -> String {
        switch outcome {
        case .cleaned: return "Last dictation: cleaned up by Claude"
        case .raw(_, .disabled): return "Last dictation: pasted as transcribed"
        case .raw(_, .claudeNotFound): return "Last dictation: raw (claude CLI not found)"
        case .raw(_, .timedOut): return "Last dictation: raw (cleanup timed out)"
        case .raw(_, .failed(let why)): return "Last dictation: raw (\(why.prefix(60)))"
        }
    }

    @objc private func fixPermissions() {
        if !Permissions.microphoneGranted {
            Task {
                if await !Permissions.requestMicrophone() { Permissions.openMicrophoneSettings() }
                refreshUI()
            }
        }
        if !Permissions.accessibilityGranted {
            Permissions.promptAccessibility()
            Permissions.openAccessibilitySettings()
            startHotkeyWhenTrusted()
        }
        if case .error = state { state = .idle }
    }

    @objc private func showModelsFolder() {
        try? FileManager.default.createDirectory(at: Transcriber.modelsRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Transcriber.modelsRoot)
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return withSymbolConfiguration(config) ?? self
    }
}
