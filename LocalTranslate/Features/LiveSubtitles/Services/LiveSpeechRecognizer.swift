import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation

public protocol LiveSpeechRecognizerDelegate: AnyObject {
    nonisolated func liveSpeechRecognizerDidRecognize(text: String, isFinal: Bool)
    nonisolated func liveSpeechRecognizerDidFail(error: Error)
}

public final class LiveSpeechRecognizer: @unchecked Sendable {

    public nonisolated(unsafe) weak var delegate: LiveSpeechRecognizerDelegate?

    private nonisolated(unsafe) var engine: RecognitionEngine!

    public nonisolated init(language: SubtitleSourceLanguage = .english) {
        self.engine = RecognitionEngine(language: language) { [weak self] event in
            guard let self else { return }

            switch event {
            case let .transcription(text, isFinal):
                self.delegate?.liveSpeechRecognizerDidRecognize(text: text, isFinal: isFinal)
            case let .failure(error):
                self.delegate?.liveSpeechRecognizerDidFail(error: error)
            }
        }
    }

    public nonisolated func setLanguage(_ language: SubtitleSourceLanguage) {
        Task(priority: .userInitiated) {
            await engine.setLanguage(language)
        }
    }

    public nonisolated func start() async throws {
        try await engine.start()
    }

    public nonisolated func stop() async {
        await engine.stop()
    }

    public nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        Task(priority: .userInitiated) {
            await engine.appendAudioBuffer(buffer)
        }
    }
}

private actor RecognitionEngine {

    enum Event: @unchecked Sendable {
        case transcription(text: String, isFinal: Bool)
        case failure(error: Error)
    }

    private var currentLanguage: SubtitleSourceLanguage
    private let eventHandler: @Sendable (Event) -> Void

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var currentTranscript = AttributedString()

    private var analyzerFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var isRunning = false

    init(
        language: SubtitleSourceLanguage,
        eventHandler: @escaping @Sendable (Event) -> Void
    ) {
        self.currentLanguage = language
        self.eventHandler = eventHandler
    }

    func setLanguage(_ language: SubtitleSourceLanguage) async {
        guard language != currentLanguage else { return }
        currentLanguage = language

        guard isRunning else { return }

        await stop()
        do {
            try await start()
        } catch {
            eventHandler(.failure(error: error))
        }
    }

    func start() async throws {
        guard !isRunning else { return }

        let authorization = await speechAuthorizationStatus()
        guard authorization == .authorized else {
            throw NSError(
                domain: "LiveSpeechRecognizer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "语音识别权限未开启，请在系统设置中允许。"]
            )
        }

        guard SpeechTranscriber.isAvailable else {
            throw NSError(
                domain: "LiveSpeechRecognizer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "当前 Mac 不支持新的端侧语音识别模型。"]
            )
        }

        let requestedLocale = Locale(identifier: currentLanguage.rawValue)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw NSError(
                domain: "LiveSpeechRecognizer",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "当前端侧语音模型暂不支持所选语言。"]
            )
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .timeIndexedProgressiveTranscription
        )
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: false
        )
        let modules: [any SpeechModule] = [transcriber, detector]

        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await installationRequest.downloadAndInstall()
        }
        try Task.checkCancellation()

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw NSError(
                domain: "LiveSpeechRecognizer",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "无法为端侧语音识别创建兼容音频格式。"]
            )
        }

        let options = SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .whileInUse
        )
        let analyzer = SpeechAnalyzer(modules: modules, options: options)
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()

        let (inputStream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.inputContinuation = continuation
        self.currentTranscript = AttributedString()
        self.isRunning = true

        self.resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    await self?.consume(result)
                }
            } catch {
                await self?.emitFailureIfRunning(error)
            }
        }

        self.analysisTask = Task { [weak self] in
            do {
                _ = try await analyzer.analyzeSequence(inputStream)
            } catch {
                await self?.emitFailureIfRunning(error)
            }
        }
    }

    func stop() async {
        guard isRunning || analyzer != nil else { return }

        isRunning = false
        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }

        analysisTask?.cancel()
        resultsTask?.cancel()
        analysisTask = nil
        resultsTask = nil

        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        audioConverter = nil
        converterInputFormat = nil
        currentTranscript = AttributedString()

        await SpeechModels.endRetention()
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning,
              let continuation = inputContinuation,
              let analyzerFormat else {
            return
        }

        if formatsMatch(buffer.format, analyzerFormat) {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

        guard let convertedBuffer = convert(buffer, to: analyzerFormat) else { return }
        continuation.yield(AnalyzerInput(buffer: convertedBuffer))
    }

    private func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if audioConverter == nil || converterInputFormat != inputBuffer.format {
            converterInputFormat = inputBuffer.format
            audioConverter = AVAudioConverter(from: inputBuffer.format, to: outputFormat)
        }

        guard let audioConverter else { return nil }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(capacity, 1)
        ) else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }

            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
              status != .error,
              outputBuffer.frameLength > 0 else {
            return nil
        }

        return outputBuffer
    }

    private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private func emitTranscription(_ text: String, isFinal: Bool) {
        guard isRunning else { return }
        eventHandler(.transcription(text: text, isFinal: isFinal))
    }

    private func consume(_ result: SpeechTranscriber.Result) {
        guard isRunning else { return }

        // Progressive results revise an audio time range; they are not complete
        // replacement strings. Merge by time range as required by SpeechTranscriber.
        if let rangeToReplace = currentTranscript
            .rangeOfAudioTimeRangeAttributes(intersecting: result.range) {
            currentTranscript.replaceSubrange(rangeToReplace, with: result.text)
        } else {
            currentTranscript.append(result.text)
        }

        let text = String(currentTranscript.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        emitTranscription(text, isFinal: result.isFinal)

        // A finalized range won't be revised again. Start a fresh caption window
        // so a long-running session doesn't repeatedly resend old dialogue.
        if result.isFinal {
            currentTranscript = AttributedString()
        }
    }

    private func emitFailureIfRunning(_ error: Error) {
        guard isRunning else { return }
        eventHandler(.failure(error: error))
    }

    private func speechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        guard currentStatus == .notDetermined else { return currentStatus }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
