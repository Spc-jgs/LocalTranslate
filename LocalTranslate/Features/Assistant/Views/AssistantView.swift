import SwiftUI

struct AssistantView: View {
    @ObservedObject var viewModel: AssistantViewModel
    @ObservedObject private var runtime = AssistantRuntime.shared
    var onClose: () -> Void
    @FocusState private var questionFocused: Bool
    @State private var showsPayload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            content
            Divider().opacity(0.25)
            footer
        }
        .frame(width: 460, height: 380)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .onAppear { questionFocused = true }
        .onChange(of: viewModel.invocationID) { _, _ in
            questionFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "terminal")
                .foregroundStyle(Color.accentColor)
            Text("本机助手")
                .font(.system(size: 11, weight: .semibold))
            if runtime.phase == .starting, !viewModel.isLoading {
                Text("启动中")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if let answer = viewModel.answer {
                Text(kindTitle(answer.kind))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                Text(answer.sourceCaption)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if viewModel.answer != nil || runtime.isRunning {
                Button("新话题") {
                    viewModel.startNewTopic()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .help("丢掉当前 agy 会话，下一问重新开始")
                .disabled(viewModel.isLoading)
            }
            Button {
                viewModel.togglePinned()
            } label: {
                Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(
                        viewModel.isPinned
                            ? Color.accentColor : Color.secondary
                    )
                    .frame(width: 22, height: 22)
                    .background {
                        if viewModel.isPinned {
                            RoundedRectangle(
                                cornerRadius: 5,
                                style: .continuous
                            )
                            .fill(Color.accentColor.opacity(0.12))
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(viewModel.isPinned ? "取消钉住" : "钉住窗口")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭本机助手")
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                inputSection

                if viewModel.isLoading {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(viewModel.loadingCaption)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                } else if let answer = viewModel.answer {
                    answerSection(answer)
                }

                if let notice = viewModel.routeNotice, viewModel.answer != nil {
                    Text(notice)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                if showsPayload {
                    Text(viewModel.handoffPayload)
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(
                            Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(
                "想问什么？例如：把最近三个提交合并成一个",
                text: $viewModel.question,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(2...10)
            .focused($questionFocused)
            .onSubmit { viewModel.submit() }
            .padding(8)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 7)
            )
            Text("⌘↩ 提交 · 有选区会填进框里，改过就只送你看见的字")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func answerSection(_ answer: AssistantAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if answer.isCommand {
                Text(answer.primary)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
            } else {
                Text(answer.primary)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }

            // 破坏性由代码判定并且永远显示在命令**下方紧邻处**，不折叠、不靠
            // 用户展开——一条 `git reset --hard` 和 `--soft` 只差一个词。
            if let hazard = answer.hazard {
                Label {
                    Text(
                        hazard.irreversible
                            ? "\(hazard.reason)执行前请确认，这一步没有本地退路。"
                            : hazard.reason
                    )
                } icon: {
                    Image(
                        systemName: hazard.irreversible
                            ? "exclamationmark.triangle.fill"
                            : "exclamationmark.circle"
                    )
                }
                .font(.system(size: 10))
                .foregroundStyle(hazard.irreversible ? .red : .orange)
            }

            if !answer.note.isEmpty {
                Text(answer.note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.copyAnswer()
                } label: {
                    Label(
                        viewModel.copiedAnswer ? "已复制" : "复制",
                        systemImage: "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("只复制到剪贴板，不会自动执行或粘贴到终端")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("⌥⇧E")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.tertiary)
            Button(showsPayload ? "收起交接内容" : "查看交接内容") {
                showsPayload.toggle()
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canSubmit && viewModel.answer == nil)
            Spacer()
            Button("提交") { viewModel.submit() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!viewModel.canSubmit)
            Button {
                viewModel.copyAndOpenHandoffTarget()
            } label: {
                Label(
                    viewModel.copiedForHandoff
                        ? "已复制，请粘贴"
                        : "交给 \(viewModel.handoffTarget.displayName)",
                    systemImage: "arrow.up.forward.app"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.inputText.isEmpty)
            .help("只复制并打开网页，不会自动粘贴或提交")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func kindTitle(_ kind: AssistantAnswerKind) -> String {
        switch kind {
        case .command: return "命令"
        case .diagnosis: return "排错"
        case .explanation: return "解释"
        }
    }
}
