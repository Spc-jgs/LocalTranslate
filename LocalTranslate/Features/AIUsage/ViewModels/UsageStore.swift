import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    static let automaticRefreshInterval: TimeInterval = 30 * 60
    static let currentSnapshotSchemaVersion = AccountSnapshot.currentSchemaVersion

    @Published private(set) var accounts: [AccountSnapshot] = []
    @Published private(set) var refreshingProviderIDs: Set<String> = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var errors: [String: String] = [:]

    var isRefreshing: Bool {
        !refreshingProviderIDs.isEmpty
    }

    // 聚合结果由 store 持有，只在 accounts 或统计周期变化时重算一次。
    @Published private(set) var dashboard = UsageDashboardSnapshot(
        accounts: [],
        range: .thirtyDays
    )

    @Published private(set) var historyRange: UsageHistoryRange = .thirtyDays

    private var refreshLoop: Task<Void, Never>?
    private var providerRefreshTasks: [String: Task<Void, Never>] = [:]
    private var providerRefreshGenerations: [String: UUID] = [:]

    // 账号来源由用户配置决定，不再写死在这里。
    private let settingsStore: UsageProviderSettingsStore
    private var providers: [any UsageProvider]
    private var settingsObserver: AnyCancellable?

    private init() {
        let settingsStore = UsageProviderSettingsStore.shared
        self.settingsStore = settingsStore
        self.providers = settingsStore.makeProviders()

        // Load cached snapshot instantly for 0ms cold-start
        let cached = UsageDiskCache.shared.load()
        if !cached.isEmpty {
            self.accounts = cached
                .filter { settingsStore.activeProviderIDs().contains($0.id) }
                .sorted { $0.sortOrder < $1.sortOrder }
            self.lastRefresh = accounts.map(\.updatedAt).max()
            recomputeDashboard()
        }

        settingsObserver = settingsStore.$settings
            .dropFirst()
            .sink { [weak self] _ in
                self?.reloadProviders()
            }
    }

    /// 账号配置变化后重建 Provider，并丢弃已删除账号的快照。
    private func reloadProviders() {
        providerRefreshTasks.values.forEach { $0.cancel() }
        providerRefreshTasks.removeAll()
        providerRefreshGenerations.removeAll()
        refreshingProviderIDs.removeAll()

        providers = settingsStore.makeProviders()

        let active = settingsStore.activeProviderIDs()
        accounts.removeAll { !active.contains($0.id) }
        errors = errors.filter { active.contains($0.key) }
        recomputeDashboard()
        UsageDiskCache.shared.save(accounts)

        guard refreshLoop != nil else { return }
        Task { [weak self] in
            await self?.refreshStaleAccounts()
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
        recomputeDashboard()

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

    func setHistoryRange(_ range: UsageHistoryRange) {
        guard range != historyRange else { return }
        historyRange = range
        recomputeDashboard()
    }

    private func recomputeDashboard() {
        dashboard = UsageDashboardSnapshot(
            accounts: accounts,
            range: historyRange
        )
    }
}
