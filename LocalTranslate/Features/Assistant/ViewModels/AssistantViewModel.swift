import AppKit
import Combine
import Foundation

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published private(set) var answer: AssistantAnswer?
    @Published private(set) var isLoading = false
    @Published private(set) var isLaunching = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var routeNotice: String?
    @Published private(set) var copiedAnswer = false
    @Published private(set) var copiedForHandoff = false
    /// 面板上那一个输入框。有划词时预填选区，没有就空着，都能改。
    @Published var question = ""
    /// 每次唤起面板时更新，用来把焦点拉回输入框。
    @Published private(set) var invocationID = UUID()
    /// 钉住后点击外部不关。不写 UserDefaults，重启后恢复未钉住。
    @Published var isPinned = false

    private var capturedContext: SelectionContext?
    private var originalSelection = ""

    private let service = AssistantService()
    private var task: Task<Void, Never>?
    private var generation = UUID()

    var inputText: String { question }

    var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoading
    }

    var hasOpenSession: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || answer != nil
            || isLoading
            || errorMessage != nil
    }

    func togglePinned() {
        isPinned.toggle()
    }

    func focusInput() {
        invocationID = UUID()
    }

    var mode: AssistantMode {
        AssistantDraft.shouldAttachCapturedContext(
            draft: question,
            originalSelection: originalSelection
        ) ? .analyzeSelection : .askQuestion
    }

    private var contextForSubmission: SelectionContext? {
        mode == .analyzeSelection ? capturedContext : nil
    }

    var loadingCaption: String {
        if isLaunching { return "正在启动本机助手…" }
        if AppSettings.assistantLocalOnly {
            return "本地模型正在作答…"
        }
        return "本机助手正在作答…"
    }

    var handoffPayload: String {
        AssistantHandoffPayload.make(
            mode: mode,
            input: inputText,
            context: contextForSubmission,
            answer: answer
        )
    }

    /// 有选区：预填进输入框，等 ⌘↩。不自动开算。
    func startWithSelection(_ context: SelectionContext) {
        reset()
        let bounded = AssistantInputBounds.apply(to: context)
        capturedContext = bounded
        originalSelection = bounded.selectedText
        question = bounded.selectedText
        invocationID = UUID()
        warmUpIfNeeded()
    }

    /// 无选区：空框，等用户输入。
    func startWithQuestion() {
        reset()
        invocationID = UUID()
        warmUpIfNeeded()
    }

    /// 菜单栏「启动助手」：只等到 init，不发提问。
    /// 显式启动不受连续失败上限限制，失败三次后仍可再试。
    func startResidentProcess() {
        guard !AppSettings.assistantLocalOnly else { return }
        guard AGYLaunchSpec.binaryURL() != nil else { return }
        Task {
            await AGYSessionProcess.shared.clearFailures()
            try? await AGYSessionProcess.shared.ensureReady()
        }
    }

    func submit() {
        let input = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        run()
    }

    /// 问完 git 接着贴 Java 栈时，上一轮上下文只有污染作用。
    /// 重置 = 关掉 agy 再拉起，同进程内没有重置事件。
    func startNewTopic() {
        cancel()
        answer = nil
        errorMessage = nil
        routeNotice = nil
        copiedAnswer = false
        copiedForHandoff = false
        Task { [weak self] in
            await AGYSessionProcess.shared.resetSession()
            await MainActor.run { self?.warmUpIfNeeded() }
        }
    }

    func stopResidentProcess() {
        cancel()
        Task { await AGYSessionProcess.shared.resetSession() }
    }

    func shutdownResidentProcess() {
        AGYSessionProcess.shared.shutdownSync()
    }

    private func run() {
        task?.cancel()
        generation = UUID()
        let expected = generation
        let input = inputText
        let capturedMode = mode
        let capturedContext = contextForSubmission
        errorMessage = nil
        routeNotice = nil
        copiedAnswer = false
        copiedForHandoff = false
        isLoading = true
        isLaunching = false
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.resolveAnswer(
                mode: capturedMode,
                input: input,
                context: capturedContext
            )
            guard !Task.isCancelled, generation == expected else { return }
            switch outcome {
            case .answered(let result, let notice):
                answer = result
                routeNotice = notice
            case .failed(let message):
                errorMessage = message
            case .cancelled:
                break
            }
            guard generation == expected else { return }
            isLoading = false
            isLaunching = false
            task = nil
        }
    }

    private enum Outcome {
        case answered(AssistantAnswer, notice: String?)
        case failed(String)
        case cancelled
    }

    private func resolveAnswer(
        mode: AssistantMode,
        input: String,
        context: SelectionContext?
    ) async -> Outcome {
        let localModel = AppSettings.model
        let localOnly = AppSettings.assistantLocalOnly
        let binaryAvailable = AGYLaunchSpec.binaryURL() != nil
        let failures = AGYSessionProcess.shared.consecutiveFailures
        if localOnly, AGYSessionProcess.shared.isRunning {
            await AGYSessionProcess.shared.resetSession()
        }

        if AssistantDegradationPolicy.shouldAttemptAGY(
            localOnly: localOnly,
            binaryAvailable: binaryAvailable,
            consecutiveFailures: failures
        ) {
            isLaunching = !AGYSessionProcess.shared.isReady
            do {
                try await AGYSessionProcess.shared.ensureReady()
                if Task.isCancelled { return .cancelled }
                isLaunching = false
                let payload = try await AGYSessionProcess.shared.ask(
                    prompt: AssistantPromptParts.agyPrompt(
                        mode: mode,
                        input: input,
                        context: context
                    )
                )
                let decoded = try AssistantOutputSchema.parse(payload.response)
                return .answered(
                    makeAnswer(
                        decoded,
                        modelID: AGYLaunchSpec.sourceModelID,
                        source: .agy
                    ),
                    notice: nil
                )
            } catch is CancellationError {
                return .cancelled
            } catch let error as AGYSessionProcess.SessionError
                where error == .cancelled {
                return .cancelled
            } catch {
                if Task.isCancelled { return .cancelled }
                let trigger = (error as? AGYSessionProcess.SessionError)?
                    .degradeTrigger ?? .startFailed
                var notice = AssistantDegradationPolicy.notice(
                    for: trigger,
                    localModel: localModel
                )
                if let session = error as? AGYSessionProcess.SessionError {
                    switch session {
                    case .statusNotSuccess(let detail),
                         .startFailed(let detail):
                        if !detail.isEmpty {
                            notice =
                                "agy 不可用（\(detail)），已改用本地 \(localModel)"
                        }
                    default:
                        if let desc = session.errorDescription,
                           !desc.isEmpty {
                            notice =
                                "\(desc)，已改用本地 \(localModel)"
                        }
                    }
                } else {
                    notice =
                        "agy 返回无法解析，已改用本地 \(localModel)"
                }
                return await localAnswer(
                    mode: mode,
                    input: input,
                    context: context,
                    model: localModel,
                    notice: notice
                )
            }
        }

        let notice: String?
        if localOnly {
            notice = nil
        } else if !binaryAvailable {
            notice = AssistantDegradationPolicy.notice(
                for: .binaryMissing,
                localModel: localModel
            )
        } else {
            notice = AssistantDegradationPolicy.notice(
                for: .startFailed,
                localModel: localModel
            )
        }
        return await localAnswer(
            mode: mode,
            input: input,
            context: context,
            model: localModel,
            notice: notice
        )
    }

    private func localAnswer(
        mode: AssistantMode,
        input: String,
        context: SelectionContext?,
        model: String,
        notice: String?
    ) async -> Outcome {
        isLaunching = false
        do {
            let result = try await service.answer(
                mode: mode,
                input: input,
                context: context,
                model: model,
                keepAlive: AppSettings.keepAlive
            )
            return .answered(result, notice: notice)
        } catch is CancellationError {
            return .cancelled
        } catch {
            if Task.isCancelled { return .cancelled }
            let ollama = OllamaFailure.message(for: error)
            if let notice {
                return .failed("\(notice)。\(ollama)")
            }
            return .failed(ollama)
        }
    }

    private func makeAnswer(
        _ decoded: AssistantOutputSchema.ModelAnswer,
        modelID: String,
        source: AssistantAnswerSource
    ) -> AssistantAnswer {
        var primary = trim(decoded.primary, maximumCharacters: 600)
        var note = trim(decoded.note, maximumCharacters: 300)
        if primary.isEmpty {
            primary = note.isEmpty ? "没有给出可用的答案。" : note
            if primary == note { note = "" }
        }
        return AssistantAnswer(
            kind: decoded.kind,
            primary: primary,
            note: note,
            hazard: decoded.kind == .command
                ? DestructiveCommandPolicy.hazard(in: primary)
                : nil,
            modelID: modelID,
            source: source
        )
    }

    private func trim(
        _ value: String,
        maximumCharacters: Int
    ) -> String {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters)) + "…"
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
        isLaunching = false
    }

    private func reset() {
        cancel()
        answer = nil
        errorMessage = nil
        routeNotice = nil
        copiedAnswer = false
        copiedForHandoff = false
        question = ""
        capturedContext = nil
        originalSelection = ""
    }

    /// 打开面板：拉起 agy 等到 init，与打字重叠。
    /// 只用本地、没二进制、或已连续失败三次时不拉。
    private func warmUpIfNeeded() {
        let localOnly = AppSettings.assistantLocalOnly
        let binaryAvailable = AGYLaunchSpec.binaryURL() != nil
        let failures = AGYSessionProcess.shared.consecutiveFailures
        guard AssistantDegradationPolicy.shouldAttemptAGY(
            localOnly: localOnly,
            binaryAvailable: binaryAvailable,
            consecutiveFailures: failures
        ) else { return }
        Task {
            try? await AGYSessionProcess.shared.ensureReady()
        }
    }
}
