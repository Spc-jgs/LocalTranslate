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
        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        } else if status == .denied || status == .restricted {
            throw NSError(
                domain: "LiveSpeechRecognizer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "语音识别权限未开启，请在系统设置中允许。"]
            )
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
            locale = Locale(identifier: "ja-JP") // 自动时默认首选日语
        } else {
            locale = Locale(identifier: language.rawValue)
        }

        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    private func startRecognitionSession() {
        stopRecognitionSession()

        setupRecognizer(for: currentLanguage)

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            // 如果某语种离线引擎暂不可用，记录日志并不阻塞主流程
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

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
                    self.restartSession()
                }
            }

            if let error {
                let nsError = error as NSError
                // 忽略正常静默/无声/超时断连错误码 (203: Timeout, 209: No speech, 216: Cancel, 1110: Audio silence)
                let silentCodes = [203, 209, 216, 1110]
                if !silentCodes.contains(nsError.code) && self.isRunning {
                    // 仅真实异常时抛出
                    if nsError.code != 1700 {
                        self.delegate?.liveSpeechRecognizerDidFail(error: error)
                    }
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
        processingQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.isRunning else { return }
            self.startRecognitionSession()
        }
    }
}
