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

    // 音频重采样管线：将 48kHz 立体声转换为 SFSpeechRecognizer 最佳声学标准 16kHz 单声道
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    private var audioConverter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?

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

        // 重采样为 16kHz 单声道以极大增强歌曲/背景音乐环境下的人声分离识别率
        let processedBuffer = resampleAudioBuffer(buffer)
        request.append(processedBuffer)
    }

    // MARK: - Audio Resampling

    private func resampleAudioBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let targetFormat = self.targetFormat else { return buffer }

        if buffer.format == targetFormat {
            return buffer
        }

        if audioConverter == nil || cachedInputFormat != buffer.format {
            cachedInputFormat = buffer.format
            audioConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }

        guard let converter = audioConverter else { return buffer }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            return buffer
        }

        var isConsumed = false
        var error: NSError?

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !isConsumed {
                outStatus.pointee = .haveData
                isConsumed = true
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if status == .haveData || status == .inputRanDry {
            return outputBuffer
        }

        return buffer
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
        request.taskHint = .dictation

        if #available(macOS 13, *) {
            // 在歌曲和快语速场景下关闭强制标点预测，避免标点回退导致丢词卡顿
            request.addsPunctuation = false
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
