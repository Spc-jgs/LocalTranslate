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
    private var lastRequestedTranslationText: String = ""

    private init() {
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
        self.lastRequestedTranslationText = ""
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
            lastRequestedTranslationText = ""
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

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            // 1. 检查是否存在自然语义断句（标点、连词、字数超限）
            if let (chunk, remainder) = self.findNaturalBoundary(in: trimmed) {
                // 将上一完整语义块归档为上一句
                self.commitChunk(chunk)
                // 剩余部分作为当前句继续识别
                self.currentOriginalText = remainder
                self.requestTranslation(for: remainder, force: true)
                return
            }

            self.currentOriginalText = trimmed

            // 2. 停顿断句判定：1.4 秒无声视为正常说话停顿，完成本句提交
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.commitCurrentSubtitle()
                }
            }

            // 3. 智能翻译节流：每增加 2 个词或遇到标点时才触发翻译，消除高频跳字频闪
            let shouldTranslate = isFinal || self.shouldTriggerTranslation(newText: trimmed)
            if shouldTranslate {
                self.requestTranslation(for: trimmed, force: isFinal)
            }
        }
    }

    public nonisolated func liveSpeechRecognizerDidFail(error: Error) {
        Task { @MainActor in
            // 静默处理部分偶发断流
        }
    }

    // MARK: - Private Translation & Boundary Logic

    private func shouldTriggerTranslation(newText: String) -> Bool {
        guard !newText.isEmpty else { return false }
        if lastRequestedTranslationText.isEmpty { return true }

        let oldWords = lastRequestedTranslationText.split(separator: " ").count
        let newWords = newText.split(separator: " ").count

        // 单词数增加 2 个及以上，或者新增了标点符号
        if newWords - oldWords >= 2 || newText.hasSuffix(".") || newText.hasSuffix(",") || newText.hasSuffix("?") || newText.hasSuffix("!") {
            return true
        }

        return false
    }

    private func requestTranslation(for text: String, force: Bool) {
        self.lastRequestedTranslationText = text

        self.translationService.translateSubtitle(
            text,
            sourceLanguage: self.sourceLanguage,
            onPartial: { [weak self] partial in
                self?.currentTranslatedText = partial
            },
            onCompletion: { [weak self] finalResult in
                self?.currentTranslatedText = finalResult
                if force {
                    self?.commitCurrentSubtitle()
                }
            }
        )
    }

    private func findNaturalBoundary(in text: String) -> (chunk: String, remainder: String)? {
        // 1. 检查标点断句 (句号、问号、感叹号)
        let sentenceEnds = [". ", "? ", "! ", "。 ", "？ ", "！ "]
        for end in sentenceEnds {
            if let range = text.range(of: end) {
                let chunk = String(text[..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let remainder = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty {
                    return (chunk, remainder)
                }
            }
        }

        // 2. 检查逗号长句断句 (逗号且前面达到 6 个词以上)
        let commaEnds = [", ", "， "]
        for comma in commaEnds {
            if let range = text.range(of: comma) {
                let chunk = String(text[..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let remainder = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let words = chunk.split(separator: " ")
                if words.count >= 6 && !remainder.isEmpty {
                    return (chunk, remainder)
                }
            }
        }

        // 3. 检查语义连接词长句自然切分 (达到 8~12 词时在连词处断句)
        let words = text.split(separator: " ")
        guard words.count >= 10 else { return nil }

        let conjunctions = ["whether", "that", "which", "and", "but", "because", "so", "when", "where", "if", "while"]
        for i in (7..<min(13, words.count)).reversed() {
            let word = String(words[i]).lowercased().trimmingCharacters(in: .punctuationCharacters)
            if conjunctions.contains(word) {
                let chunk = words[0..<i].joined(separator: " ")
                let remainder = words[i..<words.count].joined(separator: " ")
                return (chunk, remainder)
            }
        }

        // 4. 极端超长句强制保底截断 (超过 13 词截取前 9 词)
        if words.count >= 14 {
            let chunk = words[0..<9].joined(separator: " ")
            let remainder = words[9..<words.count].joined(separator: " ")
            return (chunk, remainder)
        }

        return nil
    }

    private func commitChunk(_ chunk: String) {
        let trans = currentTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = SubtitleItem(
            originalText: chunk,
            translatedText: trans.isEmpty ? chunk : trans,
            sourceLanguage: sourceLanguage.displayName,
            isFinal: true
        )

        subtitleHistory.append(item)
        if subtitleHistory.count > 50 {
            subtitleHistory.removeFirst(subtitleHistory.count - 50)
        }

        withAnimation(.easeInOut(duration: 0.22)) {
            self.previousItem = item
            self.currentTranslatedText = ""
            self.lastRequestedTranslationText = ""
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

        withAnimation(.easeInOut(duration: 0.22)) {
            self.previousItem = item
            self.currentOriginalText = ""
            self.currentTranslatedText = ""
            self.lastRequestedTranslationText = ""
        }
    }
}
