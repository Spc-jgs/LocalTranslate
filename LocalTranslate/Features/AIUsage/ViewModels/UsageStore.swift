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

    // 分片补齐：还欠一片的 Provider，以及它上一片的推进标尺。
    private var pendingCatchUp: Set<String> = []
    private var catchUpProgress: [String: Int64] = [:]
    private var dashboardRecomputeScheduled = false

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
        pendingCatchUp.removeAll()
        catchUpProgress.removeAll()

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
        // 合并写入会推迟落盘，离开页面前先把最后一份快照写掉。
        UsageDiskCache.shared.flush()

        refreshLoop?.cancel()
        refreshLoop = nil

        providerRefreshTasks.values.forEach { $0.cancel() }
        providerRefreshTasks.removeAll()
        providerRefreshGenerations.removeAll()
        refreshingProviderIDs.removeAll()
        pendingCatchUp.removeAll()
        catchUpProgress.removeAll()
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
            activityAvailable: snapshot.activityAvailable,
            catchUp: snapshot.catchUp
        )
        nextAccounts.removeAll { $0.id == snapshot.id }
        nextAccounts.append(merged)

        accounts = nextAccounts.sorted { $0.sortOrder < $1.sortOrder }
        errors.removeValue(forKey: providerID)
        lastRefresh = merged.updatedAt
        scheduleDashboardRecompute()

        UsageDiskCache.shared.save(accounts)
        noteCatchUp(merged.catchUp, for: providerID)
    }

    /// 一轮扫描被预算截断后，决定要不要立刻扫下一片。
    ///
    /// 不这么做的话 `catchUpPending` 就只是一句 UI 文案：单片预算 32 MB，
    /// 而唯一的推进器是 15 分钟醒一次、只刷新超过 30 分钟快照的 `refreshLoop`，
    /// 实际推进速率是 32 MB / 30 分钟。本机 1.5 GB 的 Codex 日志要靠这个补齐
    /// 需要页面常开约一天，用量数字在那之前一直偏低且看不出偏低。
    ///
    /// 单片预算不放宽——重活仍然带预算、带取消路径，改的只是「什么时候扫下一片」。
    private func noteCatchUp(_ catchUp: UsageCatchUpProgress?, for providerID: String) {
        guard let catchUp, catchUp.pending else {
            catchUpProgress.removeValue(forKey: providerID)
            pendingCatchUp.remove(providerID)
            return
        }
        // 进度不动就停：卡住的来源（读不出的文件、反复失败的目录）不该让
        // 这条链空转，等下一轮常规刷新再试。
        guard catchUpProgress[providerID] != catchUp.progress else {
            pendingCatchUp.remove(providerID)
            return
        }
        catchUpProgress[providerID] = catchUp.progress
        pendingCatchUp.insert(providerID)
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

        guard pendingCatchUp.remove(providerID) != nil,
              refreshLoop != nil,
              let provider = providers.first(where: { $0.providerID == providerID })
        else { return }

        // 页面还开着才继续。`stop()` 清掉 refreshLoop 并取消在途任务，
        // 这条链随之断开，空闲态不留下任何常驻物。
        scheduleRefresh(for: provider)
    }

    func setHistoryRange(_ range: UsageHistoryRange) {
        guard range != historyRange else { return }
        historyRange = range
        recomputeDashboard()
    }

    /// 把同一批 provider 返回触发的重算合并成一次。
    ///
    /// 聚合本身很便宜——本机 6 个账号、289 条日活动实测 0.45 ms/次，所以这里
    /// 省的不是 CPU，是 `@Published` 连着变六次带来的六轮 SwiftUI 重绘。
    /// 首帧和用户切换统计周期仍然同步重算，不能让它们等下一个 tick。
    private func scheduleDashboardRecompute() {
        guard !dashboardRecomputeScheduled else { return }
        dashboardRecomputeScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.dashboardRecomputeScheduled = false
            self.recomputeDashboard()
        }
    }

    private func recomputeDashboard() {
        dashboard = UsageDashboardSnapshot(
            accounts: accounts,
            range: historyRange
        )
    }
}
