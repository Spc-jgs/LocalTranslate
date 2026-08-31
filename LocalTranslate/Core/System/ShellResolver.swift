import Foundation

nonisolated enum ShellResolver {
    private static let lock = NSLock()
    // 访问全部经 `lock` 串行化；`nonisolated(unsafe)` 只是把这个既有事实
    // 告诉编译器，不改变运行时行为。
    private nonisolated(unsafe) static var cache: [String: URL] = [:]

    static func resolve(_ executable: String) throws -> URL {
        lock.lock()
        if let cached = cache[executable], FileManager.default.isExecutableFile(atPath: cached.path) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let candidates = [
            "\(home)/.local/bin/\(executable)",
            "\(home)/.npm-global/bin/\(executable)",
            "\(home)/.volta/bin/\(executable)",
            "\(home)/Library/pnpm/\(executable)",
            "/opt/homebrew/bin/\(executable)",
            "/usr/local/bin/\(executable)",
            "/usr/bin/\(executable)",
            "/bin/\(executable)"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            cacheResolved(executable, url: url)
            return url
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v \(shellQuoted(executable))"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw UsageHubError.executableNotFound(executable)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let lines = output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let last = lines.last,
           last.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: last) {
            let url = URL(fileURLWithPath: last)
            cacheResolved(executable, url: url)
            return url
        }

        throw UsageHubError.executableNotFound(executable)
    }

    private static func cacheResolved(_ executable: String, url: URL) {
        lock.lock()
        cache[executable] = url
        lock.unlock()
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
