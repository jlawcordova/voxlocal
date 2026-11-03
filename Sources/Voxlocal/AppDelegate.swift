import AppKit
import VoxlocalCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Whether the speech model is usable yet. Separate from the per-dictation state.
    enum ModelStatus: Equatable {
        case preparing(String)
        case ready
        case failed(String)
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let permissionsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cleanupItem = NSMenuItem(title: "Clean Up Grammar with Claude", action: nil, keyEquivalent: "")
    private let cleanupNote = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastResultItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let simulateItem = NSMenuItem(title: "Simulate States", action: nil, keyEquivalent: "")

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private lazy var hotkeyMonitor = HotkeyMonitor(hotkey: settings.hotkey)
    private var accessibilityPoll: Timer?
    private var recordingStartedAt: Date?
    private var cleaner = TranscriptCleaner(runner: ProcessRunner(), claudePath: nil)

    private let dictation = DictationState()
    private let settings = AppSettings()
    private lazy var settingsWindow = SettingsWindowController(settings: settings, actions: SettingsActions(
        deleteModel: { [weak self] in self?.deleteModel($0) },
        showModelsFolder: { [weak self] in self?.showModelsFolder() },
        // The bundled copy, so reading it needs no network.
        openPrivacy: { Bundle.main.url(forResource: "PRIVACY", withExtension: "md").map { _ = NSWorkspace.shared.open($0) } }
    ))
    private var overlay: OverlayController?
    private var simulation: Task<Void, Never>?
    private var livePreview: Task<Void, Never>?
    /// Whether the live preview produced any text for the current dictation.
    private var hadLiveText = false

    /// Holds shorter than this are treated as accidental taps.
    private let minimumHold: TimeInterval = 0.3

    private var modelStatus: ModelStatus = .preparing("Starting…") {
        didSet {
            switch modelStatus {
            case .preparing(let message): settings.modelStatus = message; settings.modelBusy = true
            case .ready: settings.modelStatus = "Ready: \(settings.model.rawValue)"; settings.modelBusy = false
            case .failed(let message): settings.modelStatus = message; settings.modelBusy = false
            }
            settings.downloadedModels = Transcriber.downloadedModels()
            refreshUI()
        }
    }

    private var cleanupEnabled: Bool {
        get { settings.cleanupEnabled }
        set { settings.cleanupEnabled = newValue }
    }

    private var hotkey: HotkeyChoice { settings.hotkey }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        refreshUI()
        overlay = OverlayController(state: dictation, settings: settings)
        observeDictation()
        observeSettings()
        settings.downloadedModels = Transcriber.downloadedModels()
        recorder.onLevel = { [weak self] level in self?.dictation.updateLevel(level) }
        // `open Voxlocal.app --args --simulate-states` runs the visual walkthrough at launch.
        if CommandLine.arguments.contains("--simulate-states") { simulateStates() }
        if CommandLine.arguments.contains("--open-settings") { openSettings() }

        hotkeyMonitor.onPress = { [weak self] in self?.startRecording() }
        hotkeyMonitor.onRelease = { [weak self] in self?.finishRecording() }
        hotkeyMonitor.onInterrupt = { [weak self] in self?.cancelRecording() }

        Task.detached {
            let path = ClaudeLocator.find()
            await MainActor.run {
                self.cleaner = TranscriptCleaner(runner: ProcessRunner(), claudePath: path)
                self.settings.claudePath = path?.path
            }
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
        let model = settings.model
        await transcriber.prepare(model) { phase in
            Task { @MainActor [weak self] in self?.apply(phase, for: model) }
        }
    }

    private func apply(_ phase: Transcriber.Phase, for model: ModelChoice) {
        // Ignore progress from a model the user has since switched away from.
        guard model == settings.model else { return }
        switch phase {
        case .idle: break
        case .downloading(let fraction):
            modelStatus = .preparing("Downloading \(model.rawValue) model (one time)… \(Int(fraction * 100))%")
        case .loading:
            modelStatus = .preparing("Loading \(model.rawValue) model…")
        case .ready:
            modelStatus = .ready
        case .failed(let message):
            modelStatus = .failed("Model failed to load: \(message)")
        }
    }

    private func deleteModel(_ model: ModelChoice) {
        Task {
            do {
                try await transcriber.delete(model)
            } catch {
                settings.modelStatus = error.localizedDescription
            }
            settings.downloadedModels = Transcriber.downloadedModels()
        }
    }

    /// Reacts to changes made in Settings: reload the model, swap the hotkey, refresh the menu.
    private func observeSettings() {
        let model = settings.model
        let hotkey = settings.hotkey
        withObservationTracking {
            _ = settings.model
            _ = settings.hotkey
            _ = settings.cleanupEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.settings.model != model {
                    self.modelStatus = .preparing("Switching to \(self.settings.model.rawValue)…")
                    Task { await self.loadModel() }
                }
                if self.settings.hotkey != hotkey {
                    self.hotkeyMonitor.hotkey = self.settings.hotkey
                    self.hotkeyMonitor.start()
                }
                self.refreshUI()
                self.observeSettings()
            }
        }
    }

    /// Keeps the menu-bar icon in step with the dictation state.
    private func observeDictation() {
        withObservationTracking {
            _ = dictation.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshUI()
                self?.observeDictation()
            }
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

    private var canStartDictation: Bool {
        guard modelStatus == .ready, simulation == nil else { return false }
        switch dictation.phase {
        case .idle, .pasted, .error: return true
        default: return false
        }
    }

    private func startRecording() {
        guard canStartDictation else { return }
        guard Permissions.microphoneGranted else {
            dictation.fail("Microphone access is off")
            return
        }
        do {
            try recorder.start()
            recordingStartedAt = Date()
            dictation.startListening()
            startLivePreview()
        } catch {
            dictation.fail(error.localizedDescription)
        }
    }

    private func cancelRecording() {
        guard dictation.phase == .listening else { return }
        stopLivePreview()
        _ = recorder.stop()
        dictation.cancel()
    }

    private func finishRecording() {
        guard dictation.phase == .listening else { return }
        stopLivePreview()
        let samples = recorder.stop()
        let held = Date().timeIntervalSince(recordingStartedAt ?? Date())
        guard held >= minimumHold, samples.count > Int(AudioRecorder.sampleRate * minimumHold) else {
            dictation.cancel()
            return
        }
        dictation.beginTranscribing()
        // If the live preview already showed text, keep it on screen through the final pass
        // rather than restarting from an empty partial.
        let showPartial = settings.showPartialText && !hadLiveText
        Task {
            do {
                let raw = try await transcriber.transcribe(samples) { [weak self] partial in
                    guard showPartial else { return }
                    Task { @MainActor in self?.dictation.updatePartial(partial) }
                }
                guard let raw else {
                    dictation.cancel()
                    return
                }
                let cleanup = cleanupEnabled
                if cleanup { dictation.beginPolishing() }
                // Bounded by the cleaner's 5 s timeout; any failure yields the raw transcript.
                let outcome = await cleaner.clean(raw, enabled: cleanup)
                // Paste first; the overlay only reflects what already happened.
                Paster.paste(outcome.text)
                if case .raw(_, let reason) = outcome, reason != .disabled {
                    dictation.finishPasted(raw: true)
                } else {
                    dictation.finishPasted(raw: false)
                }
                lastResultItem.title = Self.describe(outcome)
                lastResultItem.isHidden = false
            } catch {
                dictation.fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Live preview

    /// While the key is held, transcribe the latest audio about once a second and show it in
    /// the pill. Display only: the pasted text always comes from the full pass on release.
    private func startLivePreview() {
        hadLiveText = false
        guard settings.showPartialText, settings.showPill else { return }
        livePreview = Task { [weak self] in
            var language: String?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.dictation.phase == .listening else { return }
                // Whisper reads up to 30 s per window; the pill only shows the newest words,
                // so the last 10 s are enough and keep each pass quick.
                let (window, total) = self.recorder.snapshot(lastSeconds: 10)
                guard window.count >= Int(AudioRecorder.sampleRate * 0.8) else { continue }
                guard let result = await self.transcriber.preview(window, language: language),
                      !Task.isCancelled, self.dictation.phase == .listening
                else { continue }
                // Short clips misdetect easily (especially mixed-language speech), so detect
                // until ~2 s of audio exist, then keep that language for this dictation.
                if language == nil, total >= Int(AudioRecorder.sampleRate * 2) {
                    language = result.language
                }
                if !result.text.isEmpty {
                    self.hadLiveText = true
                    self.dictation.updatePartial(result.text)
                }
            }
        }
    }

    private func stopLivePreview() {
        livePreview?.cancel()
        livePreview = nil
    }

    // MARK: - Simulation

    /// Walks through every overlay state without the microphone, to check the visuals.
    @objc private func simulateStates() {
        guard simulation == nil, dictation.phase == .idle else { return }
        simulation = Task { @MainActor [weak self] in
            guard let self else { return }
            let s = self.dictation
            let sample = "Kumusta ka na? I was thinking na mag-lunch tayo sa Davao later. Maayong buntag, and see you tomorrow na lang ha."
            func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

            for pass in 0..<3 {
                s.startListening()
                let words = sample.split(separator: " ")
                for i in 0..<60 {
                    s.updateLevel(Float(abs(sin(Double(i) * 0.45))) * 0.9)
                    // Live preview: a few more words roughly every second of "speech".
                    if i % 6 == 5 { s.updatePartial(words.prefix((i + 1) / 3).joined(separator: " ")) }
                    await wait(50)
                }
                s.updatePartial(sample)
                s.beginTranscribing()
                await wait(900)
                switch pass {
                case 0:
                    s.beginPolishing(); await wait(1400); s.finishPasted(raw: false)
                case 1:
                    s.beginPolishing(); await wait(1400); s.finishPasted(raw: true)
                default:
                    s.fail("Simulated error: microphone unavailable")
                }
                await wait(2200)
            }
            self.simulation = nil
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self
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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        simulateItem.target = self
        simulateItem.action = #selector(simulateStates)
        simulateItem.isHidden = true
        menu.addItem(simulateItem)
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
        var recording = false
        switch (modelStatus, dictation.phase) {
        case (.preparing(let message), _):
            symbol = "arrow.down.circle"
            status = message
        case (.failed(let message), _):
            symbol = "exclamationmark.triangle"
            status = message
        case (.ready, .idle), (.ready, .pasted):
            symbol = "mic"
            status = "Ready. Hold \(hotkey.displayName) to dictate"
        case (.ready, .listening):
            symbol = "mic.fill"
            status = "Listening…"
            recording = true
        case (.ready, .transcribing):
            symbol = "waveform"
            status = "Transcribing on-device…"
        case (.ready, .polishing):
            symbol = "text.badge.checkmark"
            status = "Polishing with Claude…"
        case (.ready, .error(let message)):
            symbol = "exclamationmark.triangle"
            status = message
        }

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Voxlocal: \(status)")
            image?.isTemplate = !recording
            button.image = recording ? image?.tinted(.systemRed) : image
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

    @objc private func openSettings() {
        settingsWindow.show()
    }

    /// "Simulate States" is a debug item: shown only when ⌥ is held while opening the menu.
    func menuWillOpen(_ menu: NSMenu) {
        simulateItem.isHidden = !NSEvent.modifierFlags.contains(.option)
        refreshUI()
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
        if case .error = dictation.phase { dictation.cancel() }
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
