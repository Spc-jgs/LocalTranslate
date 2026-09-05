import SwiftUI

struct TriageView: View {
    @ObservedObject var viewModel: TriageViewModel
    var onClose: () -> Void
    @State private var showsPayload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            content
            Divider().opacity(0.25)
            footer
        }
        .frame(width: 420, height: 350)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .onChange(of: viewModel.context) {
            showsPayload = false
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "stethoscope")
                .foregroundStyle(Color.accentColor)
            Text("词义分诊")
                .font(.system(size: 11, weight: .semibold))
            if let decision = viewModel.decision {
                Text(decision.route == .enough ? "可先用" : "建议核对")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(decision.route == .enough ? .green : .orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭词义分诊")
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let context = viewModel.context {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.selectedText)
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            [context.sourceApp, context.captureQuality.localizedTitle]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    }
                }

                if viewModel.isLoading {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("本地模型正在分诊…")
                    }
                    .foregroundStyle(.secondary)
                } else if let decision = viewModel.decision {
                    Text(decision.explanation)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                    if decision.route == .escalate {
                        Label(decision.uncertaintyReason, systemImage: "exclamationmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                if showsPayload {
                    Text(viewModel.handoffPayload)
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
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
            .disabled(viewModel.context == nil)
            Spacer()
            Button {
                viewModel.copyAndOpenChatGPT()
            } label: {
                Label(
                    viewModel.copiedForHandoff ? "已复制，请粘贴" : "复制并打开 ChatGPT",
                    systemImage: "arrow.up.forward.app"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.context == nil)
            .help("只复制并打开网页，不会自动粘贴或提交")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
