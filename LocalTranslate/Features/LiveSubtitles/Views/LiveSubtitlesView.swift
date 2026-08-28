import SwiftUI
import AppKit

public struct LiveSubtitlesView: View {

    @ObservedObject private var viewModel = LiveSubtitlesViewModel.shared
    @State private var isHovering = false

    public init() {}

    public var body: some View {
        ZStack {
            // Apple 原生磨砂质感背景
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    Color.black.opacity(isHovering ? 0.82 : 0.65)
                )
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(spacing: 0) {
                // 顶部 Apple 原生悬浮工具条
                if isHovering || !viewModel.isRunning {
                    topControlBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .padding(.bottom, 8)
                }

                // 核心字幕展示区 (支持 上一句 + 当前句 滚动流式排版)
                if !viewModel.showHistoryDrawer {
                    rollingSubtitleDisplayArea
                        .transition(.opacity)
                } else {
                    // 台词历史回溯抽屉
                    subtitleHistoryDrawer
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .animation(.easeInOut(duration: 0.22), value: isHovering)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.showHistoryDrawer)
        }
        .frame(
            width: 710,
            height: viewModel.showHistoryDrawer ? 240 : (isHovering || !viewModel.isRunning ? 150 : 120)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: viewModel.isClickThrough) { _, newValue in
            LiveSubtitlesOverlayPanel.shared.setClickThrough(newValue)
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

                Text(viewModel.isRunning ? "同传中" : "已暂停")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(viewModel.isRunning ? .green : .secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.06), in: Capsule())

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
                NativeIconButton(systemName: "textformat.size.smaller", helpText: "减小字号") {
                    viewModel.adjustFontSize(delta: -2)
                }

                Text("\(Int(viewModel.fontSize))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 18)

                NativeIconButton(systemName: "textformat.size.larger", helpText: "增大字号") {
                    viewModel.adjustFontSize(delta: 2)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

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
            // 1. 上一句 (半透明灰白，给读者留出阅读缓冲，平滑衔接歌词与台词)
            if let prev = viewModel.previousItem, hasActiveContent {
                VStack(spacing: 2) {
                    if shouldShowTranslation && !prev.translatedText.isEmpty {
                        Text(prev.translatedText)
                            .font(.system(size: viewModel.fontSize * 0.72, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    }
                    if shouldShowOriginal && !prev.originalText.isEmpty && prev.originalText != prev.translatedText {
                        Text(prev.originalText)
                            .font(.system(size: max(viewModel.fontSize * 0.58, 11), weight: .regular))
                            .foregroundColor(.white.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 2. 当前句 (纯白高亮加粗，抗眩光双层阴影)
            if hasActiveContent {
                VStack(spacing: 3) {
                    // 主译文
                    if shouldShowTranslation {
                        let textToShow = !viewModel.currentTranslatedText.isEmpty
                            ? viewModel.currentTranslatedText
                            : viewModel.currentOriginalText

                        Text(textToShow)
                            .font(.system(size: viewModel.fontSize, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.95), radius: 3, x: 0, y: 1.5)
                            .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
                    }

                    // 原文字幕
                    if shouldShowOriginal && !viewModel.currentOriginalText.isEmpty {
                        Text(viewModel.currentOriginalText)
                            .font(.system(size: max(viewModel.fontSize * 0.66, 12), weight: .regular))
                            .foregroundColor(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                    }
                }
                .transition(.opacity)
            } else if viewModel.isRunning {
                // 等待声音输入状态
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
        .animation(.easeInOut(duration: 0.2), value: viewModel.currentTranslatedText)
        .animation(.easeInOut(duration: 0.25), value: viewModel.previousItem)
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
                    .animation(.spring(response: 0.15, dampingFraction: 0.6), value: viewModel.audioLevel)
            }
        }
        .frame(height: 10)
    }

    // MARK: - Helpers

    private var hasActiveContent: Bool {
        !viewModel.currentTranslatedText.isEmpty || !viewModel.currentOriginalText.isEmpty
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
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tintColor)
                .frame(width: 22, height: 22)
                .background(
                    isHovered ? Color.white.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { isHovered = $0 }
    }
}
