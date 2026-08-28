import Foundation

@MainActor
public final class LiveTranslationService {

    public static let shared = LiveTranslationService()

    private var activeTask: Task<Void, Never>?

    private init() {}

    /// 翻译实时字幕句子（毫秒级流式输出）
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

            let systemInstruction = """
            你是一名实时影视字幕同传翻译员。
            任务：将外语（英文/日文/韩文等）台词翻译成自然通顺、简练地道的简体中文字幕。
            规则：
            1. 严禁输出任何思考过程、解释、拼音、假名、问答或标记。
            2. 仅输出最终的中文字幕译文。
            3. 如果输入本身已经是中文，则保持原样。
            """

            do {
                guard let url = URL(string: "\(AppSettings.baseURL)/api/chat") else { return }

                var request = URLRequest(url: url, timeoutInterval: 10)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let payload: [String: Any] = [
                    "model": AppSettings.model,
                    "messages": [
                        ["role": "system", "content": systemInstruction],
                        ["role": "user", "content": trimmed]
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

                        // 过滤可能夹带的 <think> 标签
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
                // 静默忽略取消异常
            }
        }
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }
}
