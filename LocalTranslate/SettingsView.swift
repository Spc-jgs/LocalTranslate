import SwiftUI
import Foundation

struct SettingsView: View {

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

        VStack(spacing: 0) {

            header

            Divider()
                .opacity(0.28)

            ScrollView(.vertical) {

                VStack(
                    alignment: .leading,
                    spacing: 16
                ) {

                    connectionSection

                    modelSection

                    translationSection

                    runtimeSection

                    shortcutSection
                }
                .padding(
                    EdgeInsets(
                        top: 16,
                        leading: 18,
                        bottom: 18,
                        trailing: 18
                    )
                )
            }
            .scrollIndicators(.hidden)
        }
        .frame(
            width: 530,
            height: 650
        )
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

    // MARK: - Header

    private var header: some View {

        HStack(spacing: 12) {

            ZStack {

                RoundedRectangle(
                    cornerRadius: 9,
                    style: .continuous
                )
                .fill(
                    Color.primary.opacity(0.06)
                )

                Image(
                    systemName: "character.book.closed"
                )
                .font(
                    .system(
                        size: 14,
                        weight: .semibold
                    )
                )
                .foregroundStyle(.secondary)
            }
            .frame(
                width: 32,
                height: 32
            )

            VStack(
                alignment: .leading,
                spacing: 2
            ) {

                Text("Local Translate")
                    .font(
                        .system(
                            size: 15,
                            weight: .semibold
                        )
                    )

                Text("设置")
                    .font(
                        .system(size: 11)
                    )
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {

                Task {
                    await refresh()
                }

            } label: {

                if isLoading {

                    ProgressView()
                        .controlSize(.small)

                } else {

                    Image(
                        systemName: "arrow.clockwise"
                    )
                }
            }
            .buttonStyle(.plain)
            .frame(
                width: 28,
                height: 28
            )
            .disabled(isLoading)
            .help("刷新 Ollama 状态")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Ollama

    private var connectionSection: some View {

        settingsSection(
            title: "OLLAMA",
            systemImage: "server.rack"
        ) {

            VStack(spacing: 12) {

                settingsRow(
                    title: "状态"
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
                    title: "地址"
                ) {

                    TextField(
                        "",
                        text: $baseURL
                    )
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 280)
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
            title: "模型",
            systemImage: "cpu"
        ) {

            VStack(spacing: 11) {

                settingsRow(
                    title: "当前模型"
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
                    .frame(width: 250)
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

    // MARK: - Translation

    private var translationSection: some View {

        settingsSection(
            title: "翻译",
            systemImage: "text.bubble"
        ) {

            VStack(
                alignment: .leading,
                spacing: 12
            ) {

                settingsRow(
                    title: "默认风格"
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
                    .frame(width: 170)
                }

                Text(
                    selectedTranslationStyle.shortDescription
                )
                .font(
                    .system(size: 10)
                )
                .foregroundStyle(.tertiary)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )

                rowDivider

                VStack(
                    alignment: .leading,
                    spacing: 7
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
                            : "选择“自定义”时生效"
                        )
                        .font(
                            .system(size: 9)
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
                        .system(size: 11)
                    )
                    .lineLimit(4...7)
                    .padding(10)
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
                            Color.primary.opacity(0.05),
                            lineWidth: 1
                        )
                    }

                    Text(
                        "自定义 Prompt 只作为附加风格指令，不会覆盖 Local Translate 的基础翻译规则、翻译方向和代码保护规则。留空时等同于默认风格。"
                    )
                    .font(
                        .system(size: 9)
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
            title: "运行",
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
                        title: "模型状态",
                        value:
                            diagnostics?.isRunning == true
                            ? "已加载"
                            : "未加载"
                    )

                    rowDivider

                    settingsRow(
                        title: "模型驻留时间"
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
                        .frame(width: 150)
                    }

                    Text(
                        "KV Cache 量化由 Ollama Server 的 OLLAMA_KV_CACHE_TYPE 控制，当前 Ollama API 不直接返回该值。"
                    )
                    .font(
                        .system(size: 9)
                    )
                    .foregroundStyle(.tertiary)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .padding(.top, 2)
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
            title: "快捷键",
            systemImage: "keyboard"
        ) {

            settingsRow(
                title: "翻译 / 打开输入框"
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
                .padding(14)
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
                    .system(size: 12)
                )
                .foregroundStyle(.secondary)

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
