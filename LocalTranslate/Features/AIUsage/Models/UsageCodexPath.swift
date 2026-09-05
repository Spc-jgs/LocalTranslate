import Foundation

/// 把设置中的相对路径解析成唯一、仍位于用户主目录内的 `CODEX_HOME`。
///
/// 设置页允许用户手输路径；如果不先规范化，`.codex`、`foo/../.codex` 和指向
/// 同一目录的符号链接会被当成多个账号，仪表盘随后把同一批日志重复相加。
nonisolated enum UsageCodexPath {

    static func resolve(
        _ relativePath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~") else { return nil }

        let components = NSString(string: trimmed).pathComponents
        guard !components.contains("..") else { return nil }

        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = homeDirectory
            .appendingPathComponent(trimmed, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let homePath = home.path
        let candidatePath = candidate.path
        guard candidatePath.hasPrefix(homePath + "/") else { return nil }
        return candidate
    }

    static func canonicalKey(
        _ relativePath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        resolve(relativePath, homeDirectory: homeDirectory)?.path
    }
}
