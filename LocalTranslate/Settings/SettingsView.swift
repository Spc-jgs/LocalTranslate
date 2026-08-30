import SwiftUI
import Foundation

private enum PersonalToolPage: String, CaseIterable, Identifiable {
    case translation = "翻译"
    case usage = "AI 用量"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .translation:
            return "translate"
        case .usage:
            return "chart.bar.xaxis"
        }
    }

    var title: String {
        switch self {
        case .translation:
            return "翻译设置"
        case .usage:
            return "用量与额度"
        }
    }

    var subtitle: String {
        switch self {
        case .translation:
            return "本地模型、风格与运行参数"
        case .usage:
            return "今日模型、费用与订阅额度"
        }
    }
}

struct SettingsView: View {

    @ObservedObject
    private var usageStore = UsageStore.shared

    @State
    private var selectedPage: PersonalToolPage = .translation

    @AppStorage(AppSettings.Key.model)
    private var model = AppSettings.defaultModel

    @AppStorage(AppSettings.Key.baseURL)
    private var baseURL = AppSettings.defaultBaseURL

    @AppStorage(AppSettings.Key.keepAlive)
    private var keepAlive = AppSettings.defaultKeepAlive

    @AppStorage(AppSettings.Key.translationStyle)
    private var translationStyleRaw = AppSettings.defaultTranslationStyleRaw

    @AppStorage(AppSettings.Key.customPrompt)
    private var customPrompt = AppSettings.defaultCustomPrompt

    @State
    private var installedModels: [OllamaInstalledModel] = []

    @State
    private var diagnostics: OllamaModelDiagnostics?

    @State
    private var isLoading = false

    @State
    private var isLoadingDiagnostics = false

    @State
    private var connectionError: String?

    @State
    private var diagnosticsError: String?

    private var selectedModel: OllamaInstalledModel? {
        installedModels.first {
            $0.name == model
        }
    }

    private var selectedTranslationStyle: TranslationStyle {
        TranslationStyle(
            rawValue: translationStyleRaw
        ) ?? .standard
    }

    var body: some View {

        HStack(spacing: 0) {

            sidebar

            Divider()
                .opacity(0.34)

            VStack(spacing: 0) {

                pageHeader

                Divider()
                    .opacity(0.28)

                Group {
                    switch selectedPage {

                    case .translation:
                        translationSettingsContent

                    case .usage:
                        AIUsageView(
                            store: usageStore
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            width: 980,
            height: 700
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await refresh()
        }
        .onChange(
            of: model
        ) { _, _ in

            Task {
                await refreshDiagnostics()
            }
        }
    }

    // MARK: - Translation Content

    private var translationSettingsContent: some View {

        ScrollView(.vertical) {

            VStack(
                alignment: .leading,
                spacing: 18
            ) {

                connectionSection

                modelSection

                translationSection

                runtimeSection

                shortcutSection
            }
            .padding(24)
        }
        .scrollIndicators(.visible)
    }

    // MARK: - Navigation

    private var sidebar: some View {

        VStack(alignment: .leading, spacing: 0) {

            HStack(spacing: 10) {

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.gradient)

                    Image(systemName: "translate")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                .shadow(color: Color.accentColor.opacity(0.2), radius: 5, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("LocalTranslate")
                        .font(.system(size: 14, weight: .semibold))

                    Text("本机轻量工具箱")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 22)

            Text("设置")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.horizontal, 18)
                .padding(.bottom, 7)

            VStack(spacing: 4) {
                ForEach(PersonalToolPage.allCases) { page in
                    sidebarButton(for: page)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                Text("数据保留在本机")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(width: 205)
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(Color.primary.opacity(0.018))
        }
    }

    private func sidebarButton(for page: PersonalToolPage) -> some View {

        let isSelected = selectedPage == page

        return Button {
            selectedPage = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(page.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)

                    Text(page == .translation ? "Ollama 与快捷键" : "Token、成本与额度")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Header

    private var pageHeader: some View {

        HStack(spacing: 12) {

            VStack(
                alignment: .leading,
                spacing: 2
            ) {

                Text(selectedPage.title)
                    .font(
                        .system(
                            size: 17,
                            weight: .semibold
                        )
                    )

                Text(selectedPage.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {

                refreshCurrentPage()

            } label: {

                if currentPageIsRefreshing {

                    ProgressView()
                        .controlSize(.small)

                } else {

                    Image(
                        systemName: "arrow.clockwise"
                    )
                }
            }
            .buttonStyle(.borderless)
            .frame(
                width: 30,
                height: 30
            )
            .disabled(currentPageIsRefreshing)
            .help(
                selectedPage == .translation
                ? "刷新 Ollama 状态"
                : "刷新 AI 用量"
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
    }

    private var currentPageIsRefreshing: Bool {
        switch selectedPage {
        case .translation:
            return isLoading
        case .usage:
            return usageStore.isRefreshing
        }
    }

    private func refreshCurrentPage() {
        switch selectedPage {
        case .translation:
            Task {
                await refresh()
            }
        case .usage:
            Task {
                await usageStore.refresh()
            }
        }
    }

    // MARK: - Ollama Connection

    private var connectionSection: some View {

        settingsSection(
            title: "OLLAMA 连接",
            systemImage: "server.rack"
        ) {

            VStack(spacing: 12) {

                settingsRow(
                    title: "服务状态"
                ) {

                    if isLoading {

                        HStack(spacing: 6) {

                            ProgressView()
                                .controlSize(.mini)

                            Text("正在连接…")
                                .foregroundStyle(.secondary)
                        }

                    } else if connectionError == nil {

                        HStack(spacing: 6) {

                            Circle()
                                .fill(.green)
                                .frame(
                                    width: 7,
                                    height: 7
                                )

                            Text("已连接")

                            Text(
                                "· \(installedModels.count) 个模型"
                            )
                            .foregroundStyle(.secondary)
                        }

                    } else {

                        HStack(spacing: 6) {

                            Circle()
                                .fill(.red)
                                .frame(
                                    width: 7,
                                    height: 7
                                )

                            Text("连接失败")
                        }
                    }
                }

                rowDivider

                settingsRow(
                    title: "服务地址"
                ) {

                    TextField(
                        "",
                        text: $baseURL
                    )
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 320)
                    .onSubmit {

                        Task {
                            await refresh()
                        }
                    }
                }

                if let connectionError {

                    rowDivider

                    Label(
                        connectionError,
                        systemImage:
                            "exclamationmark.circle"
                    )
                    .font(
                        .system(size: 11)
                    )
                    .foregroundStyle(.red)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }
            }
        }
    }

    // MARK: - Model

    private var modelSection: some View {

        settingsSection(
            title: "模型选择",
            systemImage: "cpu"
        ) {

            VStack(spacing: 11) {

                settingsRow(
                    title: "当前翻译模型"
                ) {

                    Picker(
                        "",
                        selection: $model
                    ) {

                        if installedModels.isEmpty {

                            Text(model)
                                .tag(model)

                        } else {

                            ForEach(
                                installedModels
                            ) { item in

                                Text(item.name)
                                    .tag(item.name)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }

                if let selectedModel {

                    rowDivider

                    detailRow(
                        title: "参数规模",
                        value:
                            selectedModel.parameterSize
                            ?? "未知"
                    )

                    detailRow(
                        title: "权重量化",
                        value:
                            selectedModel.quantizationLevel
                            ?? "未知"
                    )

                    detailRow(
                        title: "模型大小",
                        value:
                            selectedModel.formattedSize
                    )

                    if let family =
                        selectedModel.family {

                        detailRow(
                            title: "模型家族",
                            value: family
                        )
                    }

                    if let format =
                        selectedModel.format {

                        detailRow(
                            title: "格式",
                            value:
                                format.uppercased()
                        )
                    }
                }
            }
        }
    }

    // MARK: - Translation Style

    private var translationSection: some View {

        settingsSection(
            title: "翻译偏好与风格",
            systemImage: "text.bubble"
        ) {

            VStack(
                alignment: .leading,
                spacing: 12
            ) {

                settingsRow(
                    title: "默认翻译风格"
                ) {

                    Picker(
                        "",
                        selection: $translationStyleRaw
                    ) {

                        ForEach(
                            TranslationStyle.allCases
                        ) { style in

                            Text(style.title)
                                .tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                Text(
                    selectedTranslationStyle.shortDescription
                )
                .font(
                    .system(size: 11)
                )
                .foregroundStyle(.tertiary)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )

                rowDivider

                VStack(
                    alignment: .leading,
                    spacing: 8
                ) {

                    HStack {

                        Text("自定义 Prompt")
                            .font(
                                .system(size: 12)
                            )
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(
                            selectedTranslationStyle == .custom
                            ? "当前生效"
                            : "选择“自定义”风格时生效"
                        )
                        .font(
                            .system(size: 10)
                        )
                        .foregroundStyle(
                            selectedTranslationStyle == .custom
                            ? .secondary
                            : .tertiary
                        )
                    }

                    TextField(
                        "例如：保持互联网口语风格，表达自然，不要过度正式。",
                        text: $customPrompt,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(
                        .system(size: 12)
                    )
                    .lineLimit(3...6)
                    .padding(12)
                    .background {

                        RoundedRectangle(
                            cornerRadius: 9,
                            style: .continuous
                        )
                        .fill(
                            Color.primary.opacity(0.028)
                        )
                    }
                    .overlay {

                        RoundedRectangle(
                            cornerRadius: 9,
                            style: .continuous
                        )
                        .stroke(
                            Color.primary.opacity(0.06),
                            lineWidth: 1
                        )
                    }

                    Text(
                        "自定义 Prompt 作为附加风格指令，不会破坏技术标识符和代码块的保护规则。留空时等同于默认风格。"
                    )
                    .font(
                        .system(size: 10)
                    )
                    .foregroundStyle(.tertiary)
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                }
            }
        }
    }

    // MARK: - Runtime

    private var runtimeSection: some View {

        settingsSection(
            title: "运行与内存",
            systemImage: "gauge.with.dots.needle.50percent"
        ) {

            VStack(spacing: 11) {

                if isLoadingDiagnostics {

                    HStack(spacing: 8) {

                        ProgressView()
                            .controlSize(.small)

                        Text(
                            "正在读取模型运行信息…"
                        )
                        .font(
                            .system(size: 11)
                        )
                        .foregroundStyle(.secondary)

                        Spacer()
                    }

                } else {

                    detailRow(
                        title: "原生上下文",
                        value:
                            formatContextLength(
                                diagnostics?
                                    .nativeContextLength
                            )
                    )

                    detailRow(
                        title: "当前上下文",
                        value:
                            runtimeContextText
                    )

                    detailRow(
                        title: "当前运行内存",
                        value:
                            runtimeMemoryText
                    )

                    detailRow(
                        title: "KV Cache 量化",
                        value:
                            diagnostics?
                                .kvCacheQuantization
                            ?? "未检测"
                    )

                    detailRow(
                        title: "模型加载状态",
                        value:
                            diagnostics?.isRunning == true
                            ? "已在内存中加载"
                            : "就绪 (未常驻)"
                    )

                    rowDivider

                    settingsRow(
                        title: "模型驻留时间 (Keep Alive)"
                    ) {

                        Picker(
                            "",
                            selection:
                                $keepAlive
                        ) {

                            Text("立即释放")
                                .tag("0")

                            Text("5 分钟")
                                .tag("5m")

                            Text("10 分钟")
                                .tag("10m")

                            Text("30 分钟")
                                .tag("30m")

                            Text("1 小时")
                                .tag("1h")
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }

                    Text(
                        "KV Cache 量化由 Ollama Server 环境变量 OLLAMA_KV_CACHE_TYPE 控制。"
                    )
                    .font(
                        .system(size: 10)
                    )
                    .foregroundStyle(.tertiary)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }

                if let diagnosticsError {

                    rowDivider

                    Label(
                        diagnosticsError,
                        systemImage:
                            "exclamationmark.circle"
                    )
                    .font(
                        .system(size: 10)
                    )
                    .foregroundStyle(.orange)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }
            }
        }
    }

    // MARK: - Shortcut

    private var shortcutSection: some View {

        settingsSection(
            title: "全局快捷键",
            systemImage: "keyboard"
        ) {

            settingsRow(
                title: "取词翻译 / 打开浮窗"
            ) {

                Text("⌥ ⇧ T")
                    .font(
                        .system(
                            size: 12,
                            weight: .medium,
                            design: .rounded
                        )
                    )
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background {

                        RoundedRectangle(
                            cornerRadius: 7,
                            style: .continuous
                        )
                        .fill(
                            Color.primary.opacity(0.06)
                        )
                    }
            }
        }
    }

    // MARK: - Components

    private func settingsSection<
        Content: View
    >(
        title: String,
        systemImage: String,
        @ViewBuilder
        content: () -> Content
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 8
        ) {

            Label(
                title,
                systemImage: systemImage
            )
            .font(
                .system(
                    size: 11,
                    weight: .semibold
                )
            )
            .foregroundStyle(.secondary)

            content()
                .padding(16)
                .background {

                    RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                    .fill(
                        Color.primary.opacity(0.035)
                    )
                }
                .overlay {

                    RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                    .stroke(
                        Color.primary.opacity(0.045),
                        lineWidth: 1
                    )
                }
        }
    }

    private func settingsRow<
        Content: View
    >(
        title: String,
        @ViewBuilder
        content: () -> Content
    ) -> some View {

        HStack(spacing: 12) {

            Text(title)
                .font(
                    .system(size: 13)
                )
                .foregroundStyle(.primary.opacity(0.85))

            Spacer()

            content()
        }
    }

    private func detailRow(
        title: String,
        value: String
    ) -> some View {

        HStack {

            Text(title)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .fontWeight(.medium)
        }
        .font(
            .system(size: 12)
        )
    }

    private var rowDivider: some View {

        Divider()
            .opacity(0.22)
    }

    // MARK: - Display

    private var runtimeContextText: String {

        guard let diagnostics else {
            return "未知"
        }

        guard diagnostics.isRunning else {
            return "未加载"
        }

        return formatContextLength(
            diagnostics.runtimeContextLength
        )
    }

    private var runtimeMemoryText: String {

        guard let diagnostics else {
            return "未知"
        }

        guard diagnostics.isRunning else {
            return "未加载"
        }

        guard let bytes =
            diagnostics.runtimeMemoryBytes
        else {
            return "未知"
        }

        return ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .memory
        )
    }

    private func formatContextLength(
        _ value: Int?
    ) -> String {

        guard let value else {
            return "未知"
        }

        if value >= 1_048_576 {

            let mega =
                Double(value)
                / 1_048_576.0

            return String(
                format: "%.1fM",
                mega
            )
        }

        if value >= 1024 {

            let kilo =
                Double(value)
                / 1024.0

            if kilo.rounded() == kilo {

                return "\(Int(kilo))K"
            }

            return String(
                format: "%.1fK",
                kilo
            )
        }

        return "\(value)"
    }

    // MARK: - Refresh

    @MainActor
    private func refresh() async {

        guard !isLoading else {
            return
        }

        isLoading = true

        connectionError = nil
        diagnosticsError = nil

        do {

            let models =
                try await
                OllamaClient.shared
                    .installedModels()

            installedModels = models

            if
                !models.contains(
                    where: {
                        $0.name == model
                    }
                ),
                let first =
                    models.first {

                model = first.name
            }

            await refreshDiagnostics()

        } catch {

            installedModels = []

            diagnostics = nil

            connectionError =
                error.localizedDescription
        }

        isLoading = false
    }

    @MainActor
    private func
    refreshDiagnostics() async {

        guard !model.isEmpty else {

            diagnostics = nil
            return
        }

        guard !isLoadingDiagnostics else {
            return
        }

        isLoadingDiagnostics = true

        diagnosticsError = nil

        do {

            diagnostics =
                try await
                OllamaClient.shared
                    .modelDiagnostics(
                        for: model
                    )

        } catch {

            diagnostics = nil

            diagnosticsError =
                "模型运行信息读取失败：\(error.localizedDescription)"
        }

        isLoadingDiagnostics = false
    }
}

#Preview {
    SettingsView()
}
