import SwiftUI

public struct LiveSubtitlesView: View {

    @ObservedObject private var viewModel = LiveSubtitlesViewModel.shared
    @State private var isHovering = false

    public init() {}

    public var body: some View {
        ZStack {
            // 电影磨砂半透明胶囊背景
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    Color.black.opacity(isHovering ? 0.88 : 0.78)
                )
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(spacing: 8) {
                // 顶部控制栏 (悬停时显现，平时隐藏以获得纯净观影沉浸感)
                topControlBar
                    .opacity(isHovering || !viewModel.isRunning ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.2), value: isHovering)

                // 中间核心字幕展示区
                subtitleDisplayArea

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 720, height: 160)
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: viewModel.isClickThrough) { _, newValue in
            LiveSubtitlesOverlayPanel.shared.setClickThrough(newValue)
        }
    }

    // MARK: - Top Control Bar

    private var topControlBar: some View {
        HStack(spacing: 12) {
            // 状态指示灯与动态音浪
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)

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
            .frame(width: 130)
            .controlSize(.small)

            Spacer()

            // 字号微调
            HStack(spacing: 4) {
                Button(action: {
                    if viewModel.fontSize > 16 {
                        viewModel.fontSize -= 2
                    }
                }) {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)

                Text("\(Int(viewModel.fontSize))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 20)

                Button(action: {
                    if viewModel.fontSize < 36 {
                        viewModel.fontSize += 2
                    }
                }) {
                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(.white.opacity(0.7))

            // 原文开关
            Button(action: {
                viewModel.showOriginalText.toggle()
            }) {
                Image(systemName: viewModel.showOriginalText ? "character.bubble.fill" : "character.bubble")
                    .font(.system(size: 12))
                    .foregroundColor(viewModel.showOriginalText ? .accentColor : .white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(viewModel.showOriginalText ? "隐藏外文原文" : "显示外文原文")

            // 开始/暂停按钮
            Button(action: {
                viewModel.toggleRunning()
            }) {
                Image(systemName: viewModel.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help(viewModel.isRunning ? "暂停同传" : "开启同传")

            // 清屏
            Button(action: {
                viewModel.clearSubtitles()
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("清空当前字幕")

            // 关闭浮窗
            Button(action: {
                viewModel.stop()
                LiveSubtitlesOverlayPanel.shared.orderOut(nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("关闭实时字幕条")
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Subtitle Display Area

    private var subtitleDisplayArea: some View {
        VStack(spacing: 6) {
            // 中文主译文 (电影级大字号、高对比度白色 + 柔和黑影，防止背景反光)
            if !viewModel.currentTranslatedText.isEmpty {
                Text(viewModel.currentTranslatedText)
                    .font(.system(size: viewModel.fontSize, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1.5)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if viewModel.isRunning {
                VStack(spacing: 4) {
                    Text("正在聆听电影/视频声音...")
                        .font(.system(size: viewModel.fontSize * 0.75, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    if viewModel.audioLevel < 0.02 {
                        Text("（💡 需开启电脑声音或佩戴耳机播放，完全静音时无法提取声波）")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.38))
                    }
                }
                .multilineTextAlignment(.center)
            } else {
                Text("点击顶部 ▶ 开启实时字幕同传")
                    .font(.system(size: viewModel.fontSize * 0.75, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
            }

            // 外文原文 (浅灰小字)
            if viewModel.showOriginalText && !viewModel.currentOriginalText.isEmpty {
                Text(viewModel.currentOriginalText)
                    .font(.system(size: max(viewModel.fontSize * 0.65, 12), weight: .regular))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
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
}
