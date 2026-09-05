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
            let numContext: Int

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
                case numContext = "num_ctx"
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
        let loadDuration: UInt64?
        let promptEvalDuration: UInt64?
        let evalDuration: UInt64?
        let promptEvalCount: Int?
        let evalCount: Int?

        enum CodingKeys: String, CodingKey {
            case message
            case done
            case loadDuration = "load_duration"
            case promptEvalDuration = "prompt_eval_duration"
            case evalDuration = "eval_duration"
            case promptEvalCount = "prompt_eval_count"
            case evalCount = "eval_count"
        }
    }

    private struct TranslationJob {
        let key: LiveTranslationRequestKey
        let sourceText: String
        /// 已经显示在字幕条上的译文。非空时作为 prefill 送进请求末尾，
        /// 模型只能往后写，屏幕上的字因此不会被改写。
        let continuing: String
        let context: [SubtitleItem]
        let sourceLanguage: SubtitleSourceLanguage
        let archivable: Bool
        let retryCount: Int
        let onPartial: @MainActor (LiveTranslationRequestKey, String) -> Void
        let completion: @MainActor (LiveTranslationRequestKey, String) -> Void

        /// 整句定稿：主行靠它翻页，不能被打断重来。
        var isStable: Bool { key.kind == .final && !archivable }

        func archived() -> TranslationJob {
            TranslationJob(
                key: key,
                sourceText: sourceText,
                continuing: continuing,
                context: context,
                sourceLanguage: sourceLanguage,
                archivable: true,
                retryCount: retryCount,
                onPartial: onPartial,
                completion: completion
            )
        }

        func retryingAsArchive() -> TranslationJob {
            TranslationJob(
                key: key,
                sourceText: sourceText,
                continuing: continuing,
                context: context,
                sourceLanguage: sourceLanguage,
                archivable: true,
                retryCount: retryCount + 1,
                onPartial: onPartial,
                completion: completion
            )
        }
    }

    private var pendingForeground: TranslationJob?
    private var activeJob: TranslationJob?
    private var activeIsArchive = false
    /// 整句定稿。它决定主行何时翻页，说话期间也必须跑，所以不能扔进归档队列；
    /// 但它同样不能去抢 preview 的槽位——那个槽位只有一个位子，而且新进来的
    /// 会抢占正在跑的活，整句挤进去就是把用户正在看的 preview 丢掉。
    /// 单独排一队：preview 之后，归档之前，先来先到，谁也不抢占谁。
    private var stableQueue: LiveStableBacklog<TranslationJob>
    private var archiveQueue: [TranslationJob] = []
    private var workerTask: Task<Void, Never>?
    private var workerGeneration = 0
    private var liveActivity = false

    private init() {
        stableQueue = LiveStableBacklog(limit: Self.maximumStableBacklog)
    }

    public func prepare() async {
        let model = AppSettings.model
        let baseURL = AppSettings.baseURL
        let keepAlive = AppSettings.keepAlive
        await Self.loadModel(model, baseURL: baseURL, keepAlive: keepAlive)
    }

    public func translatePreview(
        key: LiveTranslationRequestKey,
        _ text: String,
        continuing: String = "",
        context: [SubtitleItem] = [],
        sourceLanguage: SubtitleSourceLanguage,
        onPartial: @escaping @MainActor (LiveTranslationRequestKey, String) -> Void,
        onCompletion: @escaping @MainActor (LiveTranslationRequestKey, String) -> Void
    ) {
        guard key.kind == .preview else { return }
        let sourceText = normalized(text)
        guard !sourceText.isEmpty else { return }

        guard sourceLanguage.needsTranslationToSimplifiedChinese else {
            onCompletion(key, sourceText)
            return
        }

        LiveSubtitleDiagnosticsLog.shared.translationQueued(id: key.diagnosticsID)

        submitForeground(
            TranslationJob(
                key: key,
                sourceText: sourceText,
                continuing: continuing,
                context: Array(context.suffix(1)),
                sourceLanguage: sourceLanguage,
                archivable: false,
                retryCount: 0,
                onPartial: onPartial,
                completion: onCompletion
            )
        )
    }

    /// Archive translation is opportunistic background work. It must never
    /// occupy Ollama while speech is actively producing live preview windows.
    public func setLiveActivity(_ active: Bool) {
        guard liveActivity != active else { return }
        liveActivity = active
        if active, activeIsArchive {
            preemptActiveJob(requeue: true)
        } else if !active {
            startWorkerIfNeeded()
        }
    }

    public func enqueueFinal(
        key: LiveTranslationRequestKey,
        _ text: String,
        context: [SubtitleItem] = [],
        sourceLanguage: SubtitleSourceLanguage,
        onPartial: @escaping @MainActor (LiveTranslationRequestKey, String) -> Void,
        onCompletion: @escaping @MainActor (LiveTranslationRequestKey, String) -> Void
    ) {
        submitFinal(
            key: key,
            text,
            context: context,
            sourceLanguage: sourceLanguage,
            foreground: true,
            onPartial: onPartial,
            onCompletion: onCompletion
        )
    }

    /// 整句积压的上限。说得比翻得快时，最旧任务退出前台队列，但 finalized
    /// source 不能丢；它转入 archive，在静音或停止说话后补齐历史。
    private static let maximumStableBacklog = 4
    /// 约 64 个语义窗，按常见 5-14 词窗口足以覆盖数分钟积压；超过时显式失败，
    /// 由 ViewModel 保留源转录，而不是让长会话无限吃内存。
    private static let maximumArchiveBacklog = 64

    /// 整句定稿翻译。主行靠它翻页，所以说话期间也要跑；但它排在 preview
    /// 之后，且不抢占正在跑的活。
    public func enqueueStable(
        key: LiveTranslationRequestKey,
        _ text: String,
        context: [SubtitleItem] = [],
        sourceLanguage: SubtitleSourceLanguage,
        onCompletion: @escaping @MainActor (LiveTranslationRequestKey, String) -> Void
    ) {
        guard key.kind == .final else { return }
        let sourceText = normalized(text)
        guard !sourceText.isEmpty else { return }

        guard sourceLanguage.needsTranslationToSimplifiedChinese else {
            onCompletion(key, sourceText)
            return
        }

        LiveSubtitleDiagnosticsLog.shared.translationQueued(id: key.diagnosticsID)

        let job = TranslationJob(
                key: key,
                sourceText: sourceText,
                continuing: "",
                context: Array(context.suffix(1)),
                sourceLanguage: sourceLanguage,
                archivable: false,
                retryCount: 0,
                onPartial: { _, _ in },
                completion: onCompletion
            )
        if let displaced = stableQueue.append(job) {
            enqueueArchiveJob(displaced.archived())
        }
        startWorkerIfNeeded()
    }

    public func enqueueArchive(
        key: LiveTranslationRequestKey,
        _ text: String,
        context: [SubtitleItem] = [],
        sourceLanguage: SubtitleSourceLanguage,
        onCompletion: @escaping @MainActor (LiveTranslationRequestKey, String) -> Void
    ) {
        submitFinal(
            key: key,
            text,
            context: context,
            sourceLanguage: sourceLanguage,
            foreground: false,
            onPartial: { _, _ in },
            onCompletion: onCompletion
        )
    }

    public func cancelPreview() {
        if pendingForeground?.key.kind == .preview {
            pendingForeground = nil
        }
        if activeJob?.key.kind == .preview {
            preemptActiveJob(requeue: false)
        }
        startWorkerIfNeeded()
    }

    public func cancel(unloadModel: Bool = true) {
        workerGeneration += 1
        pendingForeground = nil
        activeJob = nil
        activeIsArchive = false
        stableQueue.removeAll()
        archiveQueue.removeAll(keepingCapacity: false)
        workerTask?.cancel()
        workerTask = nil
        liveActivity = false

        guard unloadModel else { return }
        let model = AppSettings.model
        let baseURL = AppSettings.baseURL
        Task.detached(priority: .utility) {
            await Self.unloadModel(model, baseURL: baseURL)
        }
    }

    private func submitFinal(
        key: LiveTranslationRequestKey,
        _ text: String,
        context: [SubtitleItem],
        sourceLanguage: SubtitleSourceLanguage,
        foreground: Bool,
        onPartial: @escaping @MainActor (LiveTranslationRequestKey, String) -> Void,
        onCompletion: @escaping @MainActor (LiveTranslationRequestKey, String) -> Void
    ) {
        guard key.kind == .final else { return }
        let sourceText = normalized(text)
        guard !sourceText.isEmpty else { return }

        guard sourceLanguage.needsTranslationToSimplifiedChinese else {
            onCompletion(key, sourceText)
            return
        }

        // 整句定稿不做续写：这是这段语音唯一一次可以推翻先前措辞的机会，
        // 锁住前缀等于把 preview 阶段的错译一起定死。
        let job = TranslationJob(
            key: key,
            sourceText: sourceText,
            continuing: "",
            context: Array(context.suffix(1)),
            sourceLanguage: sourceLanguage,
            archivable: true,
            retryCount: 0,
            onPartial: onPartial,
            completion: onCompletion
        )
        if foreground {
            submitForeground(job)
        } else {
            enqueueArchiveJob(job)
            startWorkerIfNeeded()
        }
    }

    private func submitForeground(_ job: TranslationJob) {
        let displaced = pendingForeground
        pendingForeground = nil
        if let displaced, displaced.archivable {
            enqueueArchiveJob(displaced)
        }
        pendingForeground = job
        trace("foreground-enqueued", key: job.key)

        if let activeJob, activeJob.key != job.key, !activeJob.isStable {
            // The overlay follows the newest stable/preview window. A stable
            // request displaced from the live slot is retained as archive
            // work; an obsolete preview is intentionally discarded.
            //
            // 但正在跑的整句定稿不抢占：它只要几百毫秒，主行等着它翻页，
            // 而它被 cancel 之后 completion 不会触发（drainQueue 检查
            // workerGeneration 就返回了），调用方的待办记录会一直挂着，
            // 那一句永远翻不了页。preview 等它跑完，比杀掉重排划算。
            preemptActiveJob(requeue: activeJob.archivable)
        }
        startWorkerIfNeeded()
    }

    private func enqueueArchiveJob(_ job: TranslationJob) {
        guard job.archivable,
              activeJob?.key != job.key,
              pendingForeground?.key != job.key,
              !archiveQueue.contains(where: { $0.key == job.key }) else { return }
        archiveQueue.append(job)
        if archiveQueue.count > Self.maximumArchiveBacklog {
            let overflow = archiveQueue.removeFirst()
            overflow.completion(overflow.key, "")
            trace("archive-budget-exceeded", key: overflow.key)
        }
        trace("archive-enqueued", key: job.key)
    }

    private func preemptActiveJob(requeue: Bool) {
        let interrupted = activeJob
        let cancelledWorker = workerTask
        workerGeneration += 1
        let replacementGeneration = workerGeneration
        activeJob = nil
        activeIsArchive = false
        cancelledWorker?.cancel()
        if requeue, let interrupted, interrupted.archivable {
            enqueueArchiveJob(interrupted)
        }
        // Wait until URLSession's cancelled byte stream has actually unwound
        // before starting the replacement. This keeps Ollama concurrency at
        // one even during rapid foreground revisions.
        workerTask = Task { [weak self] in
            await cancelledWorker?.value
            guard !Task.isCancelled else { return }
            await self?.drainQueue(generation: replacementGeneration)
        }
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil,
              pendingForeground != nil
                || !stableQueue.isEmpty
                || (!liveActivity && !archiveQueue.isEmpty) else { return }
        let generation = workerGeneration
        workerTask = Task { [weak self] in
            await self?.drainQueue(generation: generation)
        }
    }

    private func drainQueue(generation: Int) async {
        defer {
            if workerGeneration == generation {
                activeJob = nil
                activeIsArchive = false
                workerTask = nil
                startWorkerIfNeeded()
            }
        }

        while !Task.isCancelled, workerGeneration == generation {
            if pendingForeground == nil, stableQueue.isEmpty, liveActivity {
                return
            }

            if pendingForeground == nil, stableQueue.isEmpty, !archiveQueue.isEmpty {
                // Give the live preview throttle a short opportunity to fill
                // the foreground slot before starting background history work.
                // This avoids repeatedly starting and cancelling archive HTTP
                // streams between two consecutive live captions.
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      workerGeneration == generation,
                      !liveActivity else { return }
            }

            let job: TranslationJob
            if let foreground = pendingForeground {
                pendingForeground = nil
                activeIsArchive = false
                job = foreground
            } else if !stableQueue.isEmpty {
                activeIsArchive = false
                job = stableQueue.removeFirst()
            } else if !archiveQueue.isEmpty {
                activeIsArchive = true
                job = archiveQueue.removeFirst()
            } else {
                return
            }

            activeJob = job
            LiveSubtitleDiagnosticsLog.shared.translationStarted(
                id: job.key.diagnosticsID
            )
            trace("translation-started", key: job.key)
            let translatedText: String
            do {
                translatedText = try await streamTranslation(
                    job.sourceText,
                    continuing: job.continuing,
                    context: job.context,
                    sourceLanguage: job.sourceLanguage,
                    key: job.key,
                    onPartial: { partial in
                        job.onPartial(job.key, partial)
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                translatedText = ""
            }

            guard !Task.isCancelled, workerGeneration == generation else { return }
            activeJob = nil
            activeIsArchive = false
            if translatedText.isEmpty,
               job.key.kind == .final,
               job.retryCount < 1 {
                // finalized source 不因一次网络或模型失败消失。第一次失败转到
                // archive，等静音后再试一次；仍失败才通知调用方显式收口。
                enqueueArchiveJob(job.retryingAsArchive())
                trace("translation-retry-enqueued", key: job.key)
                continue
            }
            job.completion(job.key, translatedText)
            trace("translation-completed", key: job.key)
        }
    }

    private func streamTranslation(
        _ sourceText: String,
        continuing: String,
        context: [SubtitleItem],
        sourceLanguage: SubtitleSourceLanguage,
        key: LiveTranslationRequestKey,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let url = try makeURL(path: "/api/chat")
        var messages: [ChatRequest.Message] = [
            .init(role: "system", content: systemPrompt(for: sourceLanguage))
        ]

        for item in context.suffix(1) {
            let original = normalized(item.originalText)
            let translated = normalized(item.translatedText)
            if !original.isEmpty, !translated.isEmpty {
                messages.append(.init(role: "user", content: original))
                messages.append(.init(role: "assistant", content: translated))
            }
        }
        messages.append(.init(role: "user", content: sourceText))
        // 末尾放一条 assistant，语义是「你已经写到这里了，接着写」。模型返回
        // 的就只是增量——已经显示出去的字物理上不可能被改写。实测第一份真实
        // 日志里改写占 94%、新旧译文公共前缀平均只有 19%，那是每次都在重新
        // 组织整句措辞；这条消息把重译变成续写。
        if !continuing.isEmpty {
            messages.append(.init(role: "assistant", content: continuing))
        }

        let body = ChatRequest(
            model: AppSettings.model,
            messages: messages,
            stream: true,
            think: false,
            options: .init(
                temperature: 0,
                // 取词上界放到 40 个词之后，一段译文可能有六七十个中文字，
                // 而中文大致一字一 token——64 会把长句的结尾直接截掉。
                numPredict: 96,
                numContext: 2_048
            ),
            keepAlive: AppSettings.keepAlive
        )

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let requestStartedAt = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ServiceError.invalidResponse(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }

        var fullTranslation = ""
        var lastPublishedPartial = ""
        var firstTokenAt: Date?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8) else { continue }

            let chunk = try JSONDecoder().decode(StreamResponse.self, from: data)
            if let content = chunk.message?.content, !content.isEmpty {
                if firstTokenAt == nil {
                    firstTokenAt = Date()
                    LiveSubtitleDiagnosticsLog.shared.translationFirstToken(
                        id: key.diagnosticsID
                    )
                }
                fullTranslation += content
                let cleaned = LiveCaptionPresenter.stitch(
                    prefix: continuing,
                    continuation: cleanModelOutput(fullTranslation)
                )
                if shouldPublishPartial(
                    cleaned,
                    after: lastPublishedPartial
                ) {
                    lastPublishedPartial = cleaned
                    onPartial(cleaned)
                }
            }

            if chunk.done == true {
                recordFirstToken(
                    requestStartedAt: requestStartedAt,
                    firstTokenAt: firstTokenAt
                )
                traceMetrics(
                    key: key,
                    requestStartedAt: requestStartedAt,
                    firstTokenAt: firstTokenAt,
                    response: chunk
                )
                break
            }
        }
        return LiveCaptionPresenter.stitch(
            prefix: continuing,
            continuation: cleanModelOutput(fullTranslation)
        )
    }

    private func shouldPublishPartial(
        _ candidate: String,
        after previous: String
    ) -> Bool {
        guard candidate.count >= 2,
              candidate.hasPrefix(previous),
              candidate != previous else { return false }
        let addedCount = candidate.count - previous.count
        if previous.isEmpty || addedCount >= 2 {
            return true
        }
        return candidate.last.map { "，。！？；：,.!?;:".contains($0) } ?? false
    }

    private func makeURL(path: String) throws -> URL {
        do {
            return try OllamaEndpoint.url(path: path)
        } catch {
            throw ServiceError.invalidURL
        }
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
        return cleaned
            .replacingOccurrences(of: "……", with: "，")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ text: String) -> String {
        text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trace(_ event: String, key: LiveTranslationRequestKey) {
        #if DEBUG
        print(
            "[LiveTranslation] event=\(event) kind=\(key.kind) "
                + "segment=\(key.segmentID) revision=\(key.revision) "
                + "audio=\(key.audioRange.start)-\(key.audioRange.end)"
        )
        #endif
    }

    private func recordFirstToken(
        requestStartedAt: Date,
        firstTokenAt: Date?
    ) {
        guard let firstTokenAt else { return }
        LiveSubtitleDiagnosticsLog.shared.translationMetrics(
            firstTokenMS: Int(
                firstTokenAt.timeIntervalSince(requestStartedAt) * 1_000
            )
        )
    }

    private func traceMetrics(
        key: LiveTranslationRequestKey,
        requestStartedAt: Date,
        firstTokenAt: Date?,
        response: StreamResponse
    ) {
        #if DEBUG
        let firstTokenMS = firstTokenAt.map {
            Int($0.timeIntervalSince(requestStartedAt) * 1_000)
        } ?? -1
        print(
            "[LiveTranslationMetrics] segment=\(key.segmentID) "
                + "firstTokenMs=\(firstTokenMS) "
                + "loadNs=\(response.loadDuration ?? 0) "
                + "promptEvalNs=\(response.promptEvalDuration ?? 0) "
                + "evalNs=\(response.evalDuration ?? 0) "
                + "promptTokens=\(response.promptEvalCount ?? 0) "
                + "outputTokens=\(response.evalCount ?? 0)"
        )
        #endif
    }

    private nonisolated static func loadModel(
        _ model: String,
        baseURL: String,
        keepAlive: String
    ) async {
        let base = OllamaEndpoint.normalizedBase(baseURL)
        guard let url = URL(string: base + "/api/generate") else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: [
                "model": model,
                "prompt": "",
                "stream": false,
                "keep_alive": keepAlive
            ]
        )
        _ = try? await URLSession.shared.data(for: request)
    }

    private nonisolated static func unloadModel(_ model: String, baseURL: String) async {
        let base = OllamaEndpoint.normalizedBase(baseURL)
        guard let url = URL(string: base + "/api/generate") else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["model": model, "keep_alive": 0]
        )
        _ = try? await URLSession.shared.data(for: request)
    }

}
