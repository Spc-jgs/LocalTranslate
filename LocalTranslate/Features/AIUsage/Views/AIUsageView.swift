import SwiftUI
import Charts

struct AIUsageView: View {
    @ObservedObject var store: UsageStore

    @State
    private var chartRange: UsageChartRange = .thirtyDays

    private var currentMetrics: ChartMetrics {
        chartRange == .sevenDays ? store.metrics7Days : store.metrics30Days
    }

    private var allModels: [ModelActivity] {
        var byModelID: [String: ModelActivity] = [:]
        for account in store.accounts {
            for model in account.modelActivity {
                if var existing = byModelID[model.modelID] {
                    var mergedUsage = existing.usage
                    mergedUsage.add(model.usage)
                    let mergedTurns = existing.turns + model.turns
                    let mergedCost = (existing.costUSD ?? 0) + (model.costUSD ?? 0)
                    byModelID[model.modelID] = ModelActivity(
                        modelID: model.modelID,
                        displayName: model.displayName,
                        period: .thirtyDays,
                        usage: mergedUsage,
                        turns: mergedTurns,
                        costUSD: mergedCost > 0 ? mergedCost : nil
                    )
                } else {
                    byModelID[model.modelID] = model
                }
            }
        }
        return byModelID.values.sorted { $0.usage.totalTokens > $1.usage.totalTokens }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                if store.accounts.isEmpty && store.isRefreshing {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("正在读取本机 AI 使用情况 (Codex + AGY + Grok)…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                }

                if !store.errors.isEmpty {
                    errorPanel
                }

                if !store.accounts.isEmpty {
                    TotalUsageChart(
                        metrics: currentMetrics,
                        range: $chartRange
                    )

                    if !allModels.isEmpty {
                        GlobalModelsOverviewCard(models: allModels)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(store.accounts) { account in
                            AccountCard(account: account)
                        }
                    }
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

    private var errorPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("部分 Provider 读取失败", systemImage: "exclamationmark.triangle")
                .font(.headline)

            ForEach(store.errors.keys.sorted(), id: \.self) { key in
                if let message = store.errors[key] {
                    Text("\(key): \(message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private enum UsageChartRange: String, CaseIterable, Identifiable {
    case sevenDays = "7 天"
    case thirtyDays = "30 天"

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .sevenDays:
            return 7
        case .thirtyDays:
            return 30
        }
    }
}

private struct TotalUsageChart: View {
    let metrics: ChartMetrics

    @Binding
    var range: UsageChartRange

    @State
    private var rawSelectedDate: Date? = nil

    private var selectedPoint: DailyActivity? {
        guard let rawSelectedDate else { return nil }
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: rawSelectedDate)
        return metrics.points.min(by: {
            abs($0.date.timeIntervalSince(targetDay)) < abs($1.date.timeIntervalSince(targetDay))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("总 Token 趋势")
                        .font(.system(size: 15, weight: .semibold))

                    Text("Codex + AGY + Grok 每日汇总 · 鼠标悬停查看单日详情")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("", selection: $range) {
                    ForEach(UsageChartRange.allCases) { item in
                        Text(item.rawValue)
                            .tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            HStack(spacing: 20) {
                if let selected = selectedPoint {
                    chartMetric(
                        title: "选中: \(selected.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))",
                        value: TokenFormatter.compact(selected.tokens)
                    )
                    .foregroundStyle(Color.accentColor)

                    if selected.turns > 0 {
                        chartMetric(
                            title: "交互轮次 / 步骤",
                            value: "\(selected.turns) 次"
                        )
                    }
                } else {
                    chartMetric(
                        title: "总计",
                        value: TokenFormatter.compact(metrics.totalTokens)
                    )

                    chartMetric(
                        title: "日均",
                        value: TokenFormatter.compact(metrics.averageTokens)
                    )

                    chartMetric(
                        title: "峰值",
                        value: metrics.peak.map { TokenFormatter.compact($0.tokens) } ?? "0"
                    )

                    if let peak = metrics.peak {
                        chartMetric(
                            title: "峰值日期",
                            value: peak.date.formatted(
                                .dateTime.month(.twoDigits).day(.twoDigits)
                            )
                        )
                    }
                }

                Spacer()
            }

            Chart {
                ForEach(metrics.points) { point in
                    AreaMark(
                        x: .value("日期", point.date),
                        y: .value("Token", Double(point.tokens))
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.24),
                                Color.accentColor.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("日期", point.date),
                        y: .value("Token", Double(point.tokens))
                    )
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: 2,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                    if range == .sevenDays {
                        PointMark(
                            x: .value("日期", point.date),
                            y: .value("Token", Double(point.tokens))
                        )
                        .symbolSize(22)
                    }
                }

                if let selected = selectedPoint {
                    RuleMark(x: .value("Selected Date", selected.date))
                        .foregroundStyle(Color.accentColor.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(
                            position: .top,
                            alignment: .center,
                            spacing: 8
                        ) {
                            tooltipView(for: selected)
                        }

                    PointMark(
                        x: .value("Selected Date", selected.date),
                        y: .value("Token", Double(selected.tokens))
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(60)
                }
            }
            .chartXSelection(value: $rawSelectedDate)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                        .foregroundStyle(.separator.opacity(0.3))

                    AxisValueLabel {
                        if let rawValue = value.as(Double.self) {
                            Text(
                                TokenFormatter.compact(
                                    Int64(rawValue.rounded())
                                )
                            )
                            .font(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(
                    values: .automatic(
                        desiredCount: range == .sevenDays ? 7 : 6
                    )
                ) { value in
                    AxisGridLine()
                        .foregroundStyle(.separator.opacity(0.15))

                    AxisValueLabel(
                        format: .dateTime.month(.twoDigits).day(.twoDigits)
                    )
                    .font(.caption2)
                }
            }
            .frame(height: 210)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 1)
        }
    }

    private func tooltipView(for item: DailyActivity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text(TokenFormatter.formattedNumber(item.tokens))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text("Tokens")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if item.turns > 0 {
                Text("\(item.turns) 次交互 / 步")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
    }

    private func chartMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
    }
}

private struct GlobalModelsOverviewCard: View {
    let models: [ModelActivity]
    @State private var isExpanded = false

    private var maxModelTokens: Int64 {
        models.map { $0.usage.totalTokens }.max() ?? 1
    }

    private var displayedModels: [ModelActivity] {
        if isExpanded || models.count <= 6 {
            return models
        }
        return Array(models.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("模型 Token 用量（按模型分组）")
                        .font(.system(size: 15, weight: .semibold))
                    Text("近 30 天各 AI 模型 Token 消耗总量与四维构成明细")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if models.count > 6 {
                    Button(isExpanded ? "收起" : "展开全部 (\(models.count)个模型)") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
            }

            VStack(spacing: 9) {
                ForEach(displayedModels) { model in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(model.displayName)
                                .font(.system(size: 13, weight: .semibold))

                            providerTag(for: model.modelID)

                            Spacer()

                            Text(TokenFormatter.formattedNumber(model.usage.totalTokens))
                                .font(.system(size: 13, weight: .bold, design: .monospaced))

                            Text("Tokens")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        // Proportion Bar
                        GeometryReader { proxy in
                            let totalWidth = proxy.size.width
                            let ratio = max(0.02, min(1.0, Double(model.usage.totalTokens) / Double(max(1, maxModelTokens))))

                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.04))
                                    .frame(height: 6)

                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: totalWidth * CGFloat(ratio), height: 6)
                            }
                        }
                        .frame(height: 6)

                        HStack(spacing: 16) {
                            metricTag("Fresh Input", model.usage.freshInputTokens)
                            metricTag("Cache Read", model.usage.cachedReadTokens)
                            metricTag("Output", model.usage.normalOutputTokens)
                            if model.usage.reasoningTokens > 0 {
                                metricTag("Reasoning", model.usage.reasoningTokens)
                            }
                            if model.turns > 0 {
                                Spacer()
                                Text("\(model.turns) turns/steps")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 1)
        }
    }

    private func providerTag(for modelID: String) -> some View {
        let tag: String
        let color: Color

        if modelID.contains("grok") {
            tag = "xAI"
            color = .purple
        } else if modelID.contains("gemini") {
            tag = "Google"
            color = .blue
        } else {
            tag = "OpenAI"
            color = .green
        }

        return Text(tag)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(color)
    }

    private func metricTag(_ label: String, _ value: Int64) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(TokenFormatter.compact(value))
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct AccountCard: View {
    let account: AccountSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountHeader

            if !account.quotaWindows.isEmpty {
                sectionTitle("额度周期")
                ForEach(account.quotaWindows) { window in
                    QuotaRow(window: window)
                }
            }

            if !account.activity.isEmpty {
                sectionTitle("Token 使用")
                activityGrid
            }

            HStack {
                Text(account.sourceLabel)
                Spacer()
                Text("可信度: \(account.confidence.rawValue)")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 1)
        }
    }

    private var accountHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(account.provider.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if let plan = account.plan {
                        Text(plan)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }

                Text(account.displayName)
                    .font(.system(size: 16, weight: .bold))

                if let email = account.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let message = account.statusMessage {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(message)
            }
        }
    }

    private var activityGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ],
            spacing: 10
        ) {
            ForEach(account.activity) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(periodTitle(item.period))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(TokenFormatter.compact(item.tokens))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))

                    if item.turns > 0 {
                        Text("\(item.turns) turns/steps")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func periodTitle(_ period: ActivityPeriod) -> String {
        switch period {
        case .today:
            return "今天"
        case .sevenDays:
            return "7 天"
        case .thirtyDays:
            return "30 天"
        case .lifetime:
            return "全部历史"
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .tracking(0.7)
    }
}

private struct QuotaRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.title)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                if let remaining = window.remainingPercent {
                    Text("剩余 \(Int(remaining.rounded(.down)))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(remaining < 15 ? .red : .primary)
                } else {
                    Text("未知")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let used = window.usedPercent {
                ProgressView(value: min(100, max(0, used)), total: 100)
            }

            if let reset = window.resetsAt {
                Text("重置 \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

enum TokenFormatter {
    static func compact(_ value: Int64) -> String {
        let number = Double(value)
        let absValue = abs(number)

        if absValue >= 1_000_000_000 {
            return String(format: "%.2fB", number / 1_000_000_000)
        }
        if absValue >= 1_000_000 {
            return String(format: "%.2fM", number / 1_000_000)
        }
        if absValue >= 1_000 {
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
