import SwiftUI
import AppKit

struct ContentView: View {

    @ObservedObject
    var viewModel: TranslationViewModel

    @AppStorage(AppSettings.Key.model)
    private var model =
        AppSettings.defaultModel

    @FocusState
    private var inputFocused: Bool

    private var originalTextBinding: Binding<String> {

        Binding(
            get: {
                viewModel.originalText
            },
            set: {
                viewModel.updateOriginalTextFromUser(
                    $0
                )
            }
        )
    }

    var body: some View {

        VStack(spacing: 0) {

            header

            Divider()
                .opacity(0.35)

            content

            Divider()
                .opacity(0.35)

            footer
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .background(.ultraThinMaterial)
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
                .primary.opacity(0.08),
                lineWidth: 1
            )
        }
        .onChange(
            of: viewModel.inputFocusRequest
        ) { _, _ in

            inputFocused = true
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
                .fill(
                    .primary.opacity(0.065)
                )

                Image(
                    systemName:
                        "character.book.closed"
                )
                .font(
                    .system(
                        size: 13,
                        weight: .semibold
                    )
                )
                .foregroundStyle(
                    .secondary
                )
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
                    .foregroundStyle(
                        .tertiary
                    )
                    .lineLimit(1)
            }

            Spacer()

            shortcutBadge

            // MARK: Pin

            Button {
                viewModel.togglePinned()
            } label: {

                Image(
                    systemName:
                        viewModel.isPinned
                        ? "pin.fill"
                        : "pin"
                )
                .font(
                    .system(
                        size: 11,
                        weight: .semibold
                    )
                )
                .foregroundStyle(
                    viewModel.isPinned
                    ? .primary
                    : .secondary
                )
                .frame(
                    width: 28,
                    height: 28
                )
                .background {

                    if viewModel.isPinned {

                        RoundedRectangle(
                            cornerRadius: 7,
                            style: .continuous
                        )
                        .fill(
                            .primary.opacity(0.08)
                        )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                viewModel.isPinned
                ? "取消钉住"
                : "钉住窗口"
            )

            // MARK: Close

            Button {

                NSApplication.shared
                    .keyWindow?
                    .orderOut(nil)

            } label: {

                Image(
                    systemName: "xmark"
                )
                .font(
                    .system(
                        size: 10,
                        weight: .semibold
                    )
                )
                .foregroundStyle(
                    .secondary
                )
                .frame(
                    width: 28,
                    height: 28
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(
            .horizontal,
            16
        )
        .padding(
            .vertical,
            11
        )
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
            .foregroundStyle(
                .tertiary
            )
            .padding(
                .horizontal,
                7
            )
            .padding(
                .vertical,
                4
            )
            .background {

                RoundedRectangle(
                    cornerRadius: 6,
                    style: .continuous
                )
                .fill(
                    .primary.opacity(0.05)
                )
            }
    }

    // MARK: - Content

    private var content: some View {

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
                    top: 15,
                    leading: 18,
                    bottom: 17,
                    trailing: 18
                )
            )
        }
    }

    // MARK: - Original

    private var originalSection: some View {

        VStack(
            alignment: .leading,
            spacing: 8
        ) {

            HStack {

                sectionTitle(
                    "原文",
                    systemImage:
                        "text.alignleft"
                )

                Spacer()

                if !viewModel
                    .originalText
                    .isEmpty {

                    Button("清空") {

                        viewModel.clearAll()
                    }
                    .font(
                        .system(
                            size: 10,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(
                        .tertiary
                    )
                    .buttonStyle(.plain)
                }
            }

            ZStack(
                alignment: .topLeading
            ) {

                if viewModel
                    .originalText
                    .isEmpty {

                    Text(
                        "输入、粘贴，或在其他 App 中选中文字后按 ⌥⇧T…"
                    )
                    .font(
                        .system(
                            size: 13
                        )
                    )
                    .foregroundStyle(
                        .tertiary
                    )
                    .padding(
                        EdgeInsets(
                            top: 9,
                            leading: 7,
                            bottom: 0,
                            trailing: 0
                        )
                    )
                    .allowsHitTesting(false)
                }

                TextEditor(
                    text:
                        originalTextBinding
                )
                .focused(
                    $inputFocused
                )
                .font(
                    .system(
                        size: 13
                    )
                )
                .lineSpacing(3)
                .scrollContentBackground(
                    .hidden
                )
                .frame(
                    minHeight: 72,
                    maxHeight: 145
                )
            }
            .padding(5)
            .background {

                RoundedRectangle(
                    cornerRadius: 11,
                    style: .continuous
                )
                .fill(
                    .primary.opacity(0.032)
                )
            }
            .overlay {

                RoundedRectangle(
                    cornerRadius: 11,
                    style: .continuous
                )
                .stroke(
                    inputFocused
                        ? Color.primary.opacity(0.12)
                        : Color.primary.opacity(0.045),
                    lineWidth: 1
                )
            }
        }
    }

    // MARK: - Translation

    private var translationSection: some View {

        VStack(
            alignment: .leading,
            spacing: 8
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

                    errorView(
                        errorMessage
                    )

                } else if viewModel
                    .translatedText
                    .isEmpty {

                    Text("翻译结果会显示在这里")
                        .font(
                            .system(
                                size: 13
                            )
                        )
                        .foregroundStyle(
                            .tertiary
                        )
                        .frame(
                            maxWidth:
                                .infinity,
                            minHeight: 44,
                            alignment:
                                .center
                        )

                } else {

                    Text(
                        viewModel
                            .translatedText
                    )
                    .font(
                        .system(
                            size: 15,
                            weight: .medium
                        )
                    )
                    .lineSpacing(5)
                    .textSelection(
                        .enabled
                    )
                    .frame(
                        maxWidth:
                            .infinity,
                        alignment:
                            .topLeading
                    )
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 44,
                alignment: .topLeading
            )
            .padding(14)
            .background {

                RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
                .fill(
                    .primary.opacity(0.048)
                )
            }
        }
    }

    private var loadingView: some View {

        HStack(spacing: 9) {

            ProgressView()
                .controlSize(.small)

            Text("正在翻译…")
                .font(
                    .system(
                        size: 13,
                        weight: .medium
                    )
                )
                .foregroundStyle(
                    .secondary
                )
        }
        .frame(
            minHeight: 44,
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
                systemName:
                    "exclamationmark.circle.fill"
            )
            .foregroundStyle(.red)

            Text(message)
                .font(
                    .system(
                        size: 12
                    )
                )
                .foregroundStyle(
                    .secondary
                )
        }
    }

    // MARK: - Footer

    private var footer: some View {

        HStack(spacing: 10) {

            Button {

                viewModel.translate()

            } label: {

                HStack(spacing: 6) {

                    if viewModel
                        .isTranslating {

                        ProgressView()
                            .controlSize(
                                .mini
                            )

                    } else {

                        Image(
                            systemName:
                                viewModel
                                    .translatedText
                                    .isEmpty
                                ? "sparkles"
                                : "arrow.clockwise"
                        )
                    }

                    Text(
                        viewModel
                            .translatedText
                            .isEmpty
                        ? "翻译"
                        : "重新翻译"
                    )
                }
                .font(
                    .system(
                        size: 12,
                        weight: .semibold
                    )
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(
                viewModel.isTranslating ||
                viewModel.originalText
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
                    .isEmpty
            )
            .keyboardShortcut(
                .return,
                modifiers: [.command]
            )

            Text("⌘↩")
                .font(
                    .system(
                        size: 10,
                        design: .rounded
                    )
                )
                .foregroundStyle(
                    .tertiary
                )

            Spacer()

            Button {

                viewModel
                    .copyTranslation()

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
                        weight: .medium
                    )
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(
                viewModel
                    .translatedText
                    .isEmpty
            )
        }
        .padding(
            .horizontal,
            16
        )
        .padding(
            .vertical,
            10
        )
    }

    // MARK: - Components

    private func sectionTitle(
        _ title: String,
        systemImage: String
    ) -> some View {

        HStack(spacing: 5) {

            Image(
                systemName:
                    systemImage
            )
            .font(
                .system(
                    size: 9,
                    weight: .semibold
                )
            )

            Text(
                title.uppercased()
            )
            .font(
                .system(
                    size: 9,
                    weight: .semibold
                )
            )
            .tracking(0.7)
        }
        .foregroundStyle(
            .tertiary
        )
    }
}

#Preview {

    ContentView(
        viewModel:
            TranslationViewModel()
    )
}
