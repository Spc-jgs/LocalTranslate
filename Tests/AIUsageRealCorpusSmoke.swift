import Foundation

@main
struct AIUsageRealCorpusSmoke {
    static func main() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let requestedProviderIDs = Set(CommandLine.arguments.dropFirst())
        let sources: [(String, () async throws -> IndexedActivitySnapshot)] = [
            (
                "codex-plus-a",
                {
                    try await UsageActivityIndexer.shared.scanCodex(
                        providerID: "codex-plus-a",
                        codexHome: home.appendingPathComponent(".codex", isDirectory: true)
                    )
                }
            ),
            (
                "codex-plus-b",
                {
                    try await UsageActivityIndexer.shared.scanCodex(
                        providerID: "codex-plus-b",
                        codexHome: home.appendingPathComponent(".codex_account2", isDirectory: true)
                    )
                }
            ),
            (
                "grok-supergrok",
                {
                    try await UsageActivityIndexer.shared.scanGrok(
                        providerID: "grok-supergrok"
                    )
                }
            ),
            (
                "agy-antigravity",
                {
                    try await UsageActivityIndexer.shared.scanAGY(
                        providerID: "agy-antigravity"
                    )
                }
            ),
            (
                "claude-subscription",
                {
                    try await UsageActivityIndexer.shared.scanClaude(
                        providerID: "claude-subscription",
                        claudeHome: home.appendingPathComponent(".claude", isDirectory: true)
                    )
                }
            ),
            (
                "alibaba-qwen-token-plan-cn",
                {
                    try await UsageActivityIndexer.shared.scanQwen(
                        providerID: "alibaba-qwen-token-plan-cn",
                        qwenHome: home.appendingPathComponent(".qwen", isDirectory: true)
                    )
                }
            )
        ]

        for (name, operation) in sources where requestedProviderIDs.isEmpty
            || requestedProviderIDs.contains(name) {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let snapshot = try await operation()
                let today = snapshot.periodActivity.first {
                    $0.period == .today
                }?.tokens ?? 0
                let elapsed = start.duration(to: clock.now)
                print(
                    "\(name): files=\(snapshot.indexedFiles) "
                        + "today=\(today) pending=\(snapshot.catchUpPending) "
                        + "elapsed=\(elapsed)"
                )
            } catch {
                print("\(name): soft-failure=\(type(of: error))")
            }
        }

        let providers: [any UsageProvider] = [
            CodexProvider(
                providerID: "codex-plus-a",
                displayName: "Codex Plus A",
                codexHome: home.appendingPathComponent(".codex", isDirectory: true),
                sortOrder: 10
            ),
            CodexProvider(
                providerID: "codex-plus-b",
                displayName: "Codex Plus B",
                codexHome: home.appendingPathComponent(".codex_account2", isDirectory: true),
                sortOrder: 20
            ),
            ClaudeProvider(),
            AGYProvider(),
            GrokProvider()
        ]
        for provider in providers where requestedProviderIDs.isEmpty
            || requestedProviderIDs.contains(provider.providerID) {
            do {
                let snapshot = try await provider.fetch()
                let today = snapshot.dailyActivity.first {
                    Calendar.current.isDateInToday($0.date)
                }?.tokens ?? 0
                let yesterdayDate = Calendar.current.date(
                    byAdding: .day,
                    value: -1,
                    to: Date()
                ) ?? Date()
                let yesterday = snapshot.dailyActivity.first {
                    Calendar.current.isDate($0.date, inSameDayAs: yesterdayDate)
                }?.tokens ?? 0
                let pricedModels = snapshot.modelActivity.filter {
                    $0.period == .today && $0.costUSD != nil
                }.count
                let todayModels = Set(
                    snapshot.modelActivity
                        .filter { $0.period == .today }
                        .map(\.modelID)
                ).sorted().joined(separator: ",")
                print(
                    "\(provider.providerID): provider-today=\(today) "
                        + "provider-yesterday=\(yesterday) "
                        + "priced-models=\(pricedModels) "
                        + "quota-windows=\(snapshot.quotaWindows.count) "
                        + "today-models=\(todayModels.isEmpty ? "none" : todayModels)"
                )
            } catch {
                print("\(provider.providerID): provider-soft-failure=\(type(of: error))")
            }
        }
    }
}
