import SwiftUI
import AppKit

public struct LiveSubtitlesView: View {

    @ObservedObject private var viewModel = LiveSubtitlesViewModel.shared
    @State private var isHovering = false

    public init() {}

    public var body: some View {
        ZStack {
            // 电影级高透磨砂深色胶囊底色
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    Color.black.opacity(isHovering ? 0.84 : 0.68)
                )
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )

            VStack(spacing: 0) {
                // 顶部精致悬浮工具条 (仅悬停或暂停时显现，平时隐形以保持纯净观影)
                if isHovering || !viewModel.isRunning {
                    topControlBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .padding(.bottom, 6)
                }

                // 核心字幕展示区 (主译文 + 外文原文对照)
                if !viewModel.showHistoryDrawer {
                    subtitleDisplayArea
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
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.showHistoryDrawer)
        }
        .frame(
            width: 700,
            height: viewModel.showHistoryDrawer ? 240 : (isHovering || !viewModel.isRunning ? 145 : 115)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: viewModel.isClickThrough) { _, newValue in
            LiveSubtitlesOverlayPanel.shared.setClickThrough(newValue)
        }
    }

    // MARK: - Top Control Bar

    private var topControlBar: some View {
        HStack(spacing: 10) {
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

            // 源语言切换器
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

            // 双语 / 仅中文 / 仅外文 模式切换
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
            HStack(spacing: 3) {
                Button(action: { viewModel.adjustFontSize(delta: -2) }) {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)

                Text("\(Int(viewModel.fontSize))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 18)

                Button(action: { viewModel.adjustFontSize(delta: 2) }) {
                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(.white.opacity(0.7))

            // 历史台词抽屉
            Button(action: { viewModel.toggleHistoryDrawer() }) {
                Image(systemName: viewModel.showHistoryDrawer ? "clock.fill" : "clock")
                    .font(.system(size: 11))
                    .foregroundColor(viewModel.showHistoryDrawer ? .accentColor : .white.opacity(0.65))
            }
            .buttonStyle(.plain)
            .help(viewModel.showHistoryDrawer ? "关闭台词历史" : "回溯最近台词历史")

            // 开始/暂停
            Button(action: { viewModel.toggleRunning() }) {
                Image(systemName: viewModel.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help(viewModel.isRunning ? "暂停同传" : "开启同传")

            // 清屏
            Button(action: { viewModel.clearSubtitles() }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("清空当前字幕")

            // 关闭
            Button(action: {
                viewModel.stop()
                LiveSubtitlesOverlayPanel.shared.orderOut(nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("关闭实时字幕条")
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Subtitle Display Area

    private var subtitleDisplayArea: some View {
        VStack(spacing: 5) {
            // 1. 中文主译文 (电影级大字号、抗眩光白色 + 柔和黑影)
            if shouldShowTranslation {
                if !viewModel.currentTranslatedText.isEmpty {
                    Text(viewModel.currentTranslatedText)
                        .font(.system(size: viewModel.fontSize, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.95), radius: 3, x: 0, y: 1.5)
                        .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
                } else if viewModel.isRunning && viewModel.currentOriginalText.isEmpty {
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
                } else if !viewModel.isRunning && viewModel.currentOriginalText.isEmpty {
                    Text("点击顶部 ▶ 开启实时字幕同传")
                        .font(.system(size: viewModel.fontSize * 0.72, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                }
            }

            // 2. 外文原文 (优雅半透明灰白)
            if shouldShowOriginal && !viewModel.currentOriginalText.isEmpty {
                Text(viewModel.currentOriginalText)
                    .font(.system(size: max(viewModel.fontSize * 0.68, 12), weight: .regular))
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
            }

            // 3. 错误提示
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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

    private var shouldShowTranslation: Bool {
        viewModel.displayMode == .bilingual || viewModel.displayMode == .chineseOnly
    }

    private var shouldShowOriginal: Bool {
        viewModel.displayMode == .bilingual || viewModel.displayMode == .originalOnly
    }
}
