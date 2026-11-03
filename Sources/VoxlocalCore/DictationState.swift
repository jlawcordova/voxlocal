import Foundation
import Observation

/// The single source of truth for where a dictation is, driven by the pipeline and read by
/// the menu-bar icon and the overlay.
///
///     idle → listening → transcribing → (polishing) → pasted → idle
///
/// plus `error` from any active phase, which, like `pasted`, returns to idle on its own.
@MainActor
@Observable
public final class DictationState {
    public enum Phase: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        case polishing
        /// `raw` is true when cleanup was on but fell back to the unpolished transcript.
        case pasted(raw: Bool)
        case error(String)

        public var isActive: Bool { self != .idle }
    }

    public private(set) var phase: Phase = .idle
    /// Microphone level while listening, 0...1.
    public private(set) var level: Float = 0
    /// Text decoded so far while transcribing.
    public private(set) var partialText = ""

    /// How long `pasted` and `error` stay visible before returning to idle.
    public var pastedDuration: Duration
    public var errorDuration: Duration

    /// Bumped on every transition so a stale auto-return can't clobber a newer dictation.
    private var generation = 0

    public init(pastedDuration: Duration = .milliseconds(600), errorDuration: Duration = .milliseconds(1800)) {
        self.pastedDuration = pastedDuration
        self.errorDuration = errorDuration
    }

    // MARK: - Transitions

    public static func canTransition(from: Phase, to: Phase) -> Bool {
        switch (from, to) {
        // A new dictation may start while the last result is still fading out.
        case (.idle, .listening), (.pasted, .listening), (.error, .listening):
            return true
        case (.listening, .transcribing):
            return true
        // Too-short hold, interrupted shortcut, or nothing heard.
        case (.listening, .idle), (.transcribing, .idle):
            return true
        case (.transcribing, .polishing):
            return true
        case (.transcribing, .pasted), (.polishing, .pasted):
            return true
        case (.listening, .error), (.transcribing, .error), (.polishing, .error), (.idle, .error):
            return true
        case (.pasted, .idle), (.error, .idle):
            return true
        default:
            return false
        }
    }

    @discardableResult
    public func startListening() -> Bool { move(to: .listening) }

    @discardableResult
    public func beginTranscribing() -> Bool { move(to: .transcribing) }

    @discardableResult
    public func beginPolishing() -> Bool { move(to: .polishing) }

    @discardableResult
    public func finishPasted(raw: Bool) -> Bool { move(to: .pasted(raw: raw)) }

    @discardableResult
    public func fail(_ message: String) -> Bool { move(to: .error(message)) }

    /// Abandons the current dictation without a result.
    @discardableResult
    public func cancel() -> Bool { move(to: .idle) }

    public func updateLevel(_ value: Float) {
        guard phase == .listening else { return }
        level = min(max(value, 0), 1)
    }

    public func updatePartial(_ text: String) {
        guard phase == .transcribing else { return }
        partialText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func move(to next: Phase) -> Bool {
        guard Self.canTransition(from: phase, to: next) else { return false }
        phase = next
        generation += 1
        if next == .listening { level = 0 }
        if next == .listening || next == .transcribing { partialText = "" }

        switch next {
        case .pasted: scheduleReturnToIdle(after: pastedDuration)
        case .error: scheduleReturnToIdle(after: errorDuration)
        default: break
        }
        return true
    }

    private func scheduleReturnToIdle(after delay: Duration) {
        let expected = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.generation == expected else { return }
            self.move(to: .idle)
        }
    }

    // MARK: - Display helpers

    /// The last `limit` characters, with a leading ellipsis when cut, so the newest words show.
    public nonisolated static func tail(_ text: String, limit: Int = 60) -> String {
        guard text.count > limit else { return text }
        return "…" + text.suffix(limit).trimmingCharacters(in: .whitespaces)
    }
}
