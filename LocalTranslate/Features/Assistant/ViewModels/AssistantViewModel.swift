import AppKit
import Combine
import Foundation

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published private(set) var mode: AssistantMode = .askQuestion
    @Published private(set) var context: SelectionContext?
    @Published private(set) var answer: AssistantAnswer?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var copiedAnswer = false
    @Published private(set) var copiedForHandoff = false
    /// 无选区时用户敲进去的问题；有选区时是选中的原文，只读展示。
    @Published var question = ""

    private let service = AssistantService()
    private var task: Task<Void, Never>?
    private var generation = UUID()

    var inputText: String {
        mode == .analyzeSelection ? (context?.selectedText ?? "") : question
    }

    var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoading
    }

    var handoffPayload: String {
        AssistantHandoffPayload.make(
            mode: mode,
            input: inputText,
            context: context,
            answer: answer
        )
    }

    /// 有选区：直接开算，不让用户再按一次回车。
    func startWithSelection(_ context: SelectionContext) {
        reset()
        mode = .analyzeSelection
        self.context = AssistantInputBounds.apply(to: context)
        submit()
    }

    /// 无选区：只把面板打开，等用户输入。
    func startWithQuestion() {
        reset()
        mode = .askQuestion
        context = nil
    }

    func submit() {
        let input = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        run(model: AppSettings.model, keepAlive: AppSettings.keepAlive)
    }

    private func run(model: String, keepAlive: String) {
        task?.cancel()
        generation = UUID()
        let expected = generation
        let input = inputText
        let capturedMode = mode
        let capturedContext = context
        errorMessage = nil
        copiedAnswer = false
        copiedForHandoff = false
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.answer(
                    mode: capturedMode,
                    input: input,
                    context: capturedContext,
                    model: model,
                    keepAlive: keepAlive
                )
                guard !Task.isCancelled, generation == expected else { return }
                answer = result
            } catch {
                guard !Task.isCancelled, generation == expected else { return }
                errorMessage = error.localizedDescription
            }
            guard generation == expected else { return }
            isLoading = false
            task = nil
        }
    }

    /// 只复制到剪贴板。命令绝不自动粘贴进终端，也绝不代为执行——
    /// 一条 `git reset --hard` 和 `--soft` 只差一个词，按下回车的必须是人。
    func copyAnswer() {
        guard let answer else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(answer.primary, forType: .string)
        copiedAnswer = true
    }

    var handoffTarget: AssistantHandoffTarget {
        .resolve(AppSettings.assistantHandoffTargetRaw)
    }

    func copyAndOpenHandoffTarget() {
        let payload = handoffPayload
        guard !payload.isEmpty, let url = handoffTarget.url else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        copiedForHandoff = true
        NSWorkspace.shared.open(url)
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }

    private func reset() {
        cancel()
        answer = nil
        errorMessage = nil
        copiedAnswer = false
        copiedForHandoff = false
        question = ""
        context = nil
    }
}
