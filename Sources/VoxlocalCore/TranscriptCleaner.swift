import Foundation

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String

    public init(exitCode: Int32, stdout: String) {
        self.exitCode = exitCode
        self.stdout = stdout
    }
}

public enum CommandError: Error, Equatable {
    case timedOut
    case launchFailed(String)
}

/// Runs a command with input on stdin. Abstracted so tests can stand in for the real `claude`.
public protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String], stdin: String,
             environment: [String: String], timeout: TimeInterval) async throws -> CommandResult
}

/// What happened to a transcript on its way to the cursor.
public enum CleanupOutcome: Equatable, Sendable {
    case cleaned(String)
    case raw(String, reason: FallbackReason)

    /// The text to paste: cleaned when possible, the original transcript otherwise.
    public var text: String {
        switch self {
        case .cleaned(let t), .raw(let t, _): return t
        }
    }
}

public enum FallbackReason: Equatable, Sendable {
    case disabled
    case claudeNotFound
    case timedOut
    case failed(String)
}

/// Sends only transcript text to `claude -p`. Any problem (switched off, not installed,
/// timed out, error, odd reply) falls back to the raw transcript, so pasting never depends on it.
public struct TranscriptCleaner: Sendable {
    public static let defaultTimeout: TimeInterval = 5

    let runner: any CommandRunning
    let claudePath: URL?
    let timeout: TimeInterval

    public init(runner: any CommandRunning, claudePath: URL?, timeout: TimeInterval = defaultTimeout) {
        self.runner = runner
        self.claudePath = claudePath
        self.timeout = timeout
    }

    public func clean(_ transcript: String, enabled: Bool) async -> CleanupOutcome {
        guard enabled else { return .raw(transcript, reason: .disabled) }
        guard let claudePath else { return .raw(transcript, reason: .claudeNotFound) }

        do {
            let result = try await runner.run(
                executable: claudePath,
                arguments: CleanupRequest.arguments(),
                stdin: CleanupRequest.userMessage(for: transcript),
                environment: CleanupRequest.environmentOverrides,
                timeout: timeout
            )
            // A failed call may still print a JSON error; prefer its message.
            do {
                let cleaned = try CleanupRequest.parse(result.stdout, original: transcript)
                guard result.exitCode == 0 else {
                    return .raw(transcript, reason: .failed("claude exited with status \(result.exitCode)"))
                }
                return .cleaned(cleaned)
            } catch CleanupRequest.ParseError.reportedError(let message) {
                return .raw(transcript, reason: .failed(message))
            } catch {
                let detail = result.exitCode == 0 ? "unusable reply (\(error))" : "claude exited with status \(result.exitCode)"
                return .raw(transcript, reason: .failed(detail))
            }
        } catch CommandError.timedOut {
            return .raw(transcript, reason: .timedOut)
        } catch {
            return .raw(transcript, reason: .failed(String(describing: error)))
        }
    }
}
