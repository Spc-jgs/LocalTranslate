import Foundation
import SwiftUI
import Combine
import AVFoundation

@MainActor
public final class LiveSubtitlesViewModel: ObservableObject, SystemAudioCaptureDelegate, LiveSpeechRecognizerDelegate {

    public static let shared = LiveSubtitlesViewModel()

    // MARK: - Published States

    @Published public var isRunning = false
    @Published public var sourceLanguage: SubtitleSourceLanguage = .japanese
    @Published public var audioLevel: Float = 0.0
    @Published public var currentOriginalText: String = ""
    @Published public var currentTranslatedText: String = ""
    @Published public var subtitleHistory: [SubtitleItem] = []
    @Published public var errorMessage: String?
    @Published public var isClickThrough = false
    @Published public var fontSize: CGFloat = 22.0
    @Published public var showOriginalText = true

    // MARK: - Services

    private let audioCaptureService = SystemAudioCaptureService.shared
    private var speechRecognizer: LiveSpeechRecognizer?
    private let translationService = LiveTranslationService.shared

    private var silenceTimer: Timer?

    private init() {
        self.speechRecognizer = LiveSpeechRecognizer(language: sourceLanguage)
        self.audioCaptureService.delegate = self
        self.speechRecognizer?.delegate = self
    }

    // MARK: - Actions

    public func toggleRunning() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    public func start() {
        guard !isRunning else { return }
        errorMessage = nil

        do {
            speechRecognizer?.setLanguage(sourceLanguage)
            try speechRecognizer?.start()

            Task {
                do {
                    try await audioCaptureService.startCapture()
                    self.isRunning = true
                } catch {
                    self.errorMessage = "音频内录启动失败：\(error.localizedDescription)"
                    self.speechRecognizer?.stop()
                    self.isRunning = false
                }
            }
        } catch {
            self.errorMessage = error.localizedDescription
            self.isRunning = false
        }
    }

    public func stop() {
        guard isRunning else { return }

        Task {
            await audioCaptureService.stopCapture()
        }

        speechRecognizer?.stop()
        translationService.cancel()
        silenceTimer?.invalidate()
        silenceTimer = nil

        audioLevel = 0.0
        isRunning = false
    }

    public func setSourceLanguage(_ language: SubtitleSourceLanguage) {
        self.sourceLanguage = language
        speechRecognizer?.setLanguage(language)
    }

    public func clearSubtitles() {
        currentOriginalText = ""
        currentTranslatedText = ""
        subtitleHistory.removeAll()
    }

    // MARK: - SystemAudioCaptureDelegate

    public nonisolated func systemAudioCaptureDidOutput(pcmBuffer: AVAudioPCMBuffer) {
        Task { @MainActor in
            guard self.isRunning else { return }
            self.speechRecognizer?.appendAudioBuffer(pcmBuffer)
        }
    }

    public nonisolated func systemAudioCaptureAudioLevelDidChange(level: Float) {
        Task { @MainActor in
            guard self.isRunning else { return }
            // 平滑动画过渡
            self.audioLevel = self.audioLevel * 0.7 + level * 0.3
        }
    }

    public nonisolated func systemAudioCaptureDidFail(error: Error) {
        Task { @MainActor in
            self.errorMessage = "音频采集错误: \(error.localizedDescription)"
            self.stop()
        }
    }

    // MARK: - LiveSpeechRecognizerDelegate

    public nonisolated func liveSpeechRecognizerDidRecognize(text: String, isFinal: Bool) {
        Task { @MainActor in
            guard self.isRunning, !text.isEmpty else { return }

            self.currentOriginalText = text

            // 重置静音定时器 (如果 3.5s 没有新词输入，归档本句进入历史)
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.commitCurrentSubtitle()
                }
            }

            // 触发实时大模型字幕翻译
            self.translationService.translateSubtitle(
                text,
                sourceLanguage: self.sourceLanguage,
                onPartial: { [weak self] partial in
                    self?.currentTranslatedText = partial
                },
                onCompletion: { [weak self] finalResult in
                    self?.currentTranslatedText = finalResult
                    if isFinal {
                        self?.commitCurrentSubtitle()
                    }
                }
            )
        }
    }

    public nonisolated func liveSpeechRecognizerDidFail(error: Error) {
        Task { @MainActor in
            // 静默处理部分偶发断流
        }
    }

    private func commitCurrentSubtitle() {
        guard !currentOriginalText.isEmpty || !currentTranslatedText.isEmpty else { return }

        let item = SubtitleItem(
            originalText: currentOriginalText,
            translatedText: currentTranslatedText.isEmpty ? "..." : currentTranslatedText,
            sourceLanguage: sourceLanguage.displayName,
            isFinal: true
        )

        subtitleHistory.append(item)
        if subtitleHistory.count > 30 {
            subtitleHistory.removeFirst(subtitleHistory.count - 30)
        }

        // 渐隐当前字幕
        withAnimation(.easeOut(duration: 0.3)) {
            currentOriginalText = ""
            currentTranslatedText = ""
        }
    }
}
