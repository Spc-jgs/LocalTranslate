import Foundation
import Combine

struct ChartMetrics: Sendable {
    let points: [DailyActivity]
    let totalTokens: Int64
    let averageTokens: Int64
    let peak: DailyActivity?
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var accounts: [AccountSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var errors: [String: String] = [:]

    // Precomputed metrics for 7-day and 30-day views
    @Published private(set) var metrics7Days: ChartMetrics = ChartMetrics(points: [], totalTokens: 0, averageTokens: 0, peak: nil)
    @Published private(set) var metrics30Days: ChartMetrics = ChartMetrics(points: [], totalTokens: 0, averageTokens: 0, peak: nil)

    private var refreshLoop: Task<Void, Never>?
    private let providers: [any UsageProvider]

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser

        providers = [
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
            AGYProvider(),
            GrokProvider()
        ]

        // Load cached snapshot instantly for 0ms cold-start
        let cached = UsageDiskCache.shared.load()
        if !cached.isEmpty {
            self.accounts = cached.sorted { $0.sortOrder < $1.sortOrder }
            recomputeMetrics()
        }
    }

    func start() {
        guard refreshLoop == nil else { return }

        refreshLoop = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }

            // Only perform automatic initial refresh if local cache is completely empty
            if self.accounts.isEmpty {
                await refresh()
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000_000) // 15 minutes
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
    }

    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var nextAccounts = accounts
        var nextErrors: [String: String] = [:]

        // Fetch all providers concurrently in background utility priority
        await withTaskGroup(of: (String, Result<AccountSnapshot, Error>).self) { group in
            for provider in providers {
                let pid = provider.providerID
                group.addTask(priority: .utility) {
                    do {
                        let snapshot = try await provider.fetch()
                        return (pid, .success(snapshot))
                    } catch {
                        return (pid, .failure(error))
                    }
                }
            }

            for await (providerID, result) in group {
                guard !Task.isCancelled else { break }

                switch result {
                case .success(let snapshot):
                    nextAccounts.removeAll { $0.id == snapshot.id }
                    nextAccounts.append(snapshot)
                    nextErrors.removeValue(forKey: providerID)

                case .failure(let error):
                    nextErrors[providerID] = error.localizedDescription
                }
            }
        }

        // Single batch atomic update on MainActor to avoid multiple UI reflows
        self.accounts = nextAccounts.sorted { $0.sortOrder < $1.sortOrder }
        self.errors = nextErrors
        self.lastRefresh = Date()
        self.recomputeMetrics()

        UsageDiskCache.shared.save(accounts)
    }

    private func recomputeMetrics() {
        metrics7Days = computeMetrics(forDays: 7)
        metrics30Days = computeMetrics(forDays: 30)
    }

    private func computeMetrics(forDays days: Int) -> ChartMetrics {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today

        var byDay: [Date: DailyActivity] = [:]
        for offset in 0..<days {
            if let date = calendar.date(byAdding: .day, value: offset, to: start) {
                let day = calendar.startOfDay(for: date)
                byDay[day] = DailyActivity(date: day, tokens: 0, turns: 0)
            }
        }

        for account in accounts {
            for item in account.dailyActivity {
                let day = calendar.startOfDay(for: item.date)
                guard day >= start && day <= today else { continue }
                let current = byDay[day] ?? DailyActivity(date: day, tokens: 0, turns: 0)
                byDay[day] = DailyActivity(
                    date: day,
                    tokens: current.tokens + item.tokens,
                    turns: current.turns + item.turns
                )
            }
        }

        let points = byDay.values.sorted { $0.date < $1.date }
        let total = points.reduce(Int64(0)) { $0 + $1.tokens }
        let avg = points.isEmpty ? 0 : total / Int64(points.count)
        let peak = points.max { $0.tokens < $1.tokens }

        return ChartMetrics(
            points: points,
            totalTokens: total,
            averageTokens: avg,
            peak: peak
        )
    }
}
