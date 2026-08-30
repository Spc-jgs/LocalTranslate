import SwiftUI
import Charts

struct AIUsageView: View {
    @ObservedObject var store: UsageStore

    @State
    private var historyRange: UsageHistoryRange = .thirtyDays

    @State
    private var breakdownMode: UsageBreakdownMode = .model

    private var dashboard: UsageDashboardSnapshot {
        UsageDashboardSnapshot(
            accounts: store.accounts,
            range: historyRange
        )
    }

    private var quotaAccounts: [AccountSnapshot] {
        store.accounts.filter { account in
            account.quotaWindows.contains { window in
                window.usedPercent != nil || window.resetsAt != nil
            }
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                toolbar

                if !store.errors.isEmpty {
                    errorPanel
                }

                if store.accounts.isEmpty && store.isRefreshing {
                    loadingState
                } else if store.accounts.isEmpty {
                    emptyState
                } else {
                    todaySection
                    quotaSection
                    overviewSection
                    breakdownSection
                    sourcesSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            store.start()
        }
        .onDisappear {
            store.stop()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("今日用量")
                    .font(.system(size: 13, weight: .semibold))

                if store.isRefreshing {
                    Text("正在分别更新 \(store.refreshingProviderIDs.count) 个账号 · 完成后立即显示")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if let lastRefresh = store.lastRefresh {
                    Text("更新于 \(lastRefresh.formatted(date: .omitted, time: .shortened)) · 超过 30 分钟自动刷新")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("本机缓存与 Provider 实时额度")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            Text("正在分别读取各账号的额度与本机 AI 活动…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("任一账号完成后都会立即显示，不等待其他来源。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有用量数据", systemImage: "chart.bar.xaxis")
        } description: {
            Text("刷新后会读取已登录的 Codex、AGY 与 Grok 数据；单个来源失败不会影响其他来源。")
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var errorPanel: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.errors.keys.sorted(), id: \.self) { key in
                    if let message = store.errors[key] {
                        Text("\(key)：\(message)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("部分来源读取失败，已保留其余数据", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
        }
        .padding(14)
        .dashboardCard()
    }

    @ViewBuilder
    private var quotaSection: some View {
        if !quotaAccounts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(
                    title: "订阅额度",
                    subtitle: "每个账号的限额窗口、剩余额度与重置时间"
                )

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 300, maximum: 440), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    ForEach(quotaAccounts) { account in
                        QuotaAccountCard(
                            account: account,
                            isRefreshing: store.isRefreshing(providerID: account.id),
                            onRefresh: {
                                Task {
                                    await store.refresh(providerID: account.id)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                sectionHeading(
                    title: "历史趋势",
                    subtitle: "\(historyRange.title)本机活动；订阅额度与 API 等价费用不是同一口径"
                )

                Spacer()

                Picker("统计周期", selection: $historyRange) {
                    ForEach(UsageHistoryRange.allCases) { range in
                        Text(range.title)
                            .tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    UsageHeadlineCard(dashboard: dashboard)
                        .frame(width: 230)

                    UsageTrendCard(dashboard: dashboard)
                }

                VStack(spacing: 12) {
                    UsageHeadlineCard(dashboard: dashboard)
                    UsageTrendCard(dashboard: dashboard)
                }
            }
        }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(
                title: "今日模型使用",
                subtitle: "按本机时区自然日汇总模型、Token、活动次数与参考费用"
            )

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 10),
                    count: 4
                ),
                spacing: 10
            ) {
                SummaryMetric(
                    label: "今日 Token",
                    value: TokenFormatter.compact(dashboard.todayTokenBreakdown.totalTokens),
                    systemImage: "sum"
                )

                SummaryMetric(
                    label: "输入",
                    value: TokenFormatter.compact(dashboard.todayTokenBreakdown.inputTokens),
                    systemImage: "text.append"
                )

                SummaryMetric(
                    label: "输出",
                    value: TokenFormatter.compact(dashboard.todayTokenBreakdown.outputTokens),
                    systemImage: "arrow.up.right"
                )

                SummaryMetric(
                    label: dashboard.todayCostLabel,
                    value: dashboard.todayCostUSD.map {
                        CurrencyFormatter.usd($0)
                    } ?? "—",
                    systemImage: "dollarsign.circle"
                )
            }

            ModelBreakdownTable(
                rows: dashboard.todayModels,
                emptyMessage: "今天还没有可验证的模型级使用记录"
            )
            .dashboardCard()

            Text("Codex 费用按 OpenAI 官方 API 单价估算，不代表 Plus 实际扣款，且不含工具调用费；Grok 优先采用本地日志费用。AGY 暂无模型级明细，不计入本区。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                sectionHeading(
                    title: "历史明细",
                    subtitle: breakdownMode == .model
                        ? "模型明细采用各来源可验证的近 30 天数据"
                        : "按日期汇总当前所选周期"
                )

                Spacer()

                Picker("明细方式", selection: $breakdownMode) {
                    ForEach(UsageBreakdownMode.allCases) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            Group {
                switch breakdownMode {
                case .model:
                    ModelBreakdownTable(
                        rows: dashboard.models,
                        emptyMessage: "近 30 天没有可验证的模型级使用记录"
                    )
                case .day:
                    DailyBreakdownTable(points: dashboard.dailyTotals)
                }
            }
            .dashboardCard()
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(
                title: "来源与账号",
                subtitle: "查看统计来源、可信度和单账号周期汇总"
            )

            VStack(spacing: 8) {
                ForEach(store.accounts) { account in
                    AccountSourceDisclosure(
                        account: account,
                        isRefreshing: store.isRefreshing(providerID: account.id),
                        onRefresh: {
                            Task {
                                await store.refresh(providerID: account.id)
                            }
                        }
                    )
                }
            }
        }
    }

    private func sectionHeading(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private enum UsageHistoryRange: Int, CaseIterable, Identifiable {
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

private enum UsageBreakdownMode: String, CaseIterable, Identifiable {
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

private struct UsageDashboardSnapshot {
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

private struct ProviderUsageRow: Identifiable {
    let provider: ProviderKind
    let tokens: Int64
    let turns: Int
    let share: Double
    let isEstimated: Bool

    var id: String { provider.rawValue }
}

private struct ModelUsageRow: Identifiable {
    let id: String
    let provider: ProviderKind
    let modelID: String
    let displayName: String
    var usage: TokenBreakdown
    var turns: Int
    var costUSD: Double?
    var costKind: UsageCostKind?
}

private struct UsageHeadlineCard: View {
    let dashboard: UsageDashboardSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(TokenFormatter.compact(dashboard.totalTokens))
                    .font(.system(size: 31, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text(
                    dashboard.includesEstimatedActivity
                        ? "活动 Token · \(dashboard.range.title) · 含估算"
                        : "处理 Token · \(dashboard.range.title)"
                )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(dashboard.providerRows) { row in
                    VStack(spacing: 5) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(row.provider.tint)
                                .frame(width: 7, height: 7)

                            Text(row.provider.rawValue)
                                .font(.system(size: 11, weight: .medium))

                            if row.isEstimated {
                                Text("估算")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }

                            Spacer()

                            Text(TokenFormatter.compact(row.tokens))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.055))

                                Capsule()
                                    .fill(row.provider.tint)
                                    .frame(width: proxy.size.width * max(0, min(1, row.share)))
                            }
                        }
                        .frame(height: 4)

                        HStack {
                            Text(PercentageFormatter.format(row.share))
                            Spacer()
                            if row.turns > 0 {
                                Text("\(row.turns) 次活动")
                            }
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            if let cost = dashboard.historyCostUSD {
                Divider()
                    .opacity(0.3)

                HStack {
                    Text(
                        dashboard.historyCostCoverageComplete
                            ? (
                                dashboard.historyCostIncludesEstimate
                                    ? "API 等价费用 · 含估算"
                                    : "日志费用"
                            )
                            : "参考费用 · 部分"
                    )
                    Spacer()
                    Text(CurrencyFormatter.usd(cost))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("Codex 为 API 等价估算，Grok 优先采用日志费用；都不代表订阅账单。")
            }
        }
        .padding(16)
        .dashboardCard()
    }
}

private struct UsageTrendCard: View {
    let dashboard: UsageDashboardSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每日趋势")
                        .font(.system(size: 12, weight: .semibold))

                    Text("按自然日汇总本机活动")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                let activeDays = dashboard.dailyTotals.filter { $0.tokens > 0 }.count
                Text("\(activeDays) 个活跃日")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Chart(dashboard.dailyTotals) { point in
                LineMark(
                    x: .value("日期", point.date),
                    y: .value("Token", point.tokens)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                        .foregroundStyle(.separator.opacity(0.25))

                    AxisValueLabel {
                        if let value = value.as(Int64.self) {
                            Text(TokenFormatter.compact(value))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: dashboard.range == .sevenDays ? 7 : 6)) {
                    AxisGridLine()
                        .foregroundStyle(.separator.opacity(0.12))
                    AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
                        .font(.system(size: 9))
                }
            }
            .frame(minHeight: 200)
        }
        .padding(16)
        .dashboardCard()
    }
}

private struct SummaryMetric: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .dashboardCard()
    }
}

private struct QuotaAccountCard: View {
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    let account: AccountSnapshot
    let isRefreshing: Bool
    let onRefresh: () -> Void

    private var windows: [QuotaWindow] {
        account.quotaWindows.filter {
            $0.usedPercent != nil || $0.resetsAt != nil
        }
        .sorted {
            ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: account.provider.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(account.provider.tint)
                    .frame(width: 30, height: 30)
                    .background(account.provider.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    Text([account.email, account.plan].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if !isRefreshing {
                    Text(account.updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                Button(action: onRefresh) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .frame(width: 26, height: 26)
                .disabled(isRefreshing)
                .help(isRefreshing ? "正在更新这个账号" : "只刷新这个账号")
            }

            VStack(spacing: 0) {
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    if index > 0 {
                        Divider()
                            .opacity(0.28)
                            .padding(.vertical, 12)
                    }

                    QuotaWindowRow(
                        provider: account.provider,
                        window: window
                    )
                }
            }
        }
        .padding(15)
        .dashboardCard()
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: isRefreshing
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.displayName)订阅额度")
    }
}

private struct QuotaWindowRow: View {
    let provider: ProviderKind
    let window: QuotaWindow

    private var remaining: Double? {
        window.remainingPercent
    }

    private var tint: Color {
        guard let remaining else { return provider.tint }
        if remaining <= 15 { return .red }
        if remaining <= 35 { return .orange }
        return provider.tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.title)
                    .font(.system(size: 11, weight: .medium))

                Spacer()

                Text(remaining.map { "\(Int($0.rounded(.down)))%" } ?? "—")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remaining == nil ? Color.secondary : tint)
                    .contentTransition(.numericText())
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))

                    if let remaining {
                        Capsule()
                            .fill(tint)
                            .frame(width: proxy.size.width * max(0, min(1, remaining / 100)))
                    }
                }
            }
            .frame(height: 5)

            HStack {
                Text("剩余额度")
                Spacer()
                if let reset = window.resetsAt {
                    Text("\(reset, style: .relative)重置")
                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("重置时间未知")
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.title)额度")
        .accessibilityValue(remaining.map { "剩余\(Int($0))%" } ?? "剩余未知")
    }
}

private struct ModelBreakdownTable: View {
    let rows: [ModelUsageRow]
    let emptyMessage: String

    var body: some View {
        VStack(spacing: 0) {
            tableHeader

            Divider()
                .opacity(0.35)

            if rows.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: row.provider.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(row.provider.tint)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.displayName)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Text("\(row.provider.rawValue) · \(row.turns) 次")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(TokenFormatter.compact(row.usage.inputTokens))
                            .frame(width: 62, alignment: .trailing)

                        Text(TokenFormatter.compact(row.usage.cachedReadTokens))
                            .frame(width: 62, alignment: .trailing)

                        Text(TokenFormatter.compact(row.usage.outputTokens))
                            .frame(width: 62, alignment: .trailing)

                        Text(TokenFormatter.compact(row.usage.totalTokens))
                            .fontWeight(.semibold)
                            .frame(width: 68, alignment: .trailing)

                        VStack(alignment: .trailing, spacing: 1) {
                            Text(row.costUSD.map {
                                CurrencyFormatter.usd($0)
                            } ?? "—")

                            if let kind = row.costKind {
                                Text(kind == .estimated ? "估算" : "日志")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 72, alignment: .trailing)
                    }
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)

                    if index < rows.count - 1 {
                        Divider()
                            .opacity(0.22)
                            .padding(.leading, 40)
                    }
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("模型")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("输入")
                .frame(width: 62, alignment: .trailing)
            Text("缓存")
                .frame(width: 62, alignment: .trailing)
            Text("输出")
                .frame(width: 62, alignment: .trailing)
            Text("Token")
                .frame(width: 68, alignment: .trailing)
            Text("参考费用")
                .frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct DailyBreakdownTable: View {
    let points: [DailyActivity]

    private var visiblePoints: [DailyActivity] {
        Array(points.reversed().prefix(30))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("日期")
                Spacer()
                Text("活动")
                    .frame(width: 90, alignment: .trailing)
                Text("Token")
                    .frame(width: 110, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()
                .opacity(0.35)

            ForEach(Array(visiblePoints.enumerated()), id: \.element.id) { index, point in
                HStack {
                    Text(point.date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                    Spacer()
                    Text(point.turns > 0 ? "\(point.turns) 次" : "—")
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Text(TokenFormatter.compact(point.tokens))
                        .fontWeight(.semibold)
                        .frame(width: 110, alignment: .trailing)
                }
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                if index < visiblePoints.count - 1 {
                    Divider()
                        .opacity(0.22)
                        .padding(.leading, 14)
                }
            }
        }
    }
}

private struct AccountSourceDisclosure: View {
    let account: AccountSnapshot
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(account.activity) { activity in
                    HStack {
                        Text(periodTitle(activity.period))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if activity.turns > 0 {
                            Text("\(activity.turns) 次")
                                .foregroundStyle(.tertiary)
                        }
                        Text(TokenFormatter.compact(activity.tokens))
                            .fontWeight(.semibold)
                            .frame(width: 90, alignment: .trailing)
                    }
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                }

                Divider()
                    .opacity(0.25)

                HStack {
                    Text(account.sourceLabel)
                    Spacer()
                    Text("可信度 \(account.confidence.localizedTitle)")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

                HStack {
                    Text("更新于 \(account.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Button(action: onRefresh) {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("刷新此账号", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRefreshing)
                    .help(isRefreshing ? "正在更新这个账号" : "只刷新这个账号")
                }

                if let message = account.statusMessage {
                    Text(message)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: account.provider.systemImage)
                    .foregroundStyle(account.provider.tint)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayName)
                        .font(.system(size: 11, weight: .semibold))

                    Text([account.email, account.plan].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

            }
        }
        .padding(13)
        .dashboardCard()
    }

    private func periodTitle(_ period: ActivityPeriod) -> String {
        switch period {
        case .today:
            return "今天"
        case .sevenDays:
            return "最近 7 天"
        case .thirtyDays:
            return "最近 30 天"
        case .lifetime:
            return "全部历史"
        }
    }
}

private struct DashboardCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.032))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 1)
            }
    }
}

private extension View {
    func dashboardCard() -> some View {
        modifier(DashboardCardModifier())
    }
}

private extension ProviderKind {
    var tint: Color {
        switch self {
        case .openAI:
            return Color(red: 0.18, green: 0.67, blue: 0.48)
        case .google:
            return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .xAI:
            return Color(red: 0.63, green: 0.38, blue: 0.92)
        }
    }

    var systemImage: String {
        switch self {
        case .openAI:
            return "sparkles"
        case .google:
            return "diamond.fill"
        case .xAI:
            return "xmark"
        }
    }
}

private extension DataConfidence {
    var localizedTitle: String {
        switch self {
        case .high:
            return "高"
        case .medium:
            return "中"
        case .low:
            return "低"
        }
    }
}

private enum PercentageFormatter {
    static func format(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

private enum CurrencyFormatter {
    static func usd(_ value: Double) -> String {
        value < 0.01
            ? String(format: "$%.4f", value)
            : String(format: "$%.2f", value)
    }
}

enum TokenFormatter {
    static func compact(_ value: Int64) -> String {
        let number = Double(value)
        let absolute = abs(number)

        if absolute >= 1_000_000_000 {
            return String(format: "%.2fB", number / 1_000_000_000)
        }
        if absolute >= 1_000_000 {
            return String(format: "%.2fM", number / 1_000_000)
        }
        if absolute >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return "\(value)"
    }

    static func formattedNumber(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
