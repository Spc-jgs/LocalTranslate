import Foundation

// 仪表盘聚合是一次多趟遍历（日粒度、Provider、模型、成本）。它按
// `accounts + range` 计算一次并被持有，绝不放在 SwiftUI 的 body 求值路径上。

nonisolated enum UsageHistoryRange: Int, CaseIterable, Identifiable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sevenDays:
            return "7 天"
        case .thirtyDays:
            return "30 天"
        case .ninetyDays:
            return "90 天"
        }
    }
}

nonisolated enum UsageBreakdownMode: String, CaseIterable, Identifiable {
    case model
    case day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .model:
            return "模型"
        case .day:
            return "日期"
        }
    }
}

nonisolated struct UsageDashboardSnapshot {
    let range: UsageHistoryRange
    let totalTokens: Int64
    let totalTurns: Int
    let dailyTotals: [DailyActivity]
    let providerRows: [ProviderUsageRow]
    let todayModels: [ModelUsageRow]
    let models: [ModelUsageRow]
    let todayTokenBreakdown: TokenBreakdown
    let modelTokenBreakdown: TokenBreakdown
    let todayCostUSD: Double?
    let todayCostLabel: String
    let historyCostUSD: Double?
    let historyCostIncludesEstimate: Bool
    let historyCostCoverageComplete: Bool
    let includesEstimatedActivity: Bool

    init(accounts: [AccountSnapshot], range: UsageHistoryRange) {
        self.range = range

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(
            byAdding: .day,
            value: -(range.rawValue - 1),
            to: today
        ) ?? today

        var dailyMap: [Date: DailyActivity] = [:]
        var providerMap: [ProviderKind: (tokens: Int64, turns: Int, estimated: Bool)] = [:]

        for offset in 0..<range.rawValue {
            if let date = calendar.date(byAdding: .day, value: offset, to: start) {
                let day = calendar.startOfDay(for: date)
                dailyMap[day] = DailyActivity(date: day, tokens: 0, turns: 0)
            }
        }

        for account in accounts {
            for activity in account.dailyActivity {
                let day = calendar.startOfDay(for: activity.date)
                guard day >= start && day <= today else { continue }

                let current = dailyMap[day] ?? DailyActivity(date: day, tokens: 0, turns: 0)
                dailyMap[day] = DailyActivity(
                    date: day,
                    tokens: current.tokens + activity.tokens,
                    turns: current.turns + activity.turns
                )

                var provider = providerMap[account.provider]
                    ?? (tokens: 0, turns: 0, estimated: false)
                provider.tokens += activity.tokens
                provider.turns += activity.turns
                provider.estimated = provider.estimated || account.confidence == .low
                providerMap[account.provider] = provider
            }
        }

        let points = dailyMap.values.sorted { $0.date < $1.date }
        dailyTotals = points
        let total = points.reduce(Int64(0)) { $0 + $1.tokens }
        totalTokens = total
        totalTurns = points.reduce(0) { $0 + $1.turns }

        let rows = providerMap.map { provider, values in
            ProviderUsageRow(
                provider: provider,
                tokens: values.tokens,
                turns: values.turns,
                share: total > 0
                    ? Double(values.tokens) / Double(total)
                    : 0,
                isEstimated: values.estimated
            )
        }
        .sorted { $0.tokens > $1.tokens }
        providerRows = rows

        todayModels = Self.makeModelRows(accounts: accounts, period: .today)
        models = Self.makeModelRows(accounts: accounts, period: .thirtyDays)

        var todayBreakdown = TokenBreakdown()
        for row in todayModels {
            todayBreakdown.add(row.usage)
        }
        todayTokenBreakdown = todayBreakdown

        var breakdown = TokenBreakdown()
        for row in models {
            breakdown.add(row.usage)
        }
        modelTokenBreakdown = breakdown

        let todayCosts = todayModels.compactMap(\.costUSD)
        todayCostUSD = todayCosts.isEmpty ? nil : todayCosts.reduce(0, +)
        let todayCostComplete = !todayModels.isEmpty
            && todayCosts.count == todayModels.count
        let todayCostEstimated = todayModels.contains {
            $0.costKind == .estimated
        }

        if todayCostUSD == nil {
            todayCostLabel = "参考费用"
        } else if !todayCostComplete {
            todayCostLabel = "参考费用 · 部分"
        } else if todayCostEstimated {
            todayCostLabel = "参考费用 · 估算"
        } else {
            todayCostLabel = "日志费用"
        }

        let historyCosts = models.compactMap(\.costUSD)
        historyCostUSD = historyCosts.isEmpty
            ? nil
            : historyCosts.reduce(0, +)
        historyCostIncludesEstimate = models.contains {
            $0.costKind == .estimated
        }
        historyCostCoverageComplete = !models.isEmpty
            && historyCosts.count == models.count
        includesEstimatedActivity = rows.contains { $0.isEstimated && $0.tokens > 0 }
    }

    private static func makeModelRows(
        accounts: [AccountSnapshot],
        period: ActivityPeriod
    ) -> [ModelUsageRow] {
        struct MutableModel {
            let provider: ProviderKind
            let modelID: String
            let displayName: String
            var usage = TokenBreakdown()
            var turns = 0
            var costUSD: Double = 0
            var costComplete = true
            var costKind: UsageCostKind?
        }

        var modelMap: [String: MutableModel] = [:]

        for account in accounts {
            for model in account.modelActivity where model.period == period {
                let key = "\(account.provider.rawValue)::\(model.modelID)"
                var current = modelMap[key] ?? MutableModel(
                    provider: account.provider,
                    modelID: model.modelID,
                    displayName: model.displayName
                )

                current.usage.add(model.usage)
                current.turns += model.turns

                if let cost = model.costUSD {
                    current.costUSD += cost
                } else {
                    current.costComplete = false
                }

                if model.costKind == .estimated {
                    current.costKind = .estimated
                } else if current.costKind == nil {
                    current.costKind = model.costKind
                }

                modelMap[key] = current
            }
        }

        return modelMap.map { key, value in
            ModelUsageRow(
                id: key,
                provider: value.provider,
                modelID: value.modelID,
                displayName: value.displayName,
                usage: value.usage,
                turns: value.turns,
                costUSD: value.costComplete ? value.costUSD : nil,
                costKind: value.costComplete ? value.costKind : nil
            )
        }
        .sorted { $0.usage.totalTokens > $1.usage.totalTokens }
    }
}

nonisolated struct ProviderUsageRow: Identifiable {
    let provider: ProviderKind
    let tokens: Int64
    let turns: Int
    let share: Double
    let isEstimated: Bool

    var id: String { provider.rawValue }
}

nonisolated struct ModelUsageRow: Identifiable {
    let id: String
    let provider: ProviderKind
    let modelID: String
    let displayName: String
    var usage: TokenBreakdown
    var turns: Int
    var costUSD: Double?
    var costKind: UsageCostKind?
}
