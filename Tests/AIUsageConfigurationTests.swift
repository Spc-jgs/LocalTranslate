import Foundation

@main
struct AIUsageConfigurationTests {
    static func main() {
        relativePathStaysInsideHome()
        equivalentPathsShareCanonicalKey()
        cacheClearsAndUsesPrivatePermissions()
        grokRedirectsStayOnTheCredentialHost()
        print("AIUsageConfigurationTests: 11 passed")
    }

    private static func grokRedirectsStayOnTheCredentialHost() {
        expect(GrokRequestPolicy.allows(URL(string: "https://cli-chat-proxy.grok.com/v1/billing")), "官方 HTTPS 主机被拒绝")
        expect(!GrokRequestPolicy.allows(URL(string: "http://cli-chat-proxy.grok.com/v1/billing")), "Grok 凭据允许降级 HTTP")
        expect(!GrokRequestPolicy.allows(URL(string: "https://attacker.example/v1/billing")), "Grok 凭据允许跨域重定向")
    }

    private static func relativePathStaysInsideHome() {
        withTemporaryDirectory { home in
            expect(
                UsageCodexPath.resolve(".codex", homeDirectory: home)?.path
                    == home.appendingPathComponent(".codex").path,
                "正常相对路径没有解析"
            )
            expect(
                UsageCodexPath.resolve("../outside", homeDirectory: home) == nil,
                "父目录逃逸没有被拒绝"
            )
            expect(
                UsageCodexPath.resolve("/tmp/codex", homeDirectory: home) == nil,
                "绝对路径没有被拒绝"
            )
            expect(
                UsageCodexPath.resolve("~/.codex", homeDirectory: home) == nil,
                "波浪号路径没有被拒绝"
            )
        }
    }

    private static func equivalentPathsShareCanonicalKey() {
        withTemporaryDirectory { home in
            let target = home.appendingPathComponent(".codex", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories: true
            )
            let alias = home.appendingPathComponent("codex-link")
            try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

            let direct = UsageCodexPath.canonicalKey(".codex", homeDirectory: home)
            let linked = UsageCodexPath.canonicalKey("codex-link", homeDirectory: home)
            expect(direct == linked, "符号链接没有归一到同一 CODEX_HOME")
        }
    }

    private static func cacheClearsAndUsesPrivatePermissions() {
        withTemporaryDirectory { root in
            let file = root
                .appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent("snapshots.json")
            let cache = UsageDiskCache(cacheFileURL: file)
            cache.save([snapshot()])
            cache.flush()

            expect(FileManager.default.fileExists(atPath: file.path), "快照没有写入")
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
            expect(permissions == 0o600, "快照权限不是 0600")

            cache.save([])
            cache.flush()
            expect(!FileManager.default.fileExists(atPath: file.path), "空账号没有清除快照")
        }
    }

    private static func snapshot() -> AccountSnapshot {
        AccountSnapshot(
            id: "fixture",
            sortOrder: 0,
            provider: .openAI,
            billingKind: .local,
            displayName: "Fixture",
            email: nil,
            plan: nil,
            quotaWindows: [],
            activity: [],
            dailyActivity: [],
            modelActivity: [],
            updatedAt: Date(),
            sourceLabel: "fixture",
            confidence: .high,
            statusMessage: nil,
            schemaVersion: AccountSnapshot.currentSchemaVersion,
            quotaAvailable: false,
            activityAvailable: true,
            catchUp: nil,
            quotaStatus: nil,
            activityStatus: nil
        )
    }

    private static func withTemporaryDirectory(_ operation: (URL) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        operation(root)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
