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
    static let automaticRefreshInterval: TimeInterval = 30 * 60
    static let currentSnapshotSchemaVersion = 4

    @Published private(set) var accounts: [AccountSnapshot] = []
    @Published private(set) var refreshingProviderIDs: Set<String> = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var errors: [String: String] = [:]

    var isRefreshing: Bool {
        !refreshingProviderIDs.isEmpty
    }

    // Precomputed metrics for 7-day and 30-day views
    @Published private(set) var metrics7Days: ChartMetrics = ChartMetrics(points: [], totalTokens: 0, averageTokens: 0, peak: nil)
    @Published private(set) var metrics30Days: ChartMetrics = ChartMetrics(points: [], totalTokens: 0, averageTokens: 0, peak: nil)

    private var refreshLoop: Task<Void, Never>?
    private var providerRefreshTasks: [String: Task<Void, Never>] = [:]
    private var providerRefreshGenerations: [String: UUID] = [:]
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
            ClaudeProvider(),
            AGYProvider(),
            GrokProvider(),
            QwenTokenPlanProvider()
        ]

        // Load cached snapshot instantly for 0ms cold-start
        let cached = UsageDiskCache.shared.load()
        if !cached.isEmpty {
            self.accounts = cached.sorted { $0.sortOrder < $1.sortOrder }
            self.lastRefresh = cached.map(\.updatedAt).max()
            recomputeMetrics()
        }
    }

    func start() {
        guard refreshLoop == nil else { return }

        refreshLoop = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }

            // Cached data renders immediately. Entering the page only refreshes
            // missing or stale accounts; explicit buttons can refresh on demand.
            await refreshStaleAccounts()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000_000) // 15 minutes
                guard !Task.isCancelled else { break }
                await refreshStaleAccounts()
            }
        }
    }

    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil

        providerRefreshTasks.values.forEach { $0.cancel() }
        providerRefreshTasks.removeAll()
        providerRefreshGenerations.removeAll()
        refreshingProviderIDs.removeAll()
    }

    func refresh() async {
        for provider in providers {
            scheduleRefresh(for: provider)
        }
    }

    func refresh(providerID: String) async {
        guard let provider = providers.first(where: {
            $0.providerID == providerID
        }) else {
            return
        }

        scheduleRefresh(for: provider)
    }

    func isRefreshing(providerID: String) -> Bool {
        refreshingProviderIDs.contains(providerID)
    }

    private func refreshStaleAccounts(referenceDate: Date = Date()) async {
        for provider in providers {
            let cached = accounts.first { $0.id == provider.providerID }
            let isStale = cached.map {
                $0.schemaVersion != Self.currentSnapshotSchemaVersion
                    || referenceDate.timeIntervalSince($0.updatedAt)
                        >= Self.automaticRefreshInterval
            } ?? true

            if isStale {
                scheduleRefresh(for: provider)
            }
        }
    }

    private func scheduleRefresh(for provider: any UsageProvider) {
        let providerID = provider.providerID
        guard providerRefreshTasks[providerID] == nil else { return }

        let generation = UUID()
        providerRefreshGenerations[providerID] = generation
        refreshingProviderIDs.insert(providerID)
        errors.removeValue(forKey: providerID)

        providerRefreshTasks[providerID] = Task(priority: .utility) { [weak self] in
            defer {
                self?.finishRefreshing(
                    providerID: providerID,
                    generation: generation
                )
            }

            do {
                let snapshot = try await provider.fetch()
                try Task.checkCancellation()
                self?.publish(snapshot, for: providerID)
            } catch is CancellationError {
                // Leaving the page cancels in-flight work without replacing cached data.
            } catch {
                self?.publish(error: error, for: providerID)
            }
        }
    }

    private func publish(_ snapshot: AccountSnapshot, for providerID: String) {
        var nextAccounts = accounts
        let previous = nextAccounts.first { $0.id == snapshot.id }
        let merged = AccountSnapshot(
            id: snapshot.id,
            sortOrder: snapshot.sortOrder,
            provider: snapshot.provider,
            billingKind: snapshot.billingKind ?? previous?.billingKind,
            displayName: snapshot.displayName,
            email: snapshot.email ?? previous?.email,
            plan: snapshot.plan ?? previous?.plan,
            quotaWindows: snapshot.quotaAvailable == false
                ? previous?.quotaWindows ?? []
                : snapshot.quotaWindows,
            activity: snapshot.activityAvailable == false
                ? previous?.activity ?? []
                : snapshot.activity,
            dailyActivity: snapshot.activityAvailable == false
                ? previous?.dailyActivity ?? []
                : snapshot.dailyActivity,
            modelActivity: snapshot.activityAvailable == false
                ? previous?.modelActivity ?? []
                : snapshot.modelActivity,
            updatedAt: snapshot.updatedAt,
            sourceLabel: snapshot.sourceLabel,
            confidence: snapshot.confidence,
            statusMessage: snapshot.statusMessage,
            schemaVersion: snapshot.schemaVersion,
            quotaAvailable: snapshot.quotaAvailable,
            activityAvailable: snapshot.activityAvailable
        )
        nextAccounts.removeAll { $0.id == snapshot.id }
        nextAccounts.append(merged)

        accounts = nextAccounts.sorted { $0.sortOrder < $1.sortOrder }
        errors.removeValue(forKey: providerID)
        lastRefresh = merged.updatedAt
        recomputeMetrics()

        UsageDiskCache.shared.save(accounts)
    }

    private func publish(error: Error, for providerID: String) {
        errors[providerID] = error.localizedDescription
    }

    private func finishRefreshing(providerID: String, generation: UUID) {
        guard providerRefreshGenerations[providerID] == generation else {
            return
        }

        providerRefreshTasks.removeValue(forKey: providerID)
        providerRefreshGenerations.removeValue(forKey: providerID)
        refreshingProviderIDs.remove(providerID)
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
