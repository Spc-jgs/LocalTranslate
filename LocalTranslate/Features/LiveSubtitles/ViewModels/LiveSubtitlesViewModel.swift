import Foundation
import SwiftUI
import Combine
import AVFoundation

@MainActor
public final class LiveSubtitlesViewModel: ObservableObject,
    SystemAudioCaptureDelegate,
    LiveSpeechRecognizerDelegate {

    public static let shared = LiveSubtitlesViewModel()

    @Published public var isRunning = false
    @Published public var sourceLanguage: SubtitleSourceLanguage = .english
    @Published public var displayMode: SubtitleDisplayMode = .bilingual
    @Published public var audioLevel: Float = 0
    @Published public var currentOriginalText = ""
    @Published public var currentTranslatedText = ""
    @Published public var subtitleHistory: [SubtitleItem] = []
    @Published public var showHistoryDrawer = false
    @Published public var errorMessage: String?
    @Published public var isClickThrough = false
    @Published public var fontSize: CGFloat = 26
    @Published public var displayLag: TimeInterval = 0
    @Published public var isCatchingUp = false

    private let audioCaptureService = SystemAudioCaptureService.shared
    private nonisolated(unsafe) var speechRecognizer: LiveSpeechRecognizer!
    private let translationService = LiveTranslationService.shared

    private var startTask: Task<Void, Never>?
    private var languageChangeTask: Task<Void, Never>?
    private var lifecycleGeneration = 0
    private var silenceTimer: Timer?
    private var previewCoalesceTask: Task<Void, Never>?

    private struct PendingStableWindow {
        let key: LiveTranslationRequestKey
        let sourceText: String
    }

    private var sessionID = UUID()
    private var windowPlanner = LiveTranslationWindowPlanner()
    private var volatileSpans: [LiveTranscriptSpan] = []
    private var pendingStableWindows: [UUID: PendingStableWindow] = [:]
    private var completedSegmentIDs: Set<UUID> = []
    private var historyAudioStarts: [UUID: TimeInterval] = [:]

    private var currentLiveKey: LiveTranslationRequestKey?
    private var previewSegmentID = UUID()
    private var previewRevision = 0
    private var lastPreviewRequestedSourceText = ""
    private var displayedTranslationSourceText = ""
    private var latestLiveSourceText = ""
    private var latestLiveSourceRange: LiveAudioTimeRange = .zero
    private var latestRecognizedAudioEnd: TimeInterval = 0
    private var displayedAudioEnd: TimeInterval = 0

    private let previewCoalesceInterval: Duration = .milliseconds(160)
    private let catchUpCoalesceInterval: Duration = .milliseconds(80)
    private let silenceFlushInterval: TimeInterval = 0.7

    private init() {
        if let savedLanguage = UserDefaults.standard.string(
            forKey: "liveSubtitlesSourceLanguage"
        ), let language = SubtitleSourceLanguage(rawValue: savedLanguage) {
            sourceLanguage = language
        }
        if let savedMode = UserDefaults.standard.string(
            forKey: "liveSubtitlesDisplayMode"
        ), let mode = SubtitleDisplayMode(rawValue: savedMode) {
            displayMode = mode
        }
        let savedFontSize = UserDefaults.standard.double(
            forKey: "liveSubtitlesFontSize"
        )
        if savedFontSize >= 16, savedFontSize <= 34 {
            fontSize = CGFloat(savedFontSize)
        }

        speechRecognizer = LiveSpeechRecognizer(language: sourceLanguage)
        audioCaptureService.delegate = self
        speechRecognizer.delegate = self
    }

    // MARK: - Actions

    public func toggleRunning() {
        isRunning ? stop() : start()
    }

    public func start() {
        guard !isRunning,
              startTask == nil,
              languageChangeTask == nil else { return }

        resetPipelineSession()
        errorMessage = nil
        isRunning = true
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        translationService.prepare()

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
                guard self.isRunning,
                      self.lifecycleGeneration == generation else {
                    await self.releaseRuntimeResources()
                    return
                }
            } catch is CancellationError {
                await self.releaseRuntimeResources()
            } catch {
                self.errorMessage = "实时字幕启动失败：\(error.localizedDescription)"
                self.isRunning = false
                self.translationService.cancel()
                await self.releaseRuntimeResources()
            }
        }
    }

    public func stop() {
        guard isRunning || startTask != nil || languageChangeTask != nil else {
            return
        }

        isRunning = false
        lifecycleGeneration += 1
        startTask?.cancel()
        startTask = nil
        languageChangeTask?.cancel()
        languageChangeTask = nil
        resetPipelineSession()
        translationService.cancel()
        audioLevel = 0

        Task { [weak self] in
            await self?.releaseRuntimeResources()
        }
    }

    public func setSourceLanguage(_ language: SubtitleSourceLanguage) {
        guard language != sourceLanguage else { return }

        let shouldRestart = isRunning || startTask != nil
        isRunning = false
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        startTask?.cancel()
        startTask = nil
        languageChangeTask?.cancel()

        sourceLanguage = language
        UserDefaults.standard.set(
            language.rawValue,
            forKey: "liveSubtitlesSourceLanguage"
        )
        resetPipelineSession()
        translationService.cancel()
        audioLevel = 0

        languageChangeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.lifecycleGeneration == generation {
                    self.languageChangeTask = nil
                }
            }

            await self.releaseRuntimeResources()
            guard !Task.isCancelled,
                  self.lifecycleGeneration == generation else { return }
            await self.speechRecognizer.setLanguage(language)
            guard !Task.isCancelled,
                  self.lifecycleGeneration == generation else { return }

            self.languageChangeTask = nil
            if shouldRestart {
                self.start()
            }
        }
    }

    public func setDisplayMode(_ mode: SubtitleDisplayMode) {
        displayMode = mode
        UserDefaults.standard.set(
            mode.rawValue,
            forKey: "liveSubtitlesDisplayMode"
        )
    }

    public func adjustFontSize(delta: CGFloat) {
        let newSize = min(max(fontSize + delta, 16), 34)
        fontSize = newSize
        UserDefaults.standard.set(
            Double(newSize),
            forKey: "liveSubtitlesFontSize"
        )
    }

    public func toggleHistoryDrawer() {
        showHistoryDrawer.toggle()
    }

    public func clearSubtitles() {
        resetPipelineSession()
        translationService.cancel(unloadModel: false)
        subtitleHistory.removeAll()
        completedSegmentIDs.removeAll()
        historyAudioStarts.removeAll()
    }

    // MARK: - Audio capture

    public nonisolated func systemAudioCaptureDidOutput(
        pcmBuffer: AVAudioPCMBuffer
    ) {
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

    // MARK: - Speech recognition

    public nonisolated func liveSpeechRecognizerDidRecognize(
        update: LiveSpeechRecognitionUpdate
    ) {
        Task { @MainActor [weak self] in
            self?.handleRecognitionUpdate(update)
        }
    }

    public nonisolated func liveSpeechRecognizerDidFail(error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.errorMessage = "端侧语音识别错误：\(error.localizedDescription)"
            self.stop()
        }
    }

    // MARK: - Pipeline

    private func handleRecognitionUpdate(_ update: LiveSpeechRecognitionUpdate) {
        guard isRunning else { return }

        latestRecognizedAudioEnd = max(
            latestRecognizedAudioEnd,
            update.latestAudioEnd
        )
        volatileSpans = update.volatileSpans
        windowPlanner.append(finalizedSpans: update.finalizedSpans)

        let stableWindows = windowPlanner.drain(force: false)
        submitStableWindows(stableWindows)
        refreshLagState()
        refreshLiveSource()
        resetSilenceTimer()
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        let expectedSessionID = sessionID
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: silenceFlushInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.sessionID == expectedSessionID,
                      self.isRunning else { return }
                let windows = self.windowPlanner.drain(force: true)
                self.submitStableWindows(windows)
                self.refreshLiveSource()
            }
        }
    }

    private func submitStableWindows(_ windows: [LiveTranslationWindow]) {
        guard !windows.isEmpty else { return }
        // Finalized ranges own immutable history, not the live overlay. Making
        // them foreground work puts Apple finalization latency directly in the
        // user's reading path.
        submitStableWindow(combineWindows(windows))
    }

    private func combineWindows(
        _ windows: [LiveTranslationWindow]
    ) -> LiveTranslationWindow {
        guard let first = windows.first else {
            return LiveTranslationWindow(range: .zero, sourceText: "")
        }
        return windows.dropFirst().reduce(first) { combined, next in
            LiveTranslationWindow(
                range: combined.range.union(next.range),
                sourceText: LiveSubtitleSemanticSegmenter.join(
                    combined.sourceText,
                    next.sourceText
                )
            )
        }
    }

    private func submitStableWindow(
        _ window: LiveTranslationWindow
    ) {
        guard !window.sourceText.isEmpty else { return }
        let key = LiveTranslationRequestKey(
            sessionID: sessionID,
            segmentID: window.id,
            revision: 0,
            kind: .final,
            audioRange: window.range
        )
        pendingStableWindows[key.segmentID] = PendingStableWindow(
            key: key,
            sourceText: window.sourceText
        )
        translationService.enqueueArchive(
            key: key,
            window.sourceText,
            context: Array(subtitleHistory.suffix(1)),
            sourceLanguage: sourceLanguage
        ) { [weak self] responseKey, translatedText in
            self?.handleStableCompletion(
                key: responseKey,
                translatedText: translatedText
            )
        }
    }

    private func handleStableCompletion(
        key: LiveTranslationRequestKey,
        translatedText: String
    ) {
        guard key.sessionID == sessionID,
              let pending = pendingStableWindows[key.segmentID],
              pending.key == key,
              !completedSegmentIDs.contains(key.segmentID) else {
            traceStaleDrop(key)
            return
        }

        pendingStableWindows.removeValue(forKey: key.segmentID)
        completedSegmentIDs.insert(key.segmentID)
        let resolved = translatedText
        let item = SubtitleItem(
            id: key.segmentID,
            originalText: pending.sourceText,
            translatedText: resolved,
            sourceLanguage: sourceLanguage.displayName,
            isFinal: true
        )
        historyAudioStarts[item.id] = key.audioRange.start
        subtitleHistory.append(item)
        subtitleHistory.sort {
            historyAudioStarts[$0.id, default: 0]
                < historyAudioStarts[$1.id, default: 0]
        }
        if subtitleHistory.count > 50 {
            let removed = subtitleHistory.prefix(subtitleHistory.count - 50)
            removed.forEach { historyAudioStarts.removeValue(forKey: $0.id) }
            subtitleHistory.removeFirst(subtitleHistory.count - 50)
        }

        // A final result is allowed to seed/advance the overlay only when it
        // has caught up to the latest heard audio and no equal-or-newer live
        // preview is already displayed. During continuous speech it remains
        // history-only.
        let caughtUpToSpeech = latestRecognizedAudioEnd - key.audioRange.end
            <= silenceFlushInterval + 0.2
        guard currentLiveKey == nil,
              caughtUpToSpeech,
              key.audioRange.end > displayedAudioEnd + 0.2,
              !resolved.isEmpty else { return }
        currentOriginalText = pending.sourceText
        currentTranslatedText = resolved
        displayedTranslationSourceText = pending.sourceText
        displayedAudioEnd = max(displayedAudioEnd, key.audioRange.end)
        refreshLagState()
        refreshLiveSource()
    }

    private func refreshLiveSource() {
        let volatileText = volatileSpans
            .sorted { $0.range.start < $1.range.start }
            .map(\.text)
            .joined(separator: " ")
        let sourceText = LiveSubtitleSemanticSegmenter.join(
            windowPlanner.pendingSourceText,
            volatileText
        )

        var range = windowPlanner.pendingRange
        for span in volatileSpans {
            range = range.map { $0.union(span.range) } ?? span.range
        }

        guard !sourceText.isEmpty, let range else { return }
        latestLiveSourceText = sourceText
        latestLiveSourceRange = range

        if currentTranslatedText.isEmpty {
            currentOriginalText = sourceText
        }

        // Do not replace an in-flight request on every ASR callback. Fast
        // compatible source growth otherwise cancels Ollama just before it can
        // complete, which leaves the overlay permanently source-only.
        if currentLiveKey != nil { return }

        guard LivePreviewStabilityPolicy.isReady(sourceText) else { return }
        schedulePreviewSubmission()
    }

    private func schedulePreviewSubmission() {
        // Throttle to the first eligible callback and translate the newest
        // snapshot when the timer fires. Debouncing every 50-100 ms ASR update
        // would postpone translation indefinitely during fast speech.
        guard previewCoalesceTask == nil else { return }
        let expectedSessionID = sessionID
        let interval = isCatchingUp
            ? catchUpCoalesceInterval
            : previewCoalesceInterval

        previewCoalesceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard let self,
                  self.sessionID == expectedSessionID,
                  self.isRunning else { return }
            self.previewCoalesceTask = nil
            self.submitLatestPreviewIfNeeded()
        }
    }

    private func submitLatestPreviewIfNeeded() {
        let preview = boundedPreviewCandidate()
        let sourceText = preview.sourceText
        let sourceRange = preview.range
        guard !sourceText.isEmpty,
              currentLiveKey == nil else { return }
        guard LivePreviewStabilityPolicy.shouldRequest(
            candidate: sourceText,
            after: lastPreviewRequestedSourceText
        ) else { return }

        previewRevision += 1
        let key = LiveTranslationRequestKey(
            sessionID: sessionID,
            segmentID: previewSegmentID,
            revision: previewRevision,
            kind: .preview,
            audioRange: sourceRange
        )
        currentLiveKey = key
        lastPreviewRequestedSourceText = sourceText

        translationService.translatePreview(
            key: key,
            sourceText,
            context: liveTranslationContext,
            sourceLanguage: sourceLanguage
        ) { [weak self] responseKey, translatedText in
            guard let self,
                  responseKey == self.currentLiveKey,
                  responseKey.sessionID == self.sessionID else {
                self?.traceStaleDrop(responseKey)
                return
            }
            self.currentLiveKey = nil
            let responseLag = self.latestRecognizedAudioEnd
                - responseKey.audioRange.end
            guard responseLag <= 2.5,
                  !translatedText.isEmpty else {
                self.traceStaleDrop(responseKey)
                self.refreshLiveSource()
                return
            }
            self.currentOriginalText = sourceText
            self.currentTranslatedText = translatedText
            self.displayedTranslationSourceText = sourceText
            self.displayedAudioEnd = max(
                self.displayedAudioEnd,
                responseKey.audioRange.end
            )
            self.refreshLagState()
            self.refreshLiveSource()
        }
    }

    private func boundedPreviewCandidate(
        maximumWords: Int = 14
    ) -> (sourceText: String, range: LiveAudioTimeRange) {
        let words = latestLiveSourceText
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
        guard words.count > maximumWords else {
            return (latestLiveSourceText, latestLiveSourceRange)
        }

        let droppedWordCount = words.count - maximumWords
        let droppedFraction = Double(droppedWordCount) / Double(words.count)
        let adjustedStart = latestLiveSourceRange.start
            + latestLiveSourceRange.duration * droppedFraction
        return (
            words.suffix(maximumWords).joined(separator: " "),
            LiveAudioTimeRange(
                start: adjustedStart,
                duration: max(latestLiveSourceRange.end - adjustedStart, 0)
            )
        )
    }

    private var liveTranslationContext: [SubtitleItem] {
        if !displayedTranslationSourceText.isEmpty,
           !currentTranslatedText.isEmpty {
            return [
                SubtitleItem(
                    originalText: displayedTranslationSourceText,
                    translatedText: currentTranslatedText,
                    sourceLanguage: sourceLanguage.displayName,
                    isFinal: false
                )
            ]
        }
        return Array(subtitleHistory.suffix(1))
    }

    private func refreshLagState() {
        displayLag = max(latestRecognizedAudioEnd - displayedAudioEnd, 0)
        isCatchingUp = displayLag > 1.5
    }

    private func resetPipelineSession() {
        sessionID = UUID()
        silenceTimer?.invalidate()
        silenceTimer = nil
        previewCoalesceTask?.cancel()
        previewCoalesceTask = nil
        windowPlanner.reset()
        volatileSpans.removeAll(keepingCapacity: false)
        pendingStableWindows.removeAll(keepingCapacity: false)
        completedSegmentIDs.removeAll(keepingCapacity: false)
        currentLiveKey = nil
        previewSegmentID = UUID()
        previewRevision = 0
        lastPreviewRequestedSourceText = ""
        displayedTranslationSourceText = ""
        latestLiveSourceText = ""
        latestLiveSourceRange = .zero
        latestRecognizedAudioEnd = 0
        displayedAudioEnd = 0
        currentOriginalText = ""
        currentTranslatedText = ""
        displayLag = 0
        isCatchingUp = false
    }

    private func traceStaleDrop(_ key: LiveTranslationRequestKey) {
        #if DEBUG
        print(
            "[LiveTranslation] stale-drop kind=\(key.kind) "
                + "segment=\(key.segmentID) revision=\(key.revision)"
        )
        #endif
    }

    private func releaseRuntimeResources() async {
        await audioCaptureService.stopCapture()
        await speechRecognizer.stop()
    }
}
