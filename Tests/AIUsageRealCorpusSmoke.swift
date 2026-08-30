import Foundation

@main
struct AIUsageRealCorpusSmoke {
    static func main() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
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
            )
        ]

        for (name, operation) in sources {
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
    }
}
