import Foundation

@MainActor
public final class LiveTranslationService {

    public static let shared = LiveTranslationService()

    private var activeTask: Task<Void, Never>?
    private var lastRequestedText: String = ""

    private init() {}

    /// 翻译实时字幕句子（支持流式逐步输出）
    public func translateSubtitle(
        _ text: String,
        sourceLanguage: SubtitleSourceLanguage,
        onPartial: @escaping @MainActor (String) -> Void,
        onCompletion: @escaping @MainActor (String) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 取消上一句未完成的流式任务
        activeTask?.cancel()

        activeTask = Task { [weak self] in
            guard let self else { return }

            let customPrompt = """
            【实时电影字幕翻译模式】
            你现在是一名专业影视字幕同传翻译员。
            请将输入的影视台词翻译成地道、简练、生动的简体中文字幕。
            规则：
            1. 译文必须极简短、符合中文母语者口语听感，不得啰嗦拖沓。
            2. 严禁输出任何解释、注释、拼音、假名或前后缀，仅输出最终中文字幕。
            3. 如果输入本身已经是中文，则保持原样或进行极微小的口语修饰。
            """

            do {
                let result = try await OllamaClient.shared.translateStream(
                    trimmed,
                    style: .custom,
                    customPrompt: customPrompt
                ) { partial in
                    guard !Task.isCancelled else { return }
                    onPartial(partial)
                }

                guard !Task.isCancelled else { return }
                onCompletion(result)
            } catch {
                guard !Task.isCancelled else { return }
                // 异常时若已有部分文本则保留，否则兜底展示简易状态
            }
        }
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }
}
