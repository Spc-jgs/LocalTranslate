import SwiftUI
import AppKit

public struct LiveSubtitlesView: View {

    @ObservedObject private var viewModel = LiveSubtitlesViewModel.shared
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        ZStack(alignment: .center) {
            // The caption always owns a contrast surface. Relying on shadows
            // alone makes text unreadable over bright interview footage.
            RoundedRectangle(
                cornerRadius: LiveSubtitlesOverlayLayout.cornerRadius,
                style: .continuous
            )
                .fill(
                    Color.black.opacity(
                        isHovering || !viewModel.isRunning || viewModel.showHistoryDrawer
                            ? 0.82
                            : 0.56
                    )
                )
                .background(
                    AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(
                        cornerRadius: LiveSubtitlesOverlayLayout.cornerRadius,
                        style: .continuous
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: LiveSubtitlesOverlayLayout.cornerRadius,
                        style: .continuous
                    )
                        .stroke(
                            Color.white.opacity(
                                isHovering || !viewModel.isRunning || viewModel.showHistoryDrawer
                                    ? 0.12
                                    : 0.06
                            ),
                            lineWidth: 1
                        )
                )

            // 核心字幕展示区：只强调正在说的这一句。
            VStack(spacing: 0) {
                if !viewModel.showHistoryDrawer {
                    rollingSubtitleDisplayArea
                        .transition(.opacity)
                } else {
                    // 台词历史回溯抽屉
                    subtitleHistoryDrawer
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, viewModel.showHistoryDrawer ? 50 : 0)

            // 顶部 Apple 原生悬浮工具条 (绝对定位在顶部)
            VStack {
                if isHovering || !viewModel.isRunning || viewModel.showHistoryDrawer {
                    topControlBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .padding(.top, 12)
                }
                Spacer()
            }
        }
        .contentShape(
            RoundedRectangle(
                cornerRadius: LiveSubtitlesOverlayLayout.cornerRadius,
                style: .continuous
            )
        )
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.15),
            value: isHovering
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: viewModel.showHistoryDrawer
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: viewModel.isClickThrough) { _, newValue in
            LiveSubtitlesOverlayPanel.shared.setClickThrough(newValue)
        }
        .onChange(of: viewModel.showHistoryDrawer) { _, isExpanded in
            LiveSubtitlesOverlayPanel.shared.setHistoryExpanded(isExpanded)
        }
    }

    // MARK: - Top Control Bar (Apple 原生控件)

    private var topControlBar: some View {
        HStack(spacing: 8) {
            // 状态指示灯与动态音浪
            HStack(spacing: 5) {
                Circle()
                    .fill(viewModel.isRunning ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)

                if viewModel.isRunning {
                    audioWaveView
                }

                Text(
                    viewModel.isPreparing
                        ? "准备中"
                        : (viewModel.isRunning ? "同传中" : "已暂停")
                )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(viewModel.isRunning ? .green : .secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.06), in: Capsule())

            if viewModel.isRunning && viewModel.isCatchingUp {
                Text("追赶中")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.1), in: Capsule())
            }

            // 源语言选择器 (macOS 原生菜单)
            Picker("", selection: Binding(
                get: { viewModel.sourceLanguage },
                set: { viewModel.setSourceLanguage($0) }
            )) {
                ForEach(SubtitleSourceLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 125)
            .controlSize(.small)

            // 双语 / 仅译文 / 仅原文 模式选择 (macOS 原生分段器)
            Picker("", selection: Binding(
                get: { viewModel.displayMode },
                set: { viewModel.setDisplayMode($0) }
            )) {
                ForEach(SubtitleDisplayMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.iconName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 135)
            .controlSize(.mini)

            Spacer()

            // 字号微调
            HStack(spacing: 2) {
                NativeIconButton(
                    systemName: "textformat.size.smaller",
                    helpText: "减小字号",
                    isEnabled: viewModel.canDecreaseFontSize
                ) {
                    viewModel.adjustFontSize(
                        delta: -AppSettings.liveFontSizeStep
                    )
                }

                Text("\(Int(viewModel.fontSize))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 18)

                NativeIconButton(
                    systemName: "textformat.size.larger",
                    helpText: "增大字号",
                    isEnabled: viewModel.canIncreaseFontSize
                ) {
                    viewModel.adjustFontSize(
                        delta: AppSettings.liveFontSizeStep
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            // 点击穿透：让鼠标事件落到下面的播放器
            NativeIconButton(
                systemName: viewModel.isClickThrough
                    ? "cursorarrow.slash"
                    : "cursorarrow",
                tintColor: viewModel.isClickThrough
                    ? .accentColor
                    : .white.opacity(0.75),
                helpText: viewModel.isClickThrough
                    ? "恢复接收鼠标事件"
                    : "点击穿透：鼠标事件交给下层窗口"
                        + "（开启后请从菜单栏关闭）"
            ) {
                viewModel.toggleClickThrough()
            }

            // 历史台词回溯抽屉
            NativeIconButton(
                systemName: viewModel.showHistoryDrawer ? "clock.fill" : "clock",
                tintColor: viewModel.showHistoryDrawer ? .accentColor : .white.opacity(0.75),
                helpText: viewModel.showHistoryDrawer ? "关闭台词历史" : "回溯最近台词历史"
            ) {
                viewModel.toggleHistoryDrawer()
            }

            // 开始/暂停
            NativeIconButton(
                systemName: viewModel.isRunning ? "pause.fill" : "play.fill",
                helpText: viewModel.isRunning ? "暂停同传" : "开启同传"
            ) {
                viewModel.toggleRunning()
            }

            // 清屏
            NativeIconButton(
                systemName: "trash",
                helpText: "清空当前字幕"
            ) {
                viewModel.clearSubtitles()
            }

            // 关闭
            NativeIconButton(
                systemName: "xmark",
                helpText: "关闭实时字幕条"
            ) {
                viewModel.stop()
                LiveSubtitlesOverlayPanel.shared.orderOut(nil)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Rolling Subtitle Display Area (滚动双行字幕流)

    private var rollingSubtitleDisplayArea: some View {
        VStack(spacing: 4) {
            if hasActiveContent {
                activeCaption
            } else if viewModel.isPreparing {
                Text("正在准备本机语音与翻译模型...")
                    .font(.system(size: viewModel.fontSize * 0.72, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            } else if viewModel.isRunning {
                // 等待声音输入状态（仅在从未接收到任何声音时显示）
                VStack(spacing: 3) {
                    Text("正在聆听电影/视频声音...")
                        .font(.system(size: viewModel.fontSize * 0.72, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    if viewModel.audioLevel < 0.02 {
                        Text("（💡 需开启电脑声音或佩戴耳机播放，完全静音时无法提取声波）")
                            .font(.system(size: 10.5))
                            .foregroundColor(.white.opacity(0.38))
                    }
                }
                .multilineTextAlignment(.center)
            } else {
                Text("点击顶部 ▶ 开启实时字幕同传")
                    .font(.system(size: viewModel.fontSize * 0.72, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
            }

            // 错误提示
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var activeCaption: some View {
        VStack(spacing: 3) {
            if shouldShowTranslation && !primaryCaptionText.isEmpty {
                Text(primaryCaptionText)
                    .font(.system(size: viewModel.fontSize, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: LiveSubtitlesOverlayLayout.captionMaximumWidth)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(
                        Color.accentColor.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .shadow(color: .black.opacity(0.95), radius: 2, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.9), radius: 6, x: 0, y: 2)
            }

            if shouldShowOriginal && shouldShowSourceLine {
                Text(activeSourceDisplayText)
                    .font(.system(size: max(viewModel.fontSize * 0.56, 14), weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: LiveSubtitlesOverlayLayout.sourceLineMaximumWidth)
                    .shadow(color: .black.opacity(0.95), radius: 2, x: 0, y: 1)
            }
        }
    }

    // MARK: - Subtitle History Drawer (台词历史回溯抽屉)

    private var subtitleHistoryDrawer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("台词历史回溯 (最近 \(viewModel.subtitleHistory.count) 条)", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))

                Spacer()

                Button("复制全部") {
                    let fullText = viewModel.subtitleHistory.map {
                        "\($0.translatedText)\n\($0.originalText)"
                    }.joined(separator: "\n\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullText, forType: .string)
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 4)

            Divider()
                .background(Color.white.opacity(0.12))

            if viewModel.subtitleHistory.isEmpty {
                Text("暂无台词历史，播放视频后将自动记录...")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.subtitleHistory) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.translatedText)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)

                                    if !item.originalText.isEmpty && item.originalText != item.translatedText {
                                        Text(item.originalText)
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onAppear {
                        if let last = viewModel.subtitleHistory.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    // 抽屉打开期间新字幕会不断追加，不跟随就得手动往下拖。
                    .onChange(of: viewModel.subtitleHistory.count) { _, _ in
                        guard let last = viewModel.subtitleHistory.last else {
                            return
                        }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Audio Wave View

    private var audioWaveView: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.green)
                    .frame(
                        width: 2,
                        height: max(3, CGFloat(viewModel.audioLevel * 14 * Float(index + 1) * 0.5))
                    )
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.1),
                        value: viewModel.audioLevel
                    )
            }
        }
        .frame(height: 10)
    }

    // MARK: - Helpers

    private var primaryCaptionText: String {
        if viewModel.displayMode == .originalOnly {
            return activeSourceDisplayText
        }
        if !viewModel.currentTranslatedText.isEmpty {
            return viewModel.currentTranslatedText
        }
        return activeSourceDisplayText
    }

    private var activeSourceDisplayText: String {
        let words = viewModel.currentOriginalText
            .split(whereSeparator: \Character.isWhitespace)
        guard words.count > 20 else { return viewModel.currentOriginalText }
        return words.suffix(20).joined(separator: " ")
    }

    private var shouldShowSourceLine: Bool {
        viewModel.displayMode != .chineseOnly
            && viewModel.displayMode != .originalOnly
            && !viewModel.currentTranslatedText.isEmpty
            && !activeSourceDisplayText.isEmpty
    }

    private var hasActiveContent: Bool {
        !viewModel.currentOriginalText.isEmpty
            || !viewModel.currentTranslatedText.isEmpty
    }

    private var shouldShowTranslation: Bool {
        viewModel.displayMode == .bilingual || viewModel.displayMode == .chineseOnly
    }

    private var shouldShowOriginal: Bool {
        viewModel.displayMode == .bilingual || viewModel.displayMode == .originalOnly
    }
}

// MARK: - Native Icon Button

private struct NativeIconButton: View {
    let systemName: String
    var tintColor: Color = .white.opacity(0.75)
    var helpText: String = ""
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(
                    isEnabled ? tintColor : tintColor.opacity(0.35)
                )
                .frame(width: 22, height: 22)
                .background(
                    isHovered && isEnabled
                        ? Color.white.opacity(0.12)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(helpText)
        // 工具条全是纯图标按钮，没有标签时 VoiceOver 只会读出 "按钮"。
        .accessibilityLabel(Text(helpText))
        .onHover { isHovered = $0 }
    }
}
