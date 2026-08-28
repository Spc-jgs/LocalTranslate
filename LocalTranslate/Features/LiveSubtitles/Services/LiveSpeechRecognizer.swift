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

    private var currentLanguage: SubtitleSourceLanguage = .english
    private var lastRecognizedText: String = ""
    private var isRunning = false
    private let processingQueue = DispatchQueue(label: "com.shaopc.LocalTranslate.speechRecognizerQueue", qos: .userInitiated)

    public init(language: SubtitleSourceLanguage = .english) {
        self.currentLanguage = language
        setupRecognizer(for: language)
    }

    public func setLanguage(_ language: SubtitleSourceLanguage) {
        guard language != currentLanguage else { return }
        self.currentLanguage = language

        if isRunning {
            startRecognitionSession()
        } else {
            setupRecognizer(for: language)
        }
    }

    public func start() throws {
        guard !isRunning else { return }

        // 申请或检查语音识别授权
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        } else if status == .denied || status == .restricted {
            throw NSError(
                domain: "LiveSpeechRecognizer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "语音识别权限未开启，请在系统设置中允许。"]
            )
        }

        self.isRunning = true
        startRecognitionSession()
    }

    public func stop() {
        guard isRunning else { return }
        self.isRunning = false
        stopRecognitionSession()
    }

    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let request = self.recognitionRequest else { return }
        request.append(buffer)
    }

    // MARK: - Private Session Setup

    private func setupRecognizer(for language: SubtitleSourceLanguage) {
        let locale: Locale
        if language == .auto {
            locale = Locale(identifier: "en-US")
        } else {
            locale = Locale(identifier: language.rawValue)
        }

        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    private func startRecognitionSession() {
        stopRecognitionSession()

        setupRecognizer(for: currentLanguage)

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        self.recognitionRequest = request
        self.lastRecognizedText = ""

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self, weak request] result, error in
            guard let self else { return }

            // 严格核对回调是否属于当前活跃的 request，避免被取消的旧任务触发循环竞争
            guard self.recognitionRequest === request else { return }

            if let result {
                let transcription = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !transcription.isEmpty && transcription != self.lastRecognizedText {
                    self.lastRecognizedText = transcription
                    self.delegate?.liveSpeechRecognizerDidRecognize(text: transcription, isFinal: result.isFinal)
                }

                if result.isFinal {
                    self.restartSession()
                }
            }

            if let error {
                let nsError = error as NSError
                let silentCodes = [203, 209, 216, 1110]
                if !silentCodes.contains(nsError.code) && self.isRunning && nsError.code != 1700 {
                    self.delegate?.liveSpeechRecognizerDidFail(error: error)
                }
                if self.isRunning {
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
        processingQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.isRunning else { return }
            self.startRecognitionSession()
        }
    }
}
