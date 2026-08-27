import SwiftUI
import AppKit

struct ContentView: View {

    @ObservedObject
    var viewModel: TranslationViewModel

    @AppStorage(AppSettings.Key.model)
    private var model =
        AppSettings.defaultModel

    @AppStorage(AppSettings.Key.translationStyle)
    private var translationStyleRaw =
        AppSettings.defaultTranslationStyleRaw

    @FocusState
    private var inputFocused: Bool

    @State
    private var resultCopied = false

    @State
    private var copyFeedbackGeneration = 0

    private var originalTextBinding:
        Binding<String> {

        Binding(
            get: {
                viewModel.originalText
            },
            set: {
                viewModel
                    .updateOriginalTextFromUser(
                        $0
                    )
            }
        )
    }

    private var copyFeedbackVisible: Bool {
        viewModel.copied
        || resultCopied
    }

    private var selectedTranslationStyle: TranslationStyle {
        TranslationStyle(
            rawValue: translationStyleRaw
        ) ?? .standard
    }

    // MARK: - Input Height

    private var inputHeight:
        CGFloat {

        let lines =
            estimatedOriginalLines(
                viewModel.originalText
            )

        let visibleLines =
            min(
                max(
                    lines,
                    3
                ),
                7
            )

        let baseHeight:
            CGFloat = 72

        let extraLines =
            max(
                visibleLines - 3,
                0
            )

        return
            baseHeight
            +
            CGFloat(
                extraLines
            ) * 19
    }

    // MARK: - Translation Height

    private var translationHeight:
        CGFloat {

        if viewModel.isTranslating {
            return 170
        }

        guard
            !viewModel
                .translatedText
                .isEmpty
        else {
            return 82
        }

        let lines =
            estimatedTranslationLines(
                viewModel
                    .translatedText
            )

        let calculated =
            CGFloat(lines)
            * 25

        return min(
            max(
                calculated,
                82
            ),
            220
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
                Color.primary
                    .opacity(0.075),
                lineWidth: 1
            )
        }
        .onChange(
            of:
                viewModel
                    .inputFocusRequest
        ) { _, _ in

            inputFocused = true
        }
        .onChange(
            of:
                viewModel
                    .translatedText
        ) { _, _ in

            // 新翻译出现后，
            // 清除之前通过文本选区触发的
            // “已复制”反馈。
            if !viewModel.isTranslating {
                resultCopied = false
            }
        }
    }

    // MARK: - Header

    private var header:
        some View {

        HStack(spacing: 10) {

            ZStack {

                RoundedRectangle(
                    cornerRadius: 8,
                    style: .continuous
                )
                .fill(
                    Color.primary
                        .opacity(0.06)
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

                Text(
                    "Local Translate"
                )
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

                viewModel
                    .togglePinned()

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
                    ? Color.primary
                    : Color.secondary
                )
                .frame(
                    width: 28,
                    height: 28
                )
                .background {

                    if
                        viewModel
                            .isPinned {

                        RoundedRectangle(
                            cornerRadius: 7,
                            style: .continuous
                        )
                        .fill(
                            Color.primary
                                .opacity(0.08)
                        )
                    }
                }
                .contentShape(
                    Rectangle()
                )
            }
            .buttonStyle(.plain)
            .help(
                viewModel.isPinned
                ? "取消钉住"
                : "钉住窗口"
            )

            // MARK: Close

            Button {

                NSApplication
                    .shared
                    .keyWindow?
                    .orderOut(nil)

            } label: {

                Image(
                    systemName:
                        "xmark"
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
                .contentShape(
                    Rectangle()
                )
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

    private var shortcutBadge:
        some View {

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
                    Color.primary
                        .opacity(0.05)
                )
            }
    }

    // MARK: - Main Content

    private var mainContent:
        some View {

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
        .frame(
            maxWidth:
                .infinity,
            alignment:
                .topLeading
        )
    }

    // MARK: - Original

    private var originalSection:
        some View {

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

                styleMenu

                if
                    !viewModel
                        .originalText
                        .isEmpty {

                    Button(
                        "清空"
                    ) {

                        viewModel
                            .clearAll()
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
                    .buttonStyle(
                        .plain
                    )
                }
            }

            TextField(
                "输入、粘贴，或在其他 App 中选中文字后按 ⌥⇧T…",
                text:
                    originalTextBinding,
                axis:
                    .vertical
            )
            .focused(
                $inputFocused
            )
            .textFieldStyle(
                .plain
            )
            .font(
                .system(
                    size: 13
                )
            )
            .lineSpacing(3)
            .lineLimit(7)
            .frame(
                height:
                    inputHeight,
                alignment:
                    .topLeading
            )
            .padding(
                EdgeInsets(
                    top: 10,
                    leading: 10,
                    bottom: 10,
                    trailing: 10
                )
            )
            .background {

                RoundedRectangle(
                    cornerRadius: 11,
                    style: .continuous
                )
                .fill(
                    Color.primary
                        .opacity(0.032)
                )
            }
            .overlay {

                RoundedRectangle(
                    cornerRadius: 11,
                    style: .continuous
                )
                .stroke(
                    inputFocused
                    ? Color.primary
                        .opacity(0.13)
                    : Color.primary
                        .opacity(0.045),
                    lineWidth: 1
                )
            }
        }
    }

    // MARK: - Translation Style Menu

    private var styleMenu: some View {

        Menu {

            ForEach(
                TranslationStyle.allCases
            ) { style in

                Button {

                    translationStyleRaw =
                        style.rawValue

                } label: {

                    if style == selectedTranslationStyle {

                        Label(
                            style.title,
                            systemImage: "checkmark"
                        )

                    } else {

                        Text(style.title)
                    }
                }
            }

        } label: {

            HStack(spacing: 4) {

                Text(
                    selectedTranslationStyle.title
                )

                Image(
                    systemName: "chevron.down"
                )
                .font(
                    .system(
                        size: 7,
                        weight: .semibold
                    )
                )
            }
            .font(
                .system(
                    size: 10,
                    weight: .medium
                )
            )
            .foregroundStyle(.secondary)
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
                    Color.primary.opacity(0.045)
                )
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(
            viewModel.isTranslating
        )
        .help(
            selectedTranslationStyle.shortDescription
        )
    }

    // MARK: - Translation

    private var translationSection:
        some View {

        VStack(
            alignment: .leading,
            spacing: 8
        ) {

            sectionTitle(
                "翻译",
                systemImage:
                    "sparkles"
            )

            translationContent
                .frame(
                    maxWidth:
                        .infinity,
                    alignment:
                        .topLeading
                )
                .frame(
                    height:
                        translationHeight,
                    alignment:
                        .topLeading
                )
                .padding(14)
                .background {

                    RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                    .fill(
                        Color.primary
                            .opacity(0.045)
                    )
                }
        }
    }

    @ViewBuilder
    private var translationContent:
        some View {

        if
            let errorMessage =
                viewModel
                    .errorMessage {

            errorView(
                errorMessage
            )

        } else if
            !viewModel
                .translatedText
                .isEmpty {

            VStack(
                alignment: .leading,
                spacing: 8
            ) {

                CleanTextScrollView(
                    text:
                        viewModel
                            .translatedText,
                    onCopy: {
                        showResultCopyFeedback()
                    }
                )

                if
                    viewModel
                        .isTranslating {

                    HStack(
                        spacing: 6
                    ) {

                        ProgressView()
                            .controlSize(
                                .mini
                            )

                        Text(
                            "正在生成…"
                        )
                        .font(
                            .system(
                                size: 10
                            )
                        )
                        .foregroundStyle(
                            .tertiary
                        )
                    }
                }
            }
            .frame(
                maxWidth:
                    .infinity,
                maxHeight:
                    .infinity,
                alignment:
                    .topLeading
            )

        } else if
            viewModel
                .isTranslating {

            loadingView

        } else {

            Text(
                "翻译结果会显示在这里"
            )
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
                maxHeight:
                    .infinity,
                alignment:
                    .center
            )
        }
    }

    private var loadingView:
        some View {

        HStack(
            spacing: 9
        ) {

            ProgressView()
                .controlSize(
                    .small
                )

            Text(
                "正在翻译…"
            )
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
            maxWidth:
                .infinity,
            maxHeight:
                .infinity,
            alignment:
                .leading
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
            .foregroundStyle(
                .red
            )

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
        .frame(
            maxWidth:
                .infinity,
            maxHeight:
                .infinity,
            alignment:
                .topLeading
        )
    }

    // MARK: - Footer

    private var footer:
        some View {

        HStack(spacing: 10) {

            Button {

                viewModel
                    .translate()

            } label: {

                HStack(
                    spacing: 6
                ) {

                    if
                        viewModel
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
            .buttonStyle(
                .bordered
            )
            .controlSize(
                .small
            )
            .disabled(
                viewModel
                    .isTranslating
                ||
                viewModel
                    .originalText
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
                    .isEmpty
            )
            .keyboardShortcut(
                .return,
                modifiers:
                    [.command]
            )

            Text("⌘↩")
                .font(
                    .system(
                        size: 10,
                        design:
                            .rounded
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

                HStack(
                    spacing: 6
                ) {

                    Image(
                        systemName:
                            copyFeedbackVisible
                            ? "checkmark"
                            : "doc.on.doc"
                    )

                    Text(
                        copyFeedbackVisible
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
            .buttonStyle(
                .bordered
            )
            .controlSize(
                .small
            )
            .disabled(
                viewModel
                    .translatedText
                    .isEmpty
            )
            .help(
                "复制完整译文"
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

    // MARK: - Copy Feedback

    private func
    showResultCopyFeedback() {

        copyFeedbackGeneration += 1

        let generation =
            copyFeedbackGeneration

        resultCopied = true

        DispatchQueue.main
            .asyncAfter(
                deadline:
                    .now() + 1.2
            ) {

                guard
                    generation
                    ==
                    copyFeedbackGeneration
                else {
                    return
                }

                resultCopied = false
            }
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

    // MARK: - Line Estimate

    private func
    estimatedOriginalLines(
        _ text: String
    ) -> Int {

        guard !text.isEmpty else {
            return 1
        }

        return text
            .components(
                separatedBy:
                    .newlines
            )
            .reduce(0) {
                result,
                line in

                let count =
                    max(
                        line.count,
                        1
                    )

                let lines =
                    Int(
                        ceil(
                            Double(count)
                            / 55.0
                        )
                    )

                return
                    result
                    + max(
                        lines,
                        1
                    )
            }
    }

    private func
    estimatedTranslationLines(
        _ text: String
    ) -> Int {

        guard !text.isEmpty else {
            return 2
        }

        return text
            .components(
                separatedBy:
                    .newlines
            )
            .reduce(0) {
                result,
                line in

                let count =
                    max(
                        line.count,
                        1
                    )

                let lines =
                    Int(
                        ceil(
                            Double(count)
                            / 29.0
                        )
                    )

                return
                    result
                    + max(
                        lines,
                        1
                    )
            }
    }
}

#Preview {

    ContentView(
        viewModel:
            TranslationViewModel()
    )
}
