import SwiftUI
import AppKit

struct ContentView: View {

    @ObservedObject
    var viewModel: TranslationViewModel

    @AppStorage(AppSettings.Key.model)
    private var model = AppSettings.defaultModel

    @AppStorage(AppSettings.Key.translationStyle)
    private var translationStyleRaw = AppSettings.defaultTranslationStyleRaw

    @FocusState
    private var inputFocused: Bool

    @State
    private var resultCopied = false

    @State
    private var copyFeedbackGeneration = 0

    private var originalTextBinding: Binding<String> {
        Binding(
            get: {
                viewModel.originalText
            },
            set: {
                viewModel.updateOriginalTextFromUser($0)
            }
        )
    }

    private var copyFeedbackVisible: Bool {
        viewModel.copied || resultCopied
    }

    private var selectedTranslationStyle: TranslationStyle {
        TranslationStyle(
            rawValue: translationStyleRaw
        ) ?? .standard
    }

    // MARK: - Measured Heights

    private var inputHeight: CGFloat {
        TranslatePanelLayout.inputHeight(
            for: viewModel.originalText
        )
    }

    private var translationHeight: CGFloat {
        TranslatePanelLayout.translationHeight(
            for: viewModel.translatedText
        )
    }

    var body: some View {

        VStack(spacing: 0) {

            header

            Divider()
                .opacity(0.28)

            mainContent

            Divider()
                .opacity(0.28)

            footer
        }
        .background(
            .ultraThinMaterial
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
            .stroke(
                Color.primary.opacity(0.075),
                lineWidth: 1
            )
        }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in
            inputFocused = true
        }
        .onChange(of: viewModel.translatedText) { _, _ in
            if !viewModel.isTranslating {
                resultCopied = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: 8,
                    style: .continuous
                )
                .fill(Color.primary.opacity(0.06))

                Image(systemName: "translate")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Local Translate")
                    .font(.system(size: 13, weight: .semibold))

                Text(model)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            shortcutBadge

            // Pin
            Button {
                viewModel.togglePinned()
            } label: {
                Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(viewModel.isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background {
                        if viewModel.isPinned {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(viewModel.isPinned ? "取消钉住" : "钉住窗口")

            // Close
            Button {
                NSApplication.shared.keyWindow?.orderOut(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var shortcutBadge: some View {
        Text("⌥⇧T")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            originalSection
            translationSection
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 15, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Original

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle("原文", systemImage: "text.alignleft")

                Spacer()

                styleMenu

                if !viewModel.originalText.isEmpty {
                    Button("清空") {
                        viewModel.clearAll()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plain)
                }
            }

            TextField(
                "输入、粘贴，或在其他 App 中选中文字后按 ⌥⇧T…",
                text: originalTextBinding,
                axis: .vertical
            )
            .focused($inputFocused)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineSpacing(3)
            .lineLimit(TranslatePanelLayout.inputMaximumLines)
            .frame(height: inputHeight, alignment: .topLeading)
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.032))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        inputFocused ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.045),
                        lineWidth: 1
                    )
            }
        }
    }

    // MARK: - Translation Style Menu

    private var styleMenu: some View {
        Menu {
            ForEach(TranslationStyle.allCases) { style in
                Button {
                    translationStyleRaw = style.rawValue
                    if !viewModel.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !viewModel.isTranslating {
                        viewModel.translate()
                    }
                } label: {
                    if style == selectedTranslationStyle {
                        Label(style.title, systemImage: "checkmark")
                    } else {
                        Text(style.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedTranslationStyle.title)

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(viewModel.isTranslating)
        .help(selectedTranslationStyle.shortDescription)
    }

    // MARK: - Translation

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("翻译", systemImage: "sparkles")

            translationContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: translationHeight, alignment: .topLeading)
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
        }
    }

    @ViewBuilder
    private var translationContent: some View {
        if let errorMessage = viewModel.errorMessage {
            errorView(errorMessage)
        } else if !viewModel.translatedText.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                CleanTextScrollView(
                    text: viewModel.translatedText,
                    onCopy: {
                        showResultCopyFeedback()
                    }
                )

                if viewModel.isTranslating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)

                        Text("正在生成…")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if viewModel.isTranslating {
            loadingView
        } else {
            Text("翻译结果会显示在这里")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var loadingView: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)

            Text("正在翻译…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// 失败时给出重试入口。
    ///
    /// 划词气泡一直有重试按钮，主面板此前只有一行红字——同一条链路上，
    /// 小窗能自愈而大窗只能让用户重新划词，是反的。Ollama 没启动是最常见的
    /// 失败，用户启动它之后需要的正是这一下。
    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)

                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Button {
                viewModel.translate()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))

                    Text("重试")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(viewModel.isTranslating)
            .accessibilityLabel("重新翻译")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.translate()
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isTranslating {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(
                            systemName: viewModel.translatedText.isEmpty
                            ? "sparkles"
                            : "arrow.clockwise"
                        )
                    }

                    Text(viewModel.translatedText.isEmpty ? "翻译" : "重新翻译")
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(
                viewModel.isTranslating
                || viewModel.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .keyboardShortcut(.return, modifiers: [.command])

            Text("⌘↩")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                viewModel.copyTranslation()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copyFeedbackVisible ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copyFeedbackVisible ? .green : .primary)

                    Text(copyFeedbackVisible ? "已复制" : "复制")
                        .foregroundStyle(copyFeedbackVisible ? .green : .primary)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.translatedText.isEmpty)
            .help("复制完整译文")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Copy Feedback

    private func showResultCopyFeedback() {
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        resultCopied = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard generation == copyFeedbackGeneration else { return }
            resultCopied = false
        }
    }

    // MARK: - Components

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))

            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.7)
        }
        .foregroundStyle(.tertiary)
    }
}

#Preview {
    ContentView(viewModel: TranslationViewModel())
}
