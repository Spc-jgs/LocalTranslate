import SwiftUI
import AppKit

struct MiniHUDView: View {

    @ObservedObject var viewModel: MiniHUDViewModel
    var onExpand: (() -> Void)?
    var onClose: (() -> Void)?

    @AppStorage(AppSettings.Key.model)
    private var model = AppSettings.defaultModel

    @AppStorage(AppSettings.Key.translationStyle)
    private var translationStyleRaw = AppSettings.defaultTranslationStyleRaw

    private var selectedTranslationStyle: TranslationStyle {
        TranslationStyle(rawValue: translationStyleRaw) ?? .standard
    }

    private var translationHeight: CGFloat {
        MiniHUDLayout.translationHeight(
            for: viewModel.translatedText
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            content
            Divider().opacity(0.25)
            footer
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .frame(width: MiniHUDLayout.panelWidth)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text("划词翻译")
                .font(.system(size: 11, weight: .semibold))

            Text("·")
                .foregroundStyle(.tertiary)

            Text(selectedTranslationStyle.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }

            Spacer()

            // Expand to Main Panel
            Button {
                onExpand?()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("展开至主翻译窗口 (⌥↩)")

            // Pin
            Button {
                viewModel.togglePinned()
            } label: {
                Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(viewModel.isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background {
                        if viewModel.isPinned {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(viewModel.isPinned ? "取消钉住" : "钉住气泡")

            // Close
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Original snippet (compact)
            if !viewModel.originalText.isEmpty {
                Text(viewModel.originalText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(MiniHUDLayout.originalMaximumLines)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    }
            }

            // Translation Body
            if let errorMessage = viewModel.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 11))

                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if !viewModel.translatedText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    CleanTextScrollView(
                        text: viewModel.translatedText,
                        onCopy: {
                            viewModel.copyTranslation()
                        }
                    )
                    .frame(height: translationHeight)

                    if viewModel.isTranslating {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("生成中…")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 2)
                    }
                }
            } else if viewModel.isTranslating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在翻译…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                Text("等待输入…")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("⌥⇧D")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }

            Text(model)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            // 气泡太窄，只放一个喇叭；原文在这里只显示两行，本来就是配角，
            // 所以读的是译文——它的语言也无需判断。
            SpeakButton(
                text: viewModel.translatedText,
                languageCode: AppSettings.targetLanguage.speechLanguageCode,
                id: "hud.translation"
            )

            // Retry Button
            Button {
                viewModel.loadAndTranslate(viewModel.originalText)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isTranslating || viewModel.originalText.isEmpty)
            .help("重新翻译")

            // Copy Button
            Button {
                viewModel.copyTranslation()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: viewModel.copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(viewModel.copied ? .green : .secondary)

                    Text(viewModel.copied ? "已复制" : "复制")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(viewModel.copied ? .green : .secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.translatedText.isEmpty && viewModel.originalText.isEmpty)
            .help("复制结果 (⌘C)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
