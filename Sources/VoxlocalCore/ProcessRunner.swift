import Foundation

/// Runs a real subprocess from a fresh, empty temporary directory that is removed afterwards.
public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], stdin: String,
                    environment: [String: String], timeout: TimeInterval) async throws -> CommandResult {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxlocal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workDir
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            let finished = Once()
            process.terminationHandler = { p in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                finished.run {
                    continuation.resume(returning: CommandResult(
                        exitCode: p.terminationStatus,
                        stdout: String(decoding: data, as: UTF8.self)
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                finished.run { continuation.resume(throwing: CommandError.launchFailed(error.localizedDescription)) }
                return
            }
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finished.run {
                    process.terminate()
                    continuation.resume(throwing: CommandError.timedOut)
                }
            }
        }
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
