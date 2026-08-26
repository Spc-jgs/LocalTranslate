import SwiftUI
import AppKit

struct ContentView: View {

    @ObservedObject var viewModel: TranslationViewModel

    @AppStorage(AppSettings.Key.model)
    private var model = AppSettings.defaultModel

    var body: some View {
        VStack(spacing: 0) {

            header

            Divider()
                .opacity(0.35)

            content

            if !viewModel.originalText.isEmpty {
                Divider()
                    .opacity(0.35)

                footer
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {

            ZStack {
                RoundedRectangle(
                    cornerRadius: 8,
                    style: .continuous
                )
                .fill(.primary.opacity(0.07))

                Image(
                    systemName: "character.book.closed"
                )
                .font(
                    .system(
                        size: 13,
                        weight: .semibold
                    )
                )
                .foregroundStyle(.secondary)
            }
            .frame(
                width: 28,
                height: 28
            )

            VStack(
                alignment: .leading,
                spacing: 1
            ) {
                Text("Local Translate")
                    .font(
                        .system(
                            size: 13,
                            weight: .semibold
                        )
                    )

                Text(model)
                    .font(
                        .system(
                            size: 10
                        )
                    )
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            shortcutBadge

            Button {
                NSApplication.shared
                    .keyWindow?
                    .orderOut(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(
                        .system(
                            size: 10,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(.secondary)
                    .frame(
                        width: 26,
                        height: 26
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var shortcutBadge: some View {
        Text("⌥⇧T")
            .font(
                .system(
                    size: 10,
                    weight: .medium,
                    design: .rounded
                )
            )
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(
                    cornerRadius: 6,
                    style: .continuous
                )
                .fill(.primary.opacity(0.05))
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {

        if viewModel.originalText.isEmpty {

            emptyState

        } else {

            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: 18
                ) {

                    originalSection

                    translationSection
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
            .scrollIndicators(.automatic)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {

            ZStack {
                Circle()
                    .fill(
                        .primary.opacity(0.05)
                    )

                Image(
                    systemName: "text.cursor"
                )
                .font(
                    .system(
                        size: 20,
                        weight: .medium
                    )
                )
                .foregroundStyle(.secondary)
            }
            .frame(
                width: 48,
                height: 48
            )

            VStack(spacing: 5) {

                Text("选择一段文字")
                    .font(
                        .system(
                            size: 14,
                            weight: .semibold
                        )
                    )

                Text("在任意 App 中选中文字，然后按 ⌥⇧T")
                    .font(
                        .system(
                            size: 12
                        )
                    )
                    .foregroundStyle(.secondary)
            }

            if let errorMessage =
                viewModel.errorMessage {

                Text(errorMessage)
                    .font(
                        .system(
                            size: 11
                        )
                    )
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .padding(.vertical, 34)
    }

    // MARK: - Original

    private var originalSection: some View {
        VStack(
            alignment: .leading,
            spacing: 7
        ) {

            sectionTitle(
                "原文",
                systemImage: "text.alignleft"
            )

            Text(viewModel.originalText)
                .font(
                    .system(
                        size: 13
                    )
                )
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
        }
    }

    // MARK: - Translation

    private var translationSection: some View {
        VStack(
            alignment: .leading,
            spacing: 9
        ) {

            sectionTitle(
                "翻译",
                systemImage: "sparkles"
            )

            Group {

                if viewModel.isTranslating {

                    loadingView

                } else if let errorMessage =
                            viewModel.errorMessage {

                    errorView(errorMessage)

                } else if !viewModel.translatedText.isEmpty {

                    Text(
                        viewModel.translatedText
                    )
                    .font(
                        .system(
                            size: 15,
                            weight: .medium
                        )
                    )
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )

                } else {

                    Text("等待翻译")
                        .font(
                            .system(
                                size: 13
                            )
                        )
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 42,
                alignment: .topLeading
            )
            .padding(14)
            .background {
                RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
                .fill(
                    .primary.opacity(0.045)
                )
            }
        }
    }

    private var loadingView: some View {
        HStack(spacing: 9) {

            ProgressView()
                .controlSize(.small)

            Text("正在翻译")
                .font(
                    .system(
                        size: 13,
                        weight: .medium
                    )
                )
                .foregroundStyle(.secondary)
        }
        .frame(
            minHeight: 42,
            alignment: .leading
        )
    }

    private func errorView(
        _ message: String
    ) -> some View {

        HStack(
            alignment: .top,
            spacing: 8
        ) {

            Image(
                systemName: "exclamationmark.circle.fill"
            )
            .foregroundStyle(.red)

            Text(message)
                .font(
                    .system(
                        size: 12
                    )
                )
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {

            Button {
                viewModel.translate()
            } label: {
                Label(
                    "重新翻译",
                    systemImage: "arrow.clockwise"
                )
                .font(
                    .system(
                        size: 12,
                        weight: .medium
                    )
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(
                viewModel.isTranslating
            )

            Spacer()

            Button {
                viewModel.copyTranslation()
            } label: {

                HStack(spacing: 6) {

                    Image(
                        systemName:
                            viewModel.copied
                            ? "checkmark"
                            : "doc.on.doc"
                    )

                    Text(
                        viewModel.copied
                        ? "已复制"
                        : "复制"
                    )
                }
                .font(
                    .system(
                        size: 12,
                        weight: .semibold
                    )
                )
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(
                        cornerRadius: 7,
                        style: .continuous
                    )
                    .fill(
                        .primary.opacity(0.08)
                    )
                }
            }
            .buttonStyle(.plain)
            .disabled(
                viewModel.translatedText.isEmpty
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Components

    private func sectionTitle(
        _ title: String,
        systemImage: String
    ) -> some View {

        HStack(spacing: 5) {

            Image(systemName: systemImage)
                .font(
                    .system(
                        size: 9,
                        weight: .semibold
                    )
                )

            Text(title.uppercased())
                .font(
                    .system(
                        size: 9,
                        weight: .semibold
                    )
                )
                .tracking(0.7)
        }
        .foregroundStyle(.tertiary)
    }
}

#Preview {
    ContentView(
        viewModel:
            TranslationViewModel()
    )
}
