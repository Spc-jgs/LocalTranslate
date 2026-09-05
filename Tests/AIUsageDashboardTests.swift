import Foundation

@main
struct AIUsageDashboardTests {
    static func main() {
        selectedHistoryRangeControlsModelTotals()
        sameModelIsNormalizedAcrossSources()
        estimatedBadgeUsesActivityLaneOnly()
        catchUpStatusSaysTheNumbersAreIncomplete()
        print("AIUsageDashboardTests: 10 passed")
    }

    private static func estimatedBadgeUsesActivityLaneOnly() {
        let observed = account(
            id: "observed",
            provider: .openAI,
            modelID: "gpt-observed",
            tokens: 10,
            confidence: .low,
            activityQuality: .observed
        )
        let observedDashboard = UsageDashboardSnapshot(
            accounts: [observed],
            range: .sevenDays
        )
        expect(
            observedDashboard.providerRows.allSatisfy { !$0.isEstimated },
            "额度或账号降级把本机事实误标成估算"
        )

        let estimated = account(
            id: "estimated",
            provider: .google,
            modelID: "agy-activity-estimate",
            tokens: 10,
            activityQuality: .estimated
        )
        let estimatedDashboard = UsageDashboardSnapshot(
            accounts: [estimated],
            range: .sevenDays
        )
        expect(
            estimatedDashboard.providerRows.allSatisfy(\.isEstimated),
            "活动估算没有进入 Provider 标记"
        )
    }

    private static func sameModelIsNormalizedAcrossSources() {
        let openAI = account(
            id: "codex",
            provider: .openAI,
            modelID: "gpt-5.6-sol",
            tokens: 30
        )
        let agy = account(
            id: "agy",
            provider: .google,
            modelID: "GPT-5.6-SOL",
            tokens: 12
        )
        let rows = UsageDashboardSnapshot(
            accounts: [openAI, agy],
            range: .sevenDays
        ).models

        expect(rows.count == 1, "同一 modelID 被来源拆成了多行")
        expect(rows[0].usage.totalTokens == 42, "跨来源模型 Token 没有相加")
        expect(rows[0].provider == .openAI, "模型厂商沿用了 AGY 的账号来源")
    }

    private static func account(
        id: String,
        provider: ProviderKind,
        modelID: String,
        tokens: Int64,
        confidence: DataConfidence = .high,
        activityQuality: UsageDataQuality = .observed
    ) -> AccountSnapshot {
        AccountSnapshot(
            id: id,
            sortOrder: 0,
            provider: provider,
            billingKind: .local,
            displayName: id,
            email: nil,
            plan: nil,
            quotaWindows: [],
            activity: [],
            dailyActivity: [
                DailyActivity(date: Date(), tokens: tokens, turns: 1)
            ],
            modelActivity: [
                ModelActivity(
                    modelID: modelID,
                    displayName: modelID,
                    period: .sevenDays,
                    usage: TokenBreakdown(inputTokens: tokens),
                    turns: 1,
                    costUSD: nil,
                    costKind: nil
                )
            ],
            updatedAt: Date(),
            sourceLabel: "fixture",
            confidence: confidence,
            statusMessage: nil,
            schemaVersion: AccountSnapshot.currentSchemaVersion,
            quotaAvailable: false,
            activityAvailable: true,
            catchUp: nil,
            quotaStatus: nil,
            activityStatus: UsageDataStatus(
                quality: activityQuality,
                updatedAt: Date()
            )
        )
    }

    private static func selectedHistoryRangeControlsModelTotals() {
        let account = AccountSnapshot(
            id: "codex-fixture",
            sortOrder: 0,
            provider: .openAI,
            billingKind: .subscription,
            displayName: "Codex",
            email: nil,
            plan: "Plus",
            quotaWindows: [],
            activity: [],
            dailyActivity: [],
            modelActivity: [
                modelActivity(period: .today, total: 10),
                modelActivity(period: .sevenDays, total: 70),
                modelActivity(period: .thirtyDays, total: 300),
                modelActivity(period: .ninetyDays, total: 900)
            ],
            updatedAt: Date(),
            sourceLabel: "fixture",
            confidence: .high,
            statusMessage: "",
            schemaVersion: AccountSnapshot.currentSchemaVersion,
            quotaAvailable: true,
            activityAvailable: true,
            catchUp: nil,
            quotaStatus: nil,
            activityStatus: nil
        )

        expect(modelTotal(account, range: .sevenDays) == 70, "7-day model total used another range")
        expect(modelTotal(account, range: .thirtyDays) == 300, "30-day model total used another range")
        expect(modelTotal(account, range: .ninetyDays) == 900, "90-day model total used another range")
    }

    private static func modelActivity(period: ActivityPeriod, total: Int64) -> ModelActivity {
        ModelActivity(
            modelID: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            period: period,
            usage: TokenBreakdown(inputTokens: total, outputTokens: 0),
            turns: 1,
            costUSD: nil,
            costKind: nil
        )
    }

    private static func modelTotal(
        _ account: AccountSnapshot,
        range: UsageHistoryRange
    ) -> Int64 {
        UsageDashboardSnapshot(accounts: [account], range: range)
            .models
            .first?
            .usage
            .totalTokens ?? -1
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }

    /// 补齐要跑一两分钟，中途的读数看上去和最终值没有区别——实测差过好几倍。
    /// 所以 pending 期间必须说清数字不完整，并给出分母。
    private static func catchUpStatusSaysTheNumbersAreIncomplete() {
        let running = UsageCatchUpProgress(
            pending: true,
            progress: 1_024,
            indexedFiles: 37,
            candidateFiles: 248
        )
        guard let text = running.statusText else {
            fatalError("补齐进行中却没有任何提示")
        }
        expect(text.contains("37/248"), "补齐提示没有给出进度分母")
        expect(text.contains("不完整"), "补齐提示没有说明数字还不完整")

        let done = UsageCatchUpProgress(
            pending: false,
            progress: 4_096,
            indexedFiles: 248,
            candidateFiles: 248
        )
        expect(done.statusText == nil, "补齐结束后仍在提示数字不完整")

        // 旧缓存里没有文件数；没有分母也得说清数字不完整。
        let legacy = UsageCatchUpProgress(
            pending: true,
            progress: 512,
            indexedFiles: nil,
            candidateFiles: nil
        )
        expect(
            legacy.statusText?.contains("不完整") == true,
            "缺少文件数时补齐提示消失了"
        )
    }
}
