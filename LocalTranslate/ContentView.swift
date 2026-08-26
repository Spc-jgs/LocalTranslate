import SwiftUI
import AppKit

struct ContentView: View {

    @ObservedObject var viewModel: TranslationViewModel

    var body: some View {

        VStack(spacing: 0) {

            // MARK: - Header

            HStack(spacing: 10) {

                Image(systemName: "character.book.closed")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Local Translate")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Button {
                    NSApplication.shared.keyWindow?.orderOut(nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)

            Divider()
                .opacity(0.5)

            // MARK: - Content

            ScrollView {

                VStack(alignment: .leading, spacing: 24) {

                    // 原文
                    VStack(alignment: .leading, spacing: 9) {

                        Text("ORIGINAL")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $viewModel.originalText)
                            .font(.system(size: 14))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 65)
                    }

                    // 翻译
                    VStack(alignment: .leading, spacing: 9) {

                        Text("TRANSLATION")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)

                        Group {

                            if viewModel.isTranslating {

                                HStack(spacing: 10) {

                                    ProgressView()
                                        .controlSize(.small)

                                    Text("正在翻译…")
                                        .foregroundStyle(.secondary)
                                }

                            } else if let errorMessage = viewModel.errorMessage {

                                Text(errorMessage)
                                    .foregroundStyle(.red)

                            } else if viewModel.translatedText.isEmpty {

                                Text("等待翻译")
                                    .foregroundStyle(.tertiary)

                            } else {

                                Text(viewModel.translatedText)
                                    .textSelection(.enabled)
                            }
                        }
                        .font(.system(size: 16, weight: .medium))
                        .lineSpacing(6)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 55,
                            alignment: .topLeading
                        )
                    }
                    .padding(16)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.primary.opacity(0.045))
                    }
                }
                .padding(20)
            }

            Divider()
                .opacity(0.5)

            // MARK: - Footer

            HStack {

                Button {
                    viewModel.translate()
                } label: {
                    Label(
                        viewModel.translatedText.isEmpty
                            ? "翻译"
                            : "重新翻译",
                        systemImage: viewModel.translatedText.isEmpty
                            ? "sparkles"
                            : "arrow.clockwise"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(
                    viewModel.isTranslating ||
                    viewModel.originalText.isEmpty
                )

                Spacer()

                Button {
                    viewModel.copyTranslation()
                } label: {

                    Label(
                        viewModel.copied ? "已复制" : "复制",
                        systemImage: viewModel.copied
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.primary.opacity(0.08))
                }
                .disabled(viewModel.translatedText.isEmpty)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
        }
        .frame(
            width: 500,
            height: 355
        )
        .background(.ultraThinMaterial)
    }
}

#Preview {
    ContentView(
        viewModel: TranslationViewModel()
    )
}
