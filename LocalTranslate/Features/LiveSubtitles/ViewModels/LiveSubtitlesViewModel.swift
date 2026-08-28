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
    private nonisolated(unsafe) var speechRecognizer: LiveSpeechRecognizer!
    private let translationService = LiveTranslationService.shared

    private var startTask: Task<Void, Never>?
    private var lifecycleGeneration = 0

    private init() {
        if let savedLanguage = UserDefaults.standard.string(forKey: "liveSubtitlesSourceLanguage"),
           let language = SubtitleSourceLanguage(rawValue: savedLanguage) {
            self.sourceLanguage = language
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
        self.speechRecognizer.delegate = self
    }

    // MARK: - Actions

    public func toggleRunning() {
        isRunning ? stop() : start()
    }

    public func start() {
        guard !isRunning, startTask == nil else { return }

        errorMessage = nil
        isRunning = true
        lifecycleGeneration += 1
        let generation = lifecycleGeneration

        startTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.lifecycleGeneration == generation {
                    self.startTask = nil
                }
            }

            do {
                try await self.speechRecognizer.start()
                try Task.checkCancellation()
                try await self.audioCaptureService.startCapture()
                try Task.checkCancellation()

                guard self.isRunning, self.lifecycleGeneration == generation else {
                    await self.releaseRuntimeResources()
                    return
                }
            } catch is CancellationError {
                await self.releaseRuntimeResources()
            } catch {
                self.errorMessage = "实时字幕启动失败：\(error.localizedDescription)"
                self.isRunning = false
                await self.releaseRuntimeResources()
            }
        }
    }

    public func stop() {
        guard isRunning || startTask != nil else { return }

        isRunning = false
        lifecycleGeneration += 1
        startTask?.cancel()
        startTask = nil
        translationService.cancel()

        audioLevel = 0.0
        currentOriginalText = ""
        currentTranslatedText = ""

        Task { [weak self] in
            await self?.releaseRuntimeResources()
        }
    }

    public func setSourceLanguage(_ language: SubtitleSourceLanguage) {
        guard language != sourceLanguage else { return }

        sourceLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: "liveSubtitlesSourceLanguage")

        currentOriginalText = ""
        currentTranslatedText = ""
        previousItem = nil
        translationService.cancel()
        speechRecognizer.setLanguage(language)
    }

    public func setDisplayMode(_ mode: SubtitleDisplayMode) {
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "liveSubtitlesDisplayMode")
    }

    public func adjustFontSize(delta: CGFloat) {
        let newSize = min(max(fontSize + delta, 16), 34)
        fontSize = newSize
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
        speechRecognizer.appendAudioBuffer(pcmBuffer)
    }

    public nonisolated func systemAudioCaptureAudioLevelDidChange(level: Float) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.audioLevel = self.audioLevel * 0.7 + level * 0.3
        }
    }

    public nonisolated func systemAudioCaptureDidFail(error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.errorMessage = "音频采集错误：\(error.localizedDescription)"
            self.stop()
        }
    }

    // MARK: - LiveSpeechRecognizerDelegate

    public nonisolated func liveSpeechRecognizerDidRecognize(text: String, isFinal: Bool) {
        Task { @MainActor [weak self] in
            self?.handleTranscription(text: text, isFinal: isFinal)
        }
    }

    public nonisolated func liveSpeechRecognizerDidFail(error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.errorMessage = "端侧语音识别错误：\(error.localizedDescription)"
            self.stop()
        }
    }

    // MARK: - Private

    private func handleTranscription(text: String, isFinal: Bool) {
        guard isRunning else { return }

        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        if isFinal {
            currentOriginalText = ""
            currentTranslatedText = ""

            translationService.enqueueFinal(
                sourceText,
                sourceLanguage: sourceLanguage
            ) { [weak self] translatedText in
                self?.commitFinalSubtitle(
                    originalText: sourceText,
                    translatedText: translatedText
                )
            }
            return
        }

        let liveText = liveCaptionWindow(sourceText)
        guard liveText != currentOriginalText else { return }

        currentOriginalText = liveText
        translationService.translatePreview(
            liveText,
            sourceLanguage: sourceLanguage
        ) { [weak self] translatedText in
            // Keep the latest completed stream visible while ASR continues to
            // revise the next snapshot; never blank subtitles during long speech.
            self?.currentTranslatedText = translatedText
        }
    }

    private func liveCaptionWindow(_ text: String) -> String {
        let words = text.split(whereSeparator: \Character.isWhitespace)
        if words.count > 32 {
            return words.suffix(32).joined(separator: " ")
        }

        guard text.count > 240 else { return text }
        return String(text.suffix(240))
    }

    private func commitFinalSubtitle(
        originalText: String,
        translatedText: String
    ) {
        let item = SubtitleItem(
            originalText: originalText,
            translatedText: translatedText.isEmpty ? originalText : translatedText,
            sourceLanguage: sourceLanguage.displayName,
            isFinal: true
        )

        subtitleHistory.append(item)
        if subtitleHistory.count > 50 {
            subtitleHistory.removeFirst(subtitleHistory.count - 50)
        }

        withAnimation(.easeInOut(duration: 0.22)) {
            previousItem = item
        }
    }

    private func releaseRuntimeResources() async {
        await audioCaptureService.stopCapture()
        await speechRecognizer.stop()
    }
}
