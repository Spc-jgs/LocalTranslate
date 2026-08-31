import Foundation
import Combine

/// 一个 Codex 账号的本机位置。
///
/// Codex 是唯一「同一个人可能有 0、1、N 份」的来源：每个账号是一个独立的
/// `CODEX_HOME` 目录。其余来源路径固定，只需要开关。
nonisolated struct UsageCodexAccount: Codable, Identifiable, Sendable, Equatable {

    var id: String
    var displayName: String
    /// 相对用户主目录的路径，例如 `.codex`。
    var relativePath: String
    var sortOrder: Int

    var homeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativePath, isDirectory: true)
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: homeURL.path)
    }
}

/// AI 用量的账号来源配置。
///
/// 这些账号原先硬编码在 `UsageStore.init` 里，其中第二个 Codex 账号指向
/// `~/.codex_account2`——那是作者本机的目录。换一台机器，那张卡片就永远是
/// 空的或报错，而界面上没有任何地方能改名、删除或新增。
nonisolated struct UsageProviderSettings: Codable, Sendable, Equatable {

    var codexAccounts: [UsageCodexAccount]
    var disabledBuiltInProviderIDs: Set<String>

    static let empty = UsageProviderSettings(
        codexAccounts: [],
        disabledBuiltInProviderIDs: []
    )

    /// 首次运行时按本机实际存在的目录推断，而不是假设某个固定布局。
    static func detectedDefault() -> UsageProviderSettings {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let manager = FileManager.default

        // 保留历史 providerID，使既有磁盘缓存继续命中。
        var accounts: [UsageCodexAccount] = []

        let candidates: [(id: String, name: String, path: String, order: Int)] = [
            ("codex-plus-a", "Codex", ".codex", 10),
            ("codex-plus-b", "Codex 账号 2", ".codex_account2", 20)
        ]

        for candidate in candidates {
            let url = home.appendingPathComponent(
                candidate.path,
                isDirectory: true
            )
            guard manager.fileExists(atPath: url.path) else { continue }
            accounts.append(
                UsageCodexAccount(
                    id: candidate.id,
                    displayName: candidate.name,
                    relativePath: candidate.path,
                    sortOrder: candidate.order
                )
            )
        }

        // 一个 Codex 目录都没有时仍然给出主账号，让用户看得到该填什么。
        if accounts.isEmpty {
            accounts.append(
                UsageCodexAccount(
                    id: "codex-plus-a",
                    displayName: "Codex",
                    relativePath: ".codex",
                    sortOrder: 10
                )
            )
        }

        return UsageProviderSettings(
            codexAccounts: accounts,
            disabledBuiltInProviderIDs: []
        )
    }
}

/// 内置的固定路径来源，只能启用或停用。
nonisolated enum BuiltInUsageProvider: String, CaseIterable, Identifiable, Sendable {

    case claude = "claude-subscription"
    case antigravity = "agy-antigravity"
    case grok = "grok-supergrok"
    case qwen = "alibaba-qwen-token-plan-cn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .antigravity: return "Antigravity (AGY)"
        case .grok: return "SuperGrok"
        case .qwen: return "百炼 Qwen Token Plan"
        }
    }

    var sourceHint: String {
        switch self {
        case .claude: return "~/.claude"
        case .antigravity: return "~/.gemini"
        case .grok: return "~/.grok"
        case .qwen: return "~/.qwen"
        }
    }

    func makeProvider() -> any UsageProvider {
        switch self {
        case .claude: return ClaudeProvider()
        case .antigravity: return AGYProvider()
        case .grok: return GrokProvider()
        case .qwen: return QwenTokenPlanProvider()
        }
    }
}

/// 配置的持久化。
@MainActor
final class UsageProviderSettingsStore: ObservableObject {

    static let shared = UsageProviderSettingsStore()

    @Published private(set) var settings: UsageProviderSettings

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(
            forKey: AppSettings.Key.usageProviderConfigurations
        ), let decoded = try? JSONDecoder().decode(
            UsageProviderSettings.self,
            from: data
        ) {
            settings = decoded
        } else {
            settings = UsageProviderSettings.detectedDefault()
        }
    }

    func update(_ transform: (inout UsageProviderSettings) -> Void) {
        var next = settings
        transform(&next)
        guard next != settings else { return }
        settings = next
        persist()
    }

    func addCodexAccount() {
        update { settings in
            let order = (settings.codexAccounts.map(\.sortOrder).max() ?? 0) + 10
            settings.codexAccounts.append(
                UsageCodexAccount(
                    id: "codex-\(UUID().uuidString.prefix(8).lowercased())",
                    displayName: "新 Codex 账号",
                    relativePath: ".codex",
                    sortOrder: order
                )
            )
        }
    }

    func removeCodexAccount(id: String) {
        update { settings in
            settings.codexAccounts.removeAll { $0.id == id }
        }
    }

    func setEnabled(_ enabled: Bool, for provider: BuiltInUsageProvider) {
        update { settings in
            if enabled {
                settings.disabledBuiltInProviderIDs.remove(provider.rawValue)
            } else {
                settings.disabledBuiltInProviderIDs.insert(provider.rawValue)
            }
        }
    }

    func isEnabled(_ provider: BuiltInUsageProvider) -> Bool {
        !settings.disabledBuiltInProviderIDs.contains(provider.rawValue)
    }

    /// 当前配置对应的全部 Provider，`UsageStore` 据此构造。
    func makeProviders() -> [any UsageProvider] {
        var providers: [any UsageProvider] = settings.codexAccounts.map { account in
            CodexProvider(
                providerID: account.id,
                displayName: account.displayName,
                codexHome: account.homeURL,
                sortOrder: account.sortOrder
            )
        }

        for builtIn in BuiltInUsageProvider.allCases where isEnabled(builtIn) {
            providers.append(builtIn.makeProvider())
        }

        return providers
    }

    /// 当前配置下应当存在的账号 ID，用于清理已删除账号的缓存快照。
    func activeProviderIDs() -> Set<String> {
        var ids = Set(settings.codexAccounts.map(\.id))
        for builtIn in BuiltInUsageProvider.allCases where isEnabled(builtIn) {
            ids.insert(builtIn.rawValue)
        }
        return ids
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(
            data,
            forKey: AppSettings.Key.usageProviderConfigurations
        )
    }
}
