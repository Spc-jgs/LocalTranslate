import Foundation
import SwiftUI
import Combine
import AVFoundation

@MainActor
public final class LiveSubtitlesViewModel: ObservableObject, SystemAudioCaptureDelegate, LiveSpeechRecognizerDelegate {

    public static let shared = LiveSubtitlesViewModel()

    // MARK: - Published States

    @Published public var isRunning = false
    @Published public var sourceLanguage: SubtitleSourceLanguage = .english
    @Published public var displayMode: SubtitleDisplayMode = .bilingual
    @Published public var audioLevel: Float = 0.0
    @Published public var currentOriginalText: String = ""
    @Published public var currentTranslatedText: String = ""
    @Published public var previousItem: SubtitleItem?
    @Published public var subtitleHistory: [SubtitleItem] = []
    @Published public var showHistoryDrawer = false
    @Published public var errorMessage: String?
    @Published public var isClickThrough = false
    @Published public var fontSize: CGFloat = 20.0

    // MARK: - Services

    private let audioCaptureService = SystemAudioCaptureService.shared
    private var speechRecognizer: LiveSpeechRecognizer?
    private let translationService = LiveTranslationService.shared

    private var silenceTimer: Timer?

    private init() {
        // 读取持久化偏好
        if let savedLanguage = UserDefaults.standard.string(forKey: "liveSubtitlesSourceLanguage"),
           let lang = SubtitleSourceLanguage(rawValue: savedLanguage) {
            self.sourceLanguage = lang
        }
        if let savedMode = UserDefaults.standard.string(forKey: "liveSubtitlesDisplayMode"),
           let mode = SubtitleDisplayMode(rawValue: savedMode) {
            self.displayMode = mode
        }
        let savedFontSize = UserDefaults.standard.double(forKey: "liveSubtitlesFontSize")
        if savedFontSize >= 14 && savedFontSize <= 36 {
            self.fontSize = CGFloat(savedFontSize)
        }

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
        guard language != sourceLanguage else { return }
        self.sourceLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: "liveSubtitlesSourceLanguage")

        self.currentOriginalText = ""
        self.currentTranslatedText = ""
        self.previousItem = nil
        self.translationService.cancel()
        self.speechRecognizer?.setLanguage(language)
    }

    public func setDisplayMode(_ mode: SubtitleDisplayMode) {
        self.displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "liveSubtitlesDisplayMode")
    }

    public func adjustFontSize(delta: CGFloat) {
        let newSize = min(max(fontSize + delta, 16), 34)
        self.fontSize = newSize
        UserDefaults.standard.set(Double(newSize), forKey: "liveSubtitlesFontSize")
    }

    public func toggleHistoryDrawer() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            showHistoryDrawer.toggle()
        }
    }

    public func clearSubtitles() {
        withAnimation(.easeOut(duration: 0.2)) {
            currentOriginalText = ""
            currentTranslatedText = ""
            previousItem = nil
            subtitleHistory.removeAll()
        }
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

            // 停顿断句判定：3.5 秒静音则完成本句提交至上一句/历史
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
        let orig = currentOriginalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trans = currentTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !orig.isEmpty || !trans.isEmpty else { return }

        let item = SubtitleItem(
            originalText: orig,
            translatedText: trans.isEmpty ? orig : trans,
            sourceLanguage: sourceLanguage.displayName,
            isFinal: true
        )

        subtitleHistory.append(item)
        if subtitleHistory.count > 50 {
            subtitleHistory.removeFirst(subtitleHistory.count - 50)
        }

        // 平滑滚动：将当前句推为上一句，清空当前输入等待下一句
        withAnimation(.easeInOut(duration: 0.25)) {
            self.previousItem = item
            self.currentOriginalText = ""
            self.currentTranslatedText = ""
        }
    }
}
