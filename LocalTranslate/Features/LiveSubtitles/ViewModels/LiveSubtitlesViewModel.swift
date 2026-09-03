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
    /// 上一条整句译文，降权显示在当前句上面。只看一句话很难接上语境。
    @Published public private(set) var previousCaptionText = ""
    @Published public var subtitleHistory: [SubtitleItem] = []
    @Published public var showHistoryDrawer = false
    @Published public var errorMessage: String?
    @Published public var fontSize: CGFloat = AppSettings.defaultLiveFontSize
    @Published public var displayLag: TimeInterval = 0
    @Published public var isCatchingUp = false
    @Published public var isPreparing = false

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

    private struct PendingCaption {
        let text: String
        let sourceText: String
        let audioEnd: TimeInterval
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

    // 字幕行的展示节奏。规则在 LiveCaptionPresenter，这里只留它需要的时刻。
    private let captionClock = ContinuousClock()
    private var lastCaptionChangeAt: ContinuousClock.Instant?
    private var lastCommitAt: ContinuousClock.Instant?
    private var pendingCaption: PendingCaption?
    private var lastCommittedCaption = ""
    /// 每次「改写」自增，View 拿它当动画身份——追加时不变，整行替换才淡入。
    @Published public private(set) var captionRewriteCount = 0

    private let previewCoalesceInterval: Duration = .milliseconds(90)
    private let catchUpCoalesceInterval: Duration = .milliseconds(50)
    private let silenceFlushInterval: TimeInterval = 0.7

    private init() {
        if let savedLanguage = UserDefaults.standard.string(
            forKey: AppSettings.Key.liveSourceLanguage
        ), let language = SubtitleSourceLanguage(rawValue: savedLanguage) {
            sourceLanguage = language
        }
        if let savedMode = UserDefaults.standard.string(
            forKey: AppSettings.Key.liveDisplayMode
        ), let mode = SubtitleDisplayMode(rawValue: savedMode) {
            displayMode = mode
        }
        let savedFontSize = CGFloat(
            UserDefaults.standard.double(
                forKey: AppSettings.Key.liveFontSize
            )
        )
        if AppSettings.liveFontSizeRange.contains(savedFontSize) {
            fontSize = savedFontSize
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
        isPreparing = true
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
                async let modelPreparation: Void = self.translationService.prepare()
                try await self.speechRecognizer.start()
                try Task.checkCancellation()
                await modelPreparation
                try Task.checkCancellation()
                try await self.audioCaptureService.startCapture()
                try Task.checkCancellation()
                guard self.isRunning,
                      self.lifecycleGeneration == generation else {
                    await self.releaseRuntimeResources()
                    return
                }
                self.isPreparing = false
            } catch is CancellationError {
                self.isPreparing = false
                await self.releaseRuntimeResources()
            } catch {
                self.errorMessage = "实时字幕启动失败：\(error.localizedDescription)"
                self.isRunning = false
                self.isPreparing = false
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
        isPreparing = false
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
        isPreparing = false
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        startTask?.cancel()
        startTask = nil
        languageChangeTask?.cancel()

        sourceLanguage = language
        UserDefaults.standard.set(
            language.rawValue,
            forKey: AppSettings.Key.liveSourceLanguage
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
            forKey: AppSettings.Key.liveDisplayMode
        )
    }

    public func adjustFontSize(delta: CGFloat) {
        let range = AppSettings.liveFontSizeRange
        let newSize = min(
            max(fontSize + delta, range.lowerBound),
            range.upperBound
        )
        fontSize = newSize
        UserDefaults.standard.set(
            Double(newSize),
            forKey: AppSettings.Key.liveFontSize
        )
    }

    public var canDecreaseFontSize: Bool {
        fontSize > AppSettings.liveFontSizeRange.lowerBound
    }

    public var canIncreaseFontSize: Bool {
        fontSize < AppSettings.liveFontSizeRange.upperBound
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

        translationService.setLiveActivity(true)
        latestRecognizedAudioEnd = max(
            latestRecognizedAudioEnd,
            update.latestAudioEnd
        )
        volatileSpans = update.volatileSpans
        windowPlanner.append(finalizedSpans: update.finalizedSpans)

        let stableWindows = windowPlanner.drain(force: false)
        submitStableWindows(stableWindows)
        flushPendingCaption()
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
                self.flushPendingCaption()
                self.translationService.setLiveActivity(false)
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

        // 整句 commit 之后要上字幕条，否则用户从头到尾只看得到滑动窗口的半句。
        // 唯一的门槛是不能倒退：`displayedAudioEnd` 会被 preview 一起推进，
        // 所以 preview 已经跑到前面时，这句旧的整句自然就不上屏了。
        guard key.audioRange.end > displayedAudioEnd + 0.2,
              !resolved.isEmpty else { return }
        presentTranslation(
            text: resolved,
            sourceText: pending.sourceText,
            audioEnd: key.audioRange.end,
            isCommitted: true
        )
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

        currentOriginalText = sourceText

        // Do not replace an in-flight request on every ASR callback. Fast
        // compatible source growth otherwise cancels Ollama just before it can
        // complete, which leaves the overlay permanently source-only.
        if currentLiveKey != nil { return }

        guard LivePreviewStabilityPolicy.isReady(
            sourceText,
            minimumWordCount: 3
        ) else { return }
        schedulePreviewSubmission()
    }

    private func schedulePreviewSubmission() {
        if lastPreviewRequestedSourceText.isEmpty {
            submitLatestPreviewIfNeeded()
            return
        }

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
            after: lastPreviewRequestedSourceText,
            minimumAddedWords: isCatchingUp ? 2 : 3
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
        let mayStreamInitialTranslation = currentTranslatedText.isEmpty

        translationService.translatePreview(
            key: key,
            sourceText,
            context: liveTranslationContext,
            sourceLanguage: sourceLanguage,
            onPartial: { [weak self] responseKey, partialText in
                guard let self,
                      mayStreamInitialTranslation,
                      responseKey == self.currentLiveKey,
                      responseKey.sessionID == self.sessionID,
                      !partialText.isEmpty else { return }
                self.presentTranslation(
                    text: partialText,
                    sourceText: sourceText,
                    audioEnd: responseKey.audioRange.end,
                    isCommitted: false
                )
            }
        ) { [weak self] responseKey, translatedText in
            guard let self,
                  responseKey == self.currentLiveKey,
                  responseKey.sessionID == self.sessionID else {
                self?.traceStaleDrop(responseKey)
                return
            }
            self.currentLiveKey = nil
            guard !translatedText.isEmpty else {
                self.traceStaleDrop(responseKey)
                self.refreshLiveSource()
                return
            }
            self.presentTranslation(
                text: translatedText,
                sourceText: sourceText,
                audioEnd: responseKey.audioRange.end,
                isCommitted: false
            )
            self.refreshLiveSource()
        }
    }

    /// preview 要翻译的那段源文本。
    ///
    /// 原先固定取最后 10 个词，是个跟着说话滑动的窗口：起点每次都在动，模型
    /// 每次拿到的都是不同的片段，于是同一句话被反复重译成不同的半截中文。
    /// 现在锚在从句边界上，一句话说完之前起点不动，译文因此能只往后长——
    /// 展示层的 `LiveCaptionPresenter` 也只有在这个前提下才有追加可走。
    ///
    /// 上界放宽到 28 个词：请求变大会让单次翻译慢一些，但重写次数下来了，
    /// 屏幕上真正发生的变化反而更少。
    private func boundedPreviewCandidate(
        maximumWords: Int = 28
    ) -> (sourceText: String, range: LiveAudioTimeRange) {
        let words = latestLiveSourceText
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
        guard words.count > maximumWords else {
            return (latestLiveSourceText, latestLiveSourceRange)
        }

        let anchored = LiveSubtitleSemanticSegmenter.previewAnchor(
            in: latestLiveSourceText,
            maximumWords: maximumWords
        )
        let anchoredWordCount = anchored
            .split(whereSeparator: \Character.isWhitespace)
            .count
        let droppedWordCount = max(words.count - anchoredWordCount, 0)
        let droppedFraction = Double(droppedWordCount) / Double(words.count)
        let adjustedStart = latestLiveSourceRange.start
            + latestLiveSourceRange.duration * droppedFraction
        return (
            anchored,
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

    /// 译文上屏的唯一入口。
    ///
    /// 「能追加就只追加、改写要隔开停留时间」这条规则不能有旁路——只要还有一处
    /// 直接写 `currentTranslatedText`，快语速下字幕就又会开始抖。被压住的那次
    /// 存进 `pendingCaption`，下一次识别回调重新评估，静音时由 flush 兜底。
    private func presentTranslation(
        text: String,
        sourceText: String,
        audioEnd: TimeInterval,
        isCommitted: Bool
    ) {
        let now = captionClock.now

        // commit 的整句要定格一会儿，否则下一句 preview 一到就把它顶掉，
        // 完整译文等于从没出现过。
        if !isCommitted, let committedAt = lastCommitAt,
           LiveCaptionPresenter.holdsCommittedCaption(
               sinceCommit: committedAt.duration(to: now)
           ) {
            pendingCaption = PendingCaption(
                text: text,
                sourceText: sourceText,
                audioEnd: audioEnd
            )
            return
        }

        let elapsed = lastCaptionChangeAt.map { $0.duration(to: now) }
            ?? .seconds(3_600)
        switch LiveCaptionPresenter.update(
            displayed: currentTranslatedText,
            incoming: text,
            sinceLastChange: elapsed
        ) {
        case .hold:
            pendingCaption = PendingCaption(
                text: text,
                sourceText: sourceText,
                audioEnd: audioEnd
            )
            return
        case .append(let value):
            currentTranslatedText = value
        case .replace(let value):
            currentTranslatedText = value
            captionRewriteCount += 1
        }

        pendingCaption = nil
        lastCaptionChangeAt = now
        if isCommitted {
            // 新的整句顶上来，上一条整句降权到上面那行。preview 的改口不算
            // 换句，不动这一行。
            previousCaptionText = lastCommittedCaption
            lastCommittedCaption = text
            lastCommitAt = now
        }
        currentOriginalText = sourceText
        displayedTranslationSourceText = sourceText
        displayedAudioEnd = max(displayedAudioEnd, audioEnd)
        refreshLagState()
    }

    /// 重新评估上一次被压住的译文。讲话时每次识别回调都会走到这里。
    private func flushPendingCaption() {
        guard let pending = pendingCaption else { return }
        pendingCaption = nil
        presentTranslation(
            text: pending.text,
            sourceText: pending.sourceText,
            audioEnd: pending.audioEnd,
            isCommitted: false
        )
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
        previousCaptionText = ""
        lastCommittedCaption = ""
        pendingCaption = nil
        lastCaptionChangeAt = nil
        lastCommitAt = nil
        displayLag = 0
        isCatchingUp = false
        isPreparing = false
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
