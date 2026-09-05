import AppKit
import Combine
import Foundation

@MainActor
final class TriageViewModel: ObservableObject {
    @Published private(set) var context: SelectionContext?
    @Published private(set) var decision: TriageDecision?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var copiedForHandoff = false

    private let service = TriageService()
    private var task: Task<Void, Never>?
    private var generation = UUID()

    var handoffPayload: String {
        guard let context else { return "" }
        return TriageHandoffPayload.make(context: context, decision: decision)
    }

    func load(_ context: SelectionContext) {
        cancel()
        let boundedContext = TriageInputBounds.apply(to: context)
        self.context = boundedContext
        decision = nil
        errorMessage = nil
        copiedForHandoff = false
        isLoading = true
        let expectedGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.evaluate(boundedContext)
                guard !Task.isCancelled, generation == expectedGeneration else { return }
                decision = result
            } catch {
                guard !Task.isCancelled, generation == expectedGeneration else { return }
                errorMessage = error.localizedDescription
                decision = TriageDecision(
                    route: .escalate,
                    kind: .ambiguous,
                    explanation: "本地模型暂时无法给出可靠解释。",
                    uncertaintyReason: "分诊请求失败，建议交给 ChatGPT 核对。",
                    handoffQuestion: "请结合上下文解释选中内容，并核对可能的歧义。",
                    wasPolicyApplied: false
                )
            }
            guard generation == expectedGeneration else { return }
            isLoading = false
            task = nil
        }
    }

    func copyAndOpenChatGPT() {
        let payload = handoffPayload
        guard !payload.isEmpty,
              let url = URL(string: "https://chatgpt.com/") else { return }
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
}
