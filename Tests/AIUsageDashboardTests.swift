import Foundation

@main
struct AIUsageDashboardTests {
    static func main() {
        selectedHistoryRangeControlsModelTotals()
        print("AIUsageDashboardTests: 3 passed")
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
            activityAvailable: true
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
}
