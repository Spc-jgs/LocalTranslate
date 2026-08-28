import Foundation
import Speech
import AVFoundation

public protocol LiveSpeechRecognizerDelegate: AnyObject {
    func liveSpeechRecognizerDidRecognize(text: String, isFinal: Bool)
    func liveSpeechRecognizerDidFail(error: Error)
}

public final class LiveSpeechRecognizer {

    public weak var delegate: LiveSpeechRecognizerDelegate?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var currentLanguage: SubtitleSourceLanguage = .japanese
    private var lastRecognizedText: String = ""
    private var isRunning = false
    private let processingQueue = DispatchQueue(label: "com.shaopc.LocalTranslate.speechRecognizerQueue", qos: .userInitiated)

    public init(language: SubtitleSourceLanguage = .japanese) {
        self.currentLanguage = language
        setupRecognizer(for: language)
    }

    public func setLanguage(_ language: SubtitleSourceLanguage) {
        guard language != currentLanguage else { return }
        self.currentLanguage = language

        if isRunning {
            restartSession()
        } else {
            setupRecognizer(for: language)
        }
    }

    public func start() throws {
        guard !isRunning else { return }

        // 申请或检查语音识别授权
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized || status == .notDetermined else {
            throw NSError(
                domain: "LiveSpeechRecognizer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "语音识别权限未开启，请在系统设置中允许。"]
            )
        }

        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }

        startRecognitionSession()
        self.isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        stopRecognitionSession()
        self.isRunning = false
    }

    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let request = self.recognitionRequest else { return }
        request.append(buffer)
    }

    // MARK: - Private Session Setup

    private func setupRecognizer(for language: SubtitleSourceLanguage) {
        let locale: Locale
        if language == .auto {
            locale = Locale(identifier: "ja-JP") // 自动时默认首选日语，后续可支持自适应
        } else {
            locale = Locale(identifier: language.rawValue)
        }

        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    private func startRecognitionSession() {
        stopRecognitionSession()

        setupRecognizer(for: currentLanguage)

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            delegate?.liveSpeechRecognizerDidFail(
                error: NSError(
                    domain: "LiveSpeechRecognizer",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "当前语言 (\(currentLanguage.displayName)) 的离线语音识别不可用"]
                )
            )
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        // 尽可能使用端侧离线识别
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        self.recognitionRequest = request
        self.lastRecognizedText = ""

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let transcription = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !transcription.isEmpty && transcription != self.lastRecognizedText {
                    self.lastRecognizedText = transcription
                    self.delegate?.liveSpeechRecognizerDidRecognize(text: transcription, isFinal: result.isFinal)
                }

                if result.isFinal {
                    // 完成一句，自动平滑重启下一个片段会话
                    self.restartSession()
                }
            }

            if let error {
                let nsError = error as NSError
                // 忽略被主动取消的正常错误 (216 / 1110)
                if nsError.code != 216 && nsError.code != 1110 && self.isRunning {
                    self.delegate?.liveSpeechRecognizerDidFail(error: error)
                    self.restartSession()
                }
            }
        }
    }

    private func stopRecognitionSession() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
    }

    private func restartSession() {
        processingQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isRunning else { return }
            self.startRecognitionSession()
        }
    }
}
