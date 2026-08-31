import SwiftUI
import Charts

struct AIUsageView: View {
    @ObservedObject var store: UsageStore

    @State
    private var breakdownMode: UsageBreakdownMode = .model

    @State
    private var isEditingProviders = false

    // 聚合由 store 持有：写成计算属性会让这段多趟遍历跟着每一次
    // body 求值重跑（hover、刷新标记、错误变化都会触发）。
    private var dashboard: UsageDashboardSnapshot {
        store.dashboard
    }

    private var historyRange: UsageHistoryRange {
        store.historyRange
    }

    private var subscriptionAccounts: [AccountSnapshot] {
        store.accounts.filter { account in
            account.billingKind == .subscription
                || (account.billingKind == nil && account.quotaWindows.contains { window in
                    window.usedPercent != nil || window.resetsAt != nil
                })
                || (account.billingKind == nil && account.provider == .anthropic)
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
        .sheet(isPresented: $isEditingProviders) {
            UsageProviderSettingsView()
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

            Button {
                isEditingProviders = true
            } label: {
                Label("账号来源", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("增删 Codex 账号目录、启停其他来源")
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
            Text("刷新后会读取「账号来源」中已启用的来源；单个来源失败不会影响其他来源。")
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
        if !subscriptionAccounts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(
                    title: "订阅额度",
                    subtitle: "每个账号的限额窗口、剩余额度与重置时间"
                )

                // LazyVGrid 会把同一行的卡片拉到最高那张的高度：AGY 有 4 个额度
                // 窗口、Claude 可能一个都没有，同行时矮的那张下方就是一大片空白。
                // 两列各自独立堆叠即可，卡片保持自身高度。
                HStack(alignment: .top, spacing: 12) {
                    ForEach(
                        Array(quotaColumns.enumerated()),
                        id: \.offset
                    ) { _, column in
                        VStack(spacing: 12) {
                            ForEach(column) { account in
                                QuotaAccountCard(
                                    account: account,
                                    isRefreshing: store.isRefreshing(
                                        providerID: account.id
                                    ),
                                    onRefresh: {
                                        Task {
                                            await store.refresh(
                                                providerID: account.id
                                            )
                                        }
                                    }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
        }
    }

    /// 把订阅卡片分到两列，尽量让两列高度接近。
    ///
    /// 高度用「额度窗口数」估算：卡片主体就是窗口列表，没有窗口时是一行提示。
    private var quotaColumns: [[AccountSnapshot]] {
        var columns: [[AccountSnapshot]] = [[], []]
        var estimatedHeights = [0, 0]

        for account in subscriptionAccounts {
            let target = estimatedHeights[0] <= estimatedHeights[1] ? 0 : 1
            columns[target].append(account)
            // 每个窗口约占一格，无窗口的提示卡按半格计。
            estimatedHeights[target] += max(account.quotaWindows.count * 2, 1)
        }

        return columns.filter { !$0.isEmpty }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                sectionHeading(
                    title: "历史趋势",
                    subtitle: "\(historyRange.title)本机活动；订阅额度与 API 等价费用不是同一口径"
                )

                Spacer()

                Picker(
                    "统计周期",
                    selection: Binding(
                        get: { store.historyRange },
                        set: { store.setHistoryRange($0) }
                    )
                ) {
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

            // 四个等权指标卡扫视时没有落点。今日 Token 升为主视觉，
            // 输入/输出降为卫星并各自标出占比，费用单独一格。
            HStack(alignment: .top, spacing: 10) {
                TodayHeadlineMetric(
                    total: dashboard.todayTokenBreakdown.totalTokens,
                    turns: dashboard.todayTurns,
                    modelCount: dashboard.todayModels.count
                )
                .frame(maxWidth: .infinity)

                VStack(spacing: 10) {
                    TodaySatelliteMetric(
                        label: "输入",
                        value: dashboard.todayTokenBreakdown.inputTokens,
                        total: dashboard.todayTokenBreakdown.totalTokens,
                        systemImage: "arrow.down.left"
                    )

                    TodaySatelliteMetric(
                        label: "输出",
                        value: dashboard.todayTokenBreakdown.outputTokens,
                        total: dashboard.todayTokenBreakdown.totalTokens,
                        systemImage: "arrow.up.right"
                    )
                }
                .frame(maxWidth: .infinity)

                TodayCostMetric(
                    label: dashboard.todayCostLabel,
                    amount: dashboard.todayCostUSD
                )
                .frame(maxWidth: .infinity)
            }

            ModelBreakdownTable(
                rows: dashboard.todayModels,
                emptyMessage: "今天还没有可验证的模型级使用记录"
            )
            .dashboardCard()

            Text("Codex、Claude 与 Grok 按官方标准 API 单价提供等价费用，Grok 有日志费用时优先采用日志值；这些都不代表订阅实际扣款，且不含工具调用费。百炼 Credits 不从 Token 反推；AGY 从本机会话库读取模型与 Token，暂不提供费用。")
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
                        ? "模型明细采用各来源可验证的 \(historyRange.title)数据"
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
                        emptyMessage: "\(historyRange.title)内没有可验证的模型级使用记录"
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
                .help("Codex、Claude 与 Grok 为标准 API 等价参考，Grok 日志费用优先；都不代表订阅账单。百炼不估算 Credits。")
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

/// 今日 Token：整页的主视觉锚点。
private struct TodayHeadlineMetric: View {
    let total: Int64
    let turns: Int
    let modelCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sum")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text("今日 Token")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text(TokenFormatter.compact(total))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 5)

            HStack(spacing: 6) {
                Text("\(turns) 次调用")
                    .monospacedDigit()

                Text("·")
                    .foregroundStyle(.quaternary)

                Text("\(modelCount) 个模型")
                    .monospacedDigit()
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color.accentColor.opacity(0.10),
                            Color.clear
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 220
                    )
                )
        }
        .dashboardCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("今日 Token \(TokenFormatter.compact(total))")
    }
}

/// 输入 / 输出：附带占比，说明这两个量本身就不对等。
private struct TodaySatelliteMetric: View {
    let label: String
    let value: Int64
    let total: Int64
    let systemImage: String

    private var share: Double? {
        guard total > 0 else { return nil }
        return Double(value) / Double(total) * 100
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(
                    Color.accentColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                Text(TokenFormatter.compact(value))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            if let share {
                Text("\(share, specifier: "%.1f")%")
                    .font(.system(size: 9.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .dashboardCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(TokenFormatter.compact(value))")
    }
}

/// 参考费用：口径标注跟着标题走，避免被误读成实际扣款。
private struct TodayCostMetric: View {
    let label: String
    let amount: Double?

    private var qualifier: String? {
        guard let separator = label.range(of: " · ") else { return nil }
        return String(label[separator.upperBound...])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text("参考费用")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                if let qualifier {
                    Text(qualifier)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }
            }

            Text(amount.map { CurrencyFormatter.usd($0) } ?? "—")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text("非订阅实际扣款")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .dashboardCard()
        .accessibilityElement(children: .combine)
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: account.provider.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(account.provider.tint)
                    .frame(width: 34, height: 34)
                    .background(
                        account.provider.tint.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)

                    Text(
                        [account.email, account.plan]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                    )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Group {
                    if isRefreshing {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("更新中")
                        }
                    } else {
                        Text(account.updatedAt.formatted(date: .omitted, time: .shortened))
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.045), in: Capsule())

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(isRefreshing && !reduceMotion ? .degrees(180) : .zero)
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.045), in: Circle())
                .disabled(isRefreshing)
                .help(isRefreshing ? "正在更新这个账号" : "只刷新这个账号")
                .accessibilityLabel(isRefreshing ? "正在刷新" : "刷新\(account.displayName)")
            }

            if windows.isEmpty {
                UnavailableQuotaRow(
                    provider: account.provider,
                    hint: account.statusMessage
                )
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(windows) { window in
                        QuotaWindowTile(
                            provider: account.provider,
                            window: window
                        )
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .top)
        .dashboardCard()
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: isRefreshing
        )
        .accessibilityElement(children: .contain)
    }
}

private struct UnavailableQuotaRow: View {
    let provider: ProviderKind
    /// Provider 生成的可操作说明（例如提示去哪里刷新额度缓存）。
    /// 此前它只存在于快照里，界面上从不展示，用户只看得到「暂无」。
    var hint: String?

    private var trimmedHint: String? {
        guard let hint else { return nil }
        let value = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(provider.tint)
                .frame(width: 22, height: 22)
                .background(provider.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text("暂无可验证的额度窗口")
                    .font(.system(size: 10, weight: .medium))

                Text("未提供 5 小时窗口时仍保留订阅卡片；本机 Token 与参考费用继续统计。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let trimmedHint {
                    Text(trimmedHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(11)
        .dashboardCard(.inset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("暂无可验证的订阅额度窗口")
    }
}

private struct QuotaWindowTile: View {
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

    /// 余量见底时整块瓦片转色，不必逐个读进度条才发现问题。
    private var isCritical: Bool {
        (remaining ?? 100) <= 15
    }

    private var used: Double? {
        window.usedPercent.map { max(0, min(100, $0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle()
                    .fill(remaining == nil ? Color.secondary : tint)
                    .frame(width: 5, height: 5)

                Text(window.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(remaining.map { "\(Int($0.rounded(.down)))" } ?? "—")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remaining == nil ? Color.secondary : tint)
                    .contentTransition(.numericText())

                if remaining != nil {
                    Text("%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                }

                Text("剩余")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    if let remaining {
                        Capsule()
                            .fill(tint)
                            .frame(
                                width: max(
                                    remaining > 0 ? 3 : 0,
                                    proxy.size.width * max(0, min(1, remaining / 100))
                                )
                            )
                    }
                }
            }
            .frame(height: 4)

            HStack(spacing: 5) {
                if let used {
                    Text("已用 \(Int(used.rounded(.down)))%")
                } else {
                    Text("使用率未知")
                }

                Spacer(minLength: 4)

                if let reset = window.resetsAt {
                    Text(reset, style: .relative)
                        .help(reset.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("重置时间未知")
                }
            }
            .font(.system(size: 8.5))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isCritical
                        ? Color.red.opacity(0.10)
                        : Color.primary.opacity(0.055)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.title)额度")
        .accessibilityValue(
            remaining.map { "剩余\(Int($0))%" } ?? "剩余额度未知"
        )
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
                        HStack(spacing: 9) {
                            Image(systemName: row.provider.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(row.provider.tint)
                                .frame(width: 22, height: 22)
                                .background(
                                    row.provider.tint.opacity(0.13),
                                    in: RoundedRectangle(
                                        cornerRadius: 6,
                                        style: .continuous
                                    )
                                )

                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.displayName)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                Text(
                                    row.turns == 0 && row.usage.totalTokens == 0
                                        ? "\(row.provider.rawValue) · 活动中，等待用量落盘"
                                        : "\(row.provider.rawValue) · \(row.turns) 次"
                                )
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(TokenFormatter.compact(row.usage.inputTokens))
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)

                        Text(TokenFormatter.compact(row.usage.cachedReadTokens))
                            .foregroundStyle(.tertiary)
                            .frame(width: 62, alignment: .trailing)

                        Text(TokenFormatter.compact(row.usage.outputTokens))
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)

                        // Token 列带占比条：省掉一张单独的模型分布图。
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(TokenFormatter.compact(row.usage.totalTokens))
                                .fontWeight(.semibold)

                            GeometryReader { proxy in
                                ZStack(alignment: .trailing) {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.07))
                                    Capsule()
                                        .fill(row.provider.tint.opacity(0.85))
                                        .frame(
                                            width: proxy.size.width
                                                * share(of: row)
                                        )
                                }
                            }
                            .frame(height: 3)
                        }
                        .frame(width: 68, alignment: .trailing)

                        VStack(alignment: .trailing, spacing: 1) {
                            Text(row.costUSD.map {
                                CurrencyFormatter.usd($0)
                            } ?? "—")
                            .foregroundStyle(
                                row.costUSD == nil ? .tertiary : .primary
                            )

                            Text(costCaption(for: row))
                                .font(.system(size: 7.5))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: 72, alignment: .trailing)
                    }
                    .font(.system(size: 10.5, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if index < rows.count - 1 {
                        Divider()
                            .opacity(0.22)
                            .padding(.leading, 45)
                    }
                }
            }
        }
    }

    /// 相对本表最大值的占比，用于 Token 列的条。
    private func share(of row: ModelUsageRow) -> Double {
        let maximum = rows.map(\.usage.totalTokens).max() ?? 0
        guard maximum > 0 else { return 0 }
        return max(0, min(1, Double(row.usage.totalTokens) / Double(maximum)))
    }

    private func costCaption(for row: ModelUsageRow) -> String {
        guard let kind = row.costKind else {
            return row.costUSD == nil ? "无费用" : ""
        }
        return kind == .estimated ? "估算" : "日志"
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
        case .ninetyDays:
            return "最近 90 天"
        case .lifetime:
            return "全部历史"
        }
    }
}

/// 看板的表面层级。
///
/// 之前整页都是同一档深灰加一圈描边，层次只能靠边框读出来。现在页面本身是
/// 第 0 层，卡片抬一档，卡片内嵌的瓦片再抬一档，描边退成辅助。
private enum DashboardSurface {
    /// 直接放在页面上的卡片。
    case card
    /// 卡片内部的嵌套块（额度瓦片、提示行）。
    case inset

    var fill: Double {
        switch self {
        case .card: return 0.032
        case .inset: return 0.055
        }
    }

    var stroke: Double {
        switch self {
        case .card: return 0.055
        case .inset: return 0.0
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .card: return 13
        case .inset: return 10
        }
    }
}

private struct DashboardCardModifier: ViewModifier {
    var surface: DashboardSurface = .card

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(
                    cornerRadius: surface.cornerRadius,
                    style: .continuous
                )
                .fill(Color.primary.opacity(surface.fill))
            }
            .overlay {
                if surface.stroke > 0 {
                    RoundedRectangle(
                        cornerRadius: surface.cornerRadius,
                        style: .continuous
                    )
                    .stroke(
                        Color.primary.opacity(surface.stroke),
                        lineWidth: 1
                    )
                }
            }
    }
}

private extension View {
    func dashboardCard(
        _ surface: DashboardSurface = .card
    ) -> some View {
        modifier(DashboardCardModifier(surface: surface))
    }
}

private extension ProviderKind {
    var tint: Color {
        switch self {
        case .openAI:
            return Color(red: 0.18, green: 0.67, blue: 0.48)
        case .anthropic:
            return Color(red: 0.82, green: 0.46, blue: 0.30)
        case .alibaba:
            return Color(red: 0.39, green: 0.30, blue: 0.92)
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
        case .anthropic:
            return "sun.max.fill"
        case .alibaba:
            return "cloud.fill"
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
