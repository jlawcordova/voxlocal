import Foundation
import Testing
@testable import VoxlocalCore

/// Stands in for `claude`: records what it was asked and replies with a canned result.
private final class FakeRunner: CommandRunning, @unchecked Sendable {
    enum Reply {
        case result(CommandResult)
        case error(Error)
    }

    let reply: Reply
    private(set) var calls: [(arguments: [String], stdin: String, environment: [String: String], timeout: TimeInterval)] = []

    init(_ reply: Reply) { self.reply = reply }

    func run(executable: URL, arguments: [String], stdin: String,
             environment: [String: String], timeout: TimeInterval) async throws -> CommandResult {
        calls.append((arguments, stdin, environment, timeout))
        switch reply {
        case .result(let r): return r
        case .error(let e): throw e
        }
    }
}

private func json(_ result: String, isError: Bool = false) -> String {
    let object: [String: Any] = ["type": "result", "is_error": isError, "result": result]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private let claude = URL(fileURLWithPath: "/usr/local/bin/claude")
private let raw = "kumusta ka na i was thinking na mag lunch tayo"

@Suite struct CleanupRequestTests {
    @Test func callIsAPureTextTransform() {
        let args = CleanupRequest.arguments()
        #expect(args.first == "-p")
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--disable-slash-commands"))
        #expect(args.contains("--no-session-persistence"))
        // Tools and settings sources are explicitly emptied.
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
        #expect(args[args.firstIndex(of: "--setting-sources")! + 1] == "")
        #expect(args[args.firstIndex(of: "--model")! + 1] == "haiku")
        // Anything that would grant permissions or file access must never appear.
        for forbidden in ["--add-dir", "--allowedTools", "--dangerously-skip-permissions", "--mcp-config", "--continue", "--resume"] {
            #expect(!args.contains(forbidden))
        }
    }

    @Test func promptKeepsLanguageMixAndForbidsTranslation() {
        let prompt = CleanupRequest.systemPrompt
        #expect(prompt.contains("Do NOT translate"))
        #expect(prompt.contains("Keep the original language mix"))
        #expect(prompt.contains("Do NOT rephrase"))
        #expect(prompt.contains("Output only the cleaned text"))
    }

    @Test func transcriptIsWrappedAsData() {
        #expect(CleanupRequest.userMessage(for: raw) == "<transcript>\n\(raw)\n</transcript>")
    }

    @Test func parsesResultAndStripsWrappers() throws {
        #expect(try CleanupRequest.parse(json("  Kumusta ka na?  "), original: raw) == "Kumusta ka na?")
        #expect(try CleanupRequest.parse(json("\"Kumusta ka na?\""), original: raw) == "Kumusta ka na?")
        #expect(try CleanupRequest.parse(json("<transcript>Kumusta ka na?</transcript>"), original: raw) == "Kumusta ka na?")
    }

    @Test func rejectsBadReplies() {
        #expect(throws: CleanupRequest.ParseError.malformed) { try CleanupRequest.parse("not json", original: raw) }
        #expect(throws: CleanupRequest.ParseError.empty) { try CleanupRequest.parse(json("   "), original: raw) }
        #expect(throws: CleanupRequest.ParseError.reportedError("Failed to authenticate")) {
            try CleanupRequest.parse(json("Failed to authenticate", isError: true), original: raw)
        }
        let essay = String(repeating: "Here is a long answer to your question. ", count: 10)
        #expect(throws: CleanupRequest.ParseError.implausible) { try CleanupRequest.parse(json(essay), original: raw) }
    }
}

@Suite struct TranscriptCleanerFallbackTests {
    @Test func successReturnsCleanedTextAndSendsOnlyTheTranscript() async {
        let runner = FakeRunner(.result(CommandResult(exitCode: 0, stdout: json("Kumusta ka na? I was thinking na mag-lunch tayo."))))
        let outcome = await TranscriptCleaner(runner: runner, claudePath: claude).clean(raw, enabled: true)
        #expect(outcome == .cleaned("Kumusta ka na? I was thinking na mag-lunch tayo."))
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].stdin == CleanupRequest.userMessage(for: raw))
        #expect(runner.calls[0].timeout == 5)
        #expect(runner.calls[0].environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
    }

    @Test func disabledNeverCallsClaude() async {
        let runner = FakeRunner(.result(CommandResult(exitCode: 0, stdout: json("x"))))
        let outcome = await TranscriptCleaner(runner: runner, claudePath: claude).clean(raw, enabled: false)
        #expect(outcome == .raw(raw, reason: .disabled))
        #expect(runner.calls.isEmpty)
    }

    @Test func missingClaudeFallsBack() async {
        let runner = FakeRunner(.result(CommandResult(exitCode: 0, stdout: json("x"))))
        let outcome = await TranscriptCleaner(runner: runner, claudePath: nil).clean(raw, enabled: true)
        #expect(outcome == .raw(raw, reason: .claudeNotFound))
        #expect(runner.calls.isEmpty)
    }

    @Test func timeoutFallsBack() async {
        let outcome = await TranscriptCleaner(runner: FakeRunner(.error(CommandError.timedOut)), claudePath: claude)
            .clean(raw, enabled: true)
        #expect(outcome == .raw(raw, reason: .timedOut))
        #expect(outcome.text == raw)
    }

    @Test func authErrorFallsBack() async {
        let stdout = json("Failed to authenticate: OAuth session expired", isError: true)
        let outcome = await TranscriptCleaner(runner: FakeRunner(.result(CommandResult(exitCode: 1, stdout: stdout))), claudePath: claude)
            .clean(raw, enabled: true)
        #expect(outcome == .raw(raw, reason: .failed("Failed to authenticate: OAuth session expired")))
    }

    @Test func nonZeroExitWithGarbageFallsBack() async {
        let outcome = await TranscriptCleaner(runner: FakeRunner(.result(CommandResult(exitCode: 2, stdout: ""))), claudePath: claude)
            .clean(raw, enabled: true)
        #expect(outcome == .raw(raw, reason: .failed("claude exited with status 2")))
    }

    @Test func launchFailureFallsBack() async {
        let outcome = await TranscriptCleaner(runner: FakeRunner(.error(CommandError.launchFailed("no such file"))), claudePath: claude)
            .clean(raw, enabled: true)
        #expect(outcome.text == raw)
    }

    @Test func realProcessRunnerTimesOutAndRunsInEmptyDirectory() async throws {
        let runner = ProcessRunner()
        // `pwd; ls -A` proves the working directory is fresh and empty.
        let listing = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "ls -A; pwd"],
                                           stdin: "", environment: [:], timeout: 5)
        let lines = listing.stdout.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].contains("voxlocal-"))

        let start = Date()
        await #expect(throws: CommandError.timedOut) {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
                                     stdin: "", environment: [:], timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
