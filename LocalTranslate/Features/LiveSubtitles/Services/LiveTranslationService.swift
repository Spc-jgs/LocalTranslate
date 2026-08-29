import Foundation

@MainActor
public final class LiveTranslationService {

    public static let shared = LiveTranslationService()

    private enum ServiceError: Error {
        case invalidURL
        case invalidResponse(statusCode: Int)
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct Options: Encodable {
            let temperature: Double
            let numPredict: Int

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }

        let model: String
        let messages: [Message]
        let stream: Bool
        let think: Bool
        let options: Options
        let keepAlive: String

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case stream
            case think
            case options
            case keepAlive = "keep_alive"
        }
    }

    private struct StreamResponse: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message?
        let done: Bool?
    }

    private struct PreviewJob {
        let key: LiveTranslationRequestKey
        let sourceText: String
        let context: [SubtitleItem]
        let sourceLanguage: SubtitleSourceLanguage
        let completion: @MainActor (LiveTranslationRequestKey, String) -> Void
    }

    private struct FinalJob {
        let key: LiveTranslationRequestKey
        let sourceText: String
        let context: [SubtitleItem]
        let sourceLanguage: SubtitleSourceLanguage
        let onPartial: @MainActor (LiveTranslationRequestKey, String) -> Void
        let completion: @MainActor (LiveTranslationRequestKey, String) -> Void
    }

    private var pendingPreview: PreviewJob?
    private var previewWorkerTask: Task<Void, Never>?
    private var finalWorkerTask: Task<Void, Never>?
    private var finalQueue: [FinalJob] = []
    private var previewGeneration = 0
    private var finalGeneration = 0

    private init() {}

    /// Keep one request in flight and coalesce subsequent semantic-ready ASR
    /// revisions into the latest pending snapshot. Preview is published only
    /// after a complete response, so the UI swaps atomically instead of exposing
    /// token-by-token rewrites of an unstable source phrase.
    public func translatePreview(
        key: LiveTranslationRequestKey,
        _ text: String,
        context: [SubtitleItem] = [],
        sourceLanguage: SubtitleSourceLanguage,
        onCompletion: @escaping @MainActor (LiveTranslationRequestKey, String) -> Void
    ) {
        guard key.kind == .preview else { return }

        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        guard sourceLanguage.needsTranslationToSimplifiedChinese else {
            onCompletion(key, sourceText)
            return
        }

        pendingPreview = PreviewJob(
            key: key,
            sourceText: sourceText,
            context: context,
            sourceLanguage: sourceLanguage,
            completion: onCompletion
        )
        trace("preview-enqueued", key: key)
        startPreviewWorkerIfNeeded()
    }

    public func enqueueFinal(
        key: LiveTranslationRequestKey,
        _ text: String,
        context: [SubtitleItem] = [],
        sourceLanguage: SubtitleSourceLanguage,
        onPartial: @escaping @MainActor (LiveTranslationRequestKey, String) -> Void,
        onCompletion: @escaping @MainActor (LiveTranslationRequestKey, String) -> Void
    ) {
        guard key.kind == .final else { return }

        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        guard sourceLanguage.needsTranslationToSimplifiedChinese else {
            onCompletion(key, sourceText)
            return
        }

        finalQueue.append(
            FinalJob(
                key: key,
                sourceText: sourceText,
                context: context,
                sourceLanguage: sourceLanguage,
                onPartial: onPartial,
                completion: onCompletion
            )
        )
        trace("final-enqueued", key: key)
        startFinalWorkerIfNeeded()
    }

    public func cancelPreview() {
        if let key = pendingPreview?.key {
            trace("preview-cancelled", key: key)
        }
        previewGeneration += 1
        pendingPreview = nil
        previewWorkerTask?.cancel()
        previewWorkerTask = nil
    }

    public func cancel(unloadModel: Bool = true) {
        cancelPreview()
        finalGeneration += 1
        finalQueue.removeAll(keepingCapacity: false)

        finalWorkerTask?.cancel()
        finalWorkerTask = nil

        guard unloadModel else { return }

        let model = AppSettings.model
        let baseURL = AppSettings.baseURL
        Task.detached(priority: .utility) {
            await Self.unloadModel(model, baseURL: baseURL)
        }
    }

    private func startPreviewWorkerIfNeeded() {
        guard previewWorkerTask == nil else { return }

        let generation = previewGeneration
        previewWorkerTask = Task { [weak self] in
            await self?.drainPreview(generation: generation)
        }
    }

    private func drainPreview(generation: Int) async {
        defer {
            if previewGeneration == generation {
                previewWorkerTask = nil
            }
        }

        while !Task.isCancelled,
              previewGeneration == generation,
              let job = pendingPreview {
            pendingPreview = nil
            trace("preview-started", key: job.key)
            var didTraceFirstToken = false
            let translatedText: String

            do {
                translatedText = try await streamTranslation(
                    job.sourceText,
                    context: job.context,
                    sourceLanguage: job.sourceLanguage,
                    onPartial: { translatedText in
                        if !didTraceFirstToken {
                            didTraceFirstToken = true
                            self.trace("preview-first-token", key: job.key)
                        }
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      previewGeneration == generation else { return }
                job.completion(job.key, "")
                continue
            }

            guard !Task.isCancelled,
                  previewGeneration == generation else { return }
            job.completion(job.key, translatedText)
            trace("preview-completed", key: job.key)
        }
    }

    private func startFinalWorkerIfNeeded() {
        guard finalWorkerTask == nil else { return }

        let generation = finalGeneration
        finalWorkerTask = Task { [weak self] in
            await self?.drainFinalQueue(generation: generation)
        }
    }

    private func drainFinalQueue(generation: Int) async {
        defer {
            if finalGeneration == generation {
                finalWorkerTask = nil
            }
        }

        while !Task.isCancelled,
              finalGeneration == generation,
              !finalQueue.isEmpty {
            let job = finalQueue.removeFirst()
            let translatedText: String
            trace("final-started", key: job.key)

            do {
                translatedText = try await streamTranslation(
                    job.sourceText,
                    context: job.context,
                    sourceLanguage: job.sourceLanguage,
                    onPartial: { translatedText in
                        job.onPartial(job.key, translatedText)
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                translatedText = ""
            }

            guard !Task.isCancelled,
                  finalGeneration == generation else { return }
            job.completion(
                job.key,
                translatedText
            )
            trace("final-completed", key: job.key)
        }
    }

    private func trace(
        _ event: String,
        key: LiveTranslationRequestKey
    ) {
        #if DEBUG
        print(
            "[LiveTranslation] event=\(event) kind=\(key.kind) "
                + "segment=\(key.segmentID) revision=\(key.revision)"
        )
        #endif
    }

    private func streamTranslation(
        _ sourceText: String,
        context: [SubtitleItem] = [],
        sourceLanguage: SubtitleSourceLanguage,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let url = try makeURL(path: "/api/chat")

        var messages: [ChatRequest.Message] = [
            .init(role: "system", content: systemPrompt(for: sourceLanguage))
        ]

        // 注入前序对话历史（全局上下文）
        for item in context.suffix(2) {
            let orig = item.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let trans = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !orig.isEmpty && !trans.isEmpty {
                messages.append(.init(role: "user", content: orig))
                messages.append(.init(role: "assistant", content: trans))
            }
        }

        messages.append(.init(role: "user", content: sourceText))

        let requestBody = ChatRequest(
            model: AppSettings.model,
            messages: messages,
            stream: true,
            think: false,
            options: .init(temperature: 0.15, numPredict: 140),
            keepAlive: AppSettings.keepAlive
        )

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ServiceError.invalidResponse(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }

        var fullTranslation = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty,
                  let data = trimmedLine.data(using: .utf8) else {
                continue
            }

            let chunk = try JSONDecoder().decode(StreamResponse.self, from: data)
            if let content = chunk.message?.content, !content.isEmpty {
                fullTranslation += content
                let cleaned = cleanModelOutput(fullTranslation)
                if !cleaned.isEmpty {
                    onPartial(cleaned)
                }
            }

            if chunk.done == true {
                break
            }
        }

        return cleanModelOutput(fullTranslation)
    }

    private func makeURL(path: String) throws -> URL {
        var baseURL = AppSettings.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if baseURL.hasPrefix("http://localhost:") {
            baseURL = baseURL.replacingOccurrences(
                of: "http://localhost:",
                with: "http://127.0.0.1:"
            )
        } else if baseURL == "http://localhost" {
            baseURL = "http://127.0.0.1"
        }

        guard let url = URL(string: baseURL + path) else {
            throw ServiceError.invalidURL
        }
        return url
    }

    private func systemPrompt(for sourceLanguage: SubtitleSourceLanguage) -> String {
        """
        你是一名专业实时影视字幕同传翻译。
        请将输入的\(sourceLanguage.shortName)语音字幕翻译为简练、通顺的简体中文。
        要求：
        1. 严格只输出纯中文译文，严禁输出“注：”、“注意：”、括号解释、任何前言后语或思考过程。
        2. 若输入为短语或未说完口语，直接顺畅直译已有内容，严禁拒绝或解释。
        3. 保持人名、代码和技术专有名词前后一致。
        """
    }

    private func cleanModelOutput(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")

        // 强力过滤任何形如（注：...）或 (Note: ...) 的大模型免责/补充声明
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*[\(（\[【](?:注|注意|Note|说明).*?[\)）\]】]"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*[\(（\[【](?:注|注意|Note|说明).*$"#,
            with: "",
            options: .regularExpression
        )

        cleaned = cleaned
            .replacingOccurrences(of: "……", with: "，")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    private nonisolated static func unloadModel(_ model: String, baseURL: String) async {
        let trimmedBaseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "http://localhost:", with: "http://127.0.0.1:")

        guard let url = URL(string: trimmedBaseURL + "/api/generate") else { return }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["model": model, "keep_alive": 0]
        )
        _ = try? await URLSession.shared.data(for: request)
    }
}
