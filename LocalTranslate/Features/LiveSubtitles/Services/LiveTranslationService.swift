import Foundation

@MainActor
public final class LiveTranslationService {

    public static let shared = LiveTranslationService()

    private var activeTask: Task<Void, Never>?
    private var pendingWorkItem: DispatchWorkItem?

    private init() {}

    /// 翻译实时字幕句子（带 300ms 平滑防抖与毫秒级流式输出）
    public func translateSubtitle(
        _ text: String,
        sourceLanguage: SubtitleSourceLanguage,
        isFinal: Bool = false,
        onPartial: @escaping @MainActor (String) -> Void,
        onCompletion: @escaping @MainActor (String) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 取消之前的待执行防抖任务
        pendingWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.executeTranslation(
                trimmed,
                sourceLanguage: sourceLanguage,
                onPartial: onPartial,
                onCompletion: onCompletion
            )
        }

        self.pendingWorkItem = workItem

        if isFinal {
            // 如果是断句最终确定的句子，立即执行翻译，无需等待防抖
            workItem.perform()
        } else {
            // 流式中间片段：320ms 防抖，聚合连续单词
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: workItem)
        }
    }

    private func executeTranslation(
        _ text: String,
        sourceLanguage: SubtitleSourceLanguage,
        onPartial: @escaping @MainActor (String) -> Void,
        onCompletion: @escaping @MainActor (String) -> Void
    ) {
        activeTask?.cancel()

        activeTask = Task { [weak self] in
            guard let self else { return }

            let systemInstruction = """
            你是一名专业影视字幕同传翻译员。
            任务：将输入的影视台词翻译为自然通顺、简练生动的简体中文字幕。
            规则：
            1. 严禁输出任何思考过程、解释、拼音、假名或前后缀，仅直接输出最终中文字幕。
            2. 译文简练地道，符合中文母语者口语习惯。
            3. 如果输入本身已经是中文，则保持原样。
            """

            do {
                guard let url = URL(string: "\(AppSettings.baseURL)/api/chat") else { return }

                var request = URLRequest(url: url, timeoutInterval: 12)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let payload: [String: Any] = [
                    "model": AppSettings.model,
                    "messages": [
                        ["role": "system", "content": systemInstruction],
                        ["role": "user", "content": text]
                    ],
                    "stream": true,
                    "think": false,
                    "options": [
                        "temperature": 0.2,
                        "num_predict": 128
                    ],
                    "keep_alive": AppSettings.keepAlive
                ]

                request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    return
                }

                var fullTranslation = ""

                for try await line in bytes.lines {
                    guard !Task.isCancelled else { break }

                    let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedLine.isEmpty, let data = trimmedLine.data(using: .utf8) else { continue }

                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let message = json["message"] as? [String: Any],
                       let content = message["content"] as? String,
                       !content.isEmpty {

                        let cleaned = content.replacingOccurrences(of: "<think>", with: "")
                                             .replacingOccurrences(of: "</think>", with: "")

                        fullTranslation += cleaned
                        onPartial(fullTranslation.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }

                let finalClean = fullTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
                if !Task.isCancelled && !finalClean.isEmpty {
                    onCompletion(finalClean)
                }
            } catch {
                // 静默处理取消异常
            }
        }
    }

    public func cancel() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        activeTask?.cancel()
        activeTask = nil
    }
}
