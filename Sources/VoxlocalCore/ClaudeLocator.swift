import Foundation

/// Finds the `claude` executable. Apps launched from Finder don't get the shell's PATH, so
/// check the usual install locations first, then ask a login shell.
public enum ClaudeLocator {
    public static func candidates(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
    }

    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        if let hit = candidates(home: home).first(where: { isExecutable($0.path) }) {
            return hit
        }
        return viaLoginShell()
    }

    private static func viaLoginShell() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}
