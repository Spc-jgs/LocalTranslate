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
        let sourceText: String
        let sourceLanguage: SubtitleSourceLanguage
        let onPartial: @MainActor (String) -> Void
    }

    private struct FinalJob {
        let sourceText: String
        let sourceLanguage: SubtitleSourceLanguage
        let completion: @MainActor (String) -> Void
    }

    private var pendingPreview: PreviewJob?
    private var previewWorkerTask: Task<Void, Never>?
    private var finalWorkerTask: Task<Void, Never>?
    private var finalQueue: [FinalJob] = []

    private init() {}

    /// Keep one request in flight and coalesce subsequent ASR revisions into the
    /// latest pending snapshot. Continuous speech therefore cannot starve the model.
    public func translatePreview(
        _ text: String,
        sourceLanguage: SubtitleSourceLanguage,
        onPartial: @escaping @MainActor (String) -> Void
    ) {
        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        guard sourceLanguage.needsTranslationToSimplifiedChinese else {
            onPartial(sourceText)
            return
        }

        pendingPreview = PreviewJob(
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            onPartial: onPartial
        )
        startPreviewWorkerIfNeeded()
    }

    public func enqueueFinal(
        _ text: String,
        sourceLanguage: SubtitleSourceLanguage,
        onCompletion: @escaping @MainActor (String) -> Void
    ) {
        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        pendingPreview = nil
        previewWorkerTask?.cancel()
        previewWorkerTask = nil

        guard sourceLanguage.needsTranslationToSimplifiedChinese else {
            onCompletion(sourceText)
            return
        }

        finalQueue.append(
            FinalJob(
                sourceText: sourceText,
                sourceLanguage: sourceLanguage,
                completion: onCompletion
            )
        )
        startFinalWorkerIfNeeded()
    }

    public func cancel(unloadModel: Bool = true) {
        pendingPreview = nil
        finalQueue.removeAll(keepingCapacity: false)

        previewWorkerTask?.cancel()
        finalWorkerTask?.cancel()
        previewWorkerTask = nil
        finalWorkerTask = nil

        guard unloadModel else { return }

        let model = AppSettings.model
        let baseURL = AppSettings.baseURL
        Task.detached(priority: .utility) {
            await Self.unloadModel(model, baseURL: baseURL)
        }
    }

    private func startPreviewWorkerIfNeeded() {
        guard previewWorkerTask == nil, finalWorkerTask == nil else { return }

        previewWorkerTask = Task { [weak self] in
            await self?.drainPreview()
        }
    }

    private func drainPreview() async {
        defer { previewWorkerTask = nil }

        // Collect the first few ASR revisions without canceling the worker.
        do {
            try await Task.sleep(for: .milliseconds(280))
        } catch {
            return
        }

        while !Task.isCancelled, let job = pendingPreview {
            pendingPreview = nil

            do {
                _ = try await streamTranslation(
                    job.sourceText,
                    sourceLanguage: job.sourceLanguage,
                    onPartial: job.onPartial
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                job.onPartial(job.sourceText)
            }
        }
    }

    private func startFinalWorkerIfNeeded() {
        guard finalWorkerTask == nil else { return }

        finalWorkerTask = Task { [weak self] in
            await self?.drainFinalQueue()
        }
    }

    private func drainFinalQueue() async {
        defer {
            finalWorkerTask = nil
            startPreviewWorkerIfNeeded()
        }

        while !Task.isCancelled, !finalQueue.isEmpty {
            let job = finalQueue.removeFirst()
            let translatedText: String

            do {
                translatedText = try await streamTranslation(
                    job.sourceText,
                    sourceLanguage: job.sourceLanguage,
                    onPartial: { _ in }
                )
            } catch is CancellationError {
                return
            } catch {
                translatedText = job.sourceText
            }

            guard !Task.isCancelled else { return }
            job.completion(translatedText.isEmpty ? job.sourceText : translatedText)
        }
    }

    private func streamTranslation(
        _ sourceText: String,
        sourceLanguage: SubtitleSourceLanguage,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let url = try makeURL(path: "/api/chat")
        let requestBody = ChatRequest(
            model: AppSettings.model,
            messages: [
                .init(role: "system", content: systemPrompt(for: sourceLanguage)),
                .init(role: "user", content: sourceText)
            ],
            stream: true,
            think: false,
            options: .init(temperature: 0.15, numPredict: 160),
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
        你是一名专业实时中文字幕翻译员。
        将下面的\(sourceLanguage.shortName)语音转写翻译成自然、准确、简练的简体中文。
        结合完整短句理解语义，不要逐词硬译；保留人名、产品名和技术标识符。
        原文可能仍在口语表达中，遇到不完整句时只翻译已有内容，不补写事实。
        只输出译文，不输出解释、思考过程、标签、引号或前后缀。
        """
    }

    private func cleanModelOutput(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
