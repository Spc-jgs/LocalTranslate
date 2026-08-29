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
    @Published public var pendingCommittedOriginalText: String = ""
    @Published public var pendingCommittedTranslatedText: String = ""
    @Published public var previousItem: SubtitleItem?
    @Published public var lastCommittedItem: SubtitleItem?
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
    private var languageChangeTask: Task<Void, Never>?
    private var lifecycleGeneration = 0
    private var silenceTimer: Timer?
    private var previewCoalesceTask: Task<Void, Never>?
    private var presentationAdvanceTask: Task<Void, Never>?

    private struct PendingSegment {
        let key: LiveTranslationRequestKey
        let sourceText: String
        var partialTranslation: String
    }

    private var sessionID = UUID()
    private var committedSourceTail = ""
    private var unstableASRText = ""
    private var previewSegmentID = UUID()
    private var previewRevision = 0
    private var currentPreviewKey: LiveTranslationRequestKey?
    private var lastPreviewRequestedSourceText = ""
    private var displayedPreviewSourceText = ""
    private var pendingSegments: [UUID: PendingSegment] = [:]
    private var pendingSegmentOrder: [UUID] = []
    private var committedSegmentIDs: Set<UUID> = []
    private var presentationQueue = LiveCaptionPresentationQueue<SubtitleItem>()

    private let previewCoalesceInterval: Duration = .milliseconds(550)
    private let minimumCaptionDwell: TimeInterval = 1.2

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
        guard !isRunning,
              startTask == nil,
              languageChangeTask == nil else { return }

        resetPipelineSession()
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

        audioLevel = 0.0
        currentOriginalText = ""
        currentTranslatedText = ""

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
        UserDefaults.standard.set(language.rawValue, forKey: "liveSubtitlesSourceLanguage")

        resetPipelineSession()
        previousItem = nil
        lastCommittedItem = nil
        translationService.cancel()
        audioLevel = 0.0

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
        resetPipelineSession()
        translationService.cancel(unloadModel: false)

        withAnimation(.easeOut(duration: 0.2)) {
            previousItem = nil
            lastCommittedItem = nil
            subtitleHistory.removeAll()
            committedSegmentIDs.removeAll()
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

    public nonisolated func liveSpeechRecognizerDidRecognize(update: LiveSpeechRecognitionUpdate) {
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

    // MARK: - Private

    private func handleRecognitionUpdate(_ update: LiveSpeechRecognitionUpdate) {
        guard isRunning else { return }

        let committedDelta = LiveSubtitleSemanticSegmenter.normalize(
            update.committedDelta
        )
        unstableASRText = LiveSubtitleSemanticSegmenter.normalize(
            update.unstableText
        )

        consumeCommittedASRDelta(committedDelta)
        resetSilenceTimer()
        refreshPreview()
    }

    private func consumeCommittedASRDelta(_ committedDelta: String) {
        guard !committedDelta.isEmpty else { return }

        committedSourceTail = LiveSubtitleSemanticSegmenter.join(
            committedSourceTail,
            committedDelta
        )
        drainCommittedSegments(force: false)
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        let expectedSessionID = sessionID
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == expectedSessionID else { return }
                self.drainCommittedSegments(force: true)
                self.refreshPreview()
            }
        }
    }

    private func drainCommittedSegments(force: Bool) {
        guard isRunning else { return }

        let extraction = LiveSubtitleSemanticSegmenter.extractSegments(
            from: committedSourceTail,
            force: force
        )
        committedSourceTail = extraction.remainder

        guard !extraction.segments.isEmpty else { return }

        invalidatePreviewForCommittedBoundary()

        for segment in extraction.segments {
            enqueueCommittedSegment(segment)
        }
    }

    private func enqueueCommittedSegment(_ sourceText: String) {
        let segmentID = UUID()
        let key = LiveTranslationRequestKey(
            sessionID: sessionID,
            segmentID: segmentID,
            revision: 0,
            kind: .final
        )
        let pending = PendingSegment(
            key: key,
            sourceText: sourceText,
            partialTranslation: ""
        )
        pendingSegments[segmentID] = pending
        pendingSegmentOrder.append(segmentID)
        refreshPendingDisplayState()

        translationService.enqueueFinal(
            key: key,
            sourceText,
            context: Array(subtitleHistory.suffix(2)),
            sourceLanguage: sourceLanguage,
            onPartial: { [weak self] partialKey, translatedText in
                self?.handleFinalTranslationPartial(
                    key: partialKey,
                    translatedText: translatedText
                )
            },
            onCompletion: { [weak self] completedKey, translatedText in
                self?.handleFinalTranslation(
                    key: completedKey,
                    translatedText: translatedText
                )
            }
        )
    }

    private func handleFinalTranslationPartial(
        key: LiveTranslationRequestKey,
        translatedText: String
    ) {
        guard !translatedText.isEmpty,
              var pending = pendingSegments[key.segmentID],
              LiveTranslationIdentityGate.acceptsFinal(
                  responseKey: key,
                  pendingKey: pending.key,
                  committedSegmentIDs: committedSegmentIDs,
                  sessionID: sessionID
              ) else {
            return
        }

        guard translatedText.count >= pending.partialTranslation.count else {
            return
        }
        pending.partialTranslation = translatedText
        pendingSegments[key.segmentID] = pending
        refreshPendingDisplayState()
    }

    private func handleFinalTranslation(
        key: LiveTranslationRequestKey,
        translatedText: String
    ) {
        let pending = pendingSegments[key.segmentID]
        guard LiveTranslationIdentityGate.acceptsFinal(
            responseKey: key,
            pendingKey: pending?.key,
            committedSegmentIDs: committedSegmentIDs,
            sessionID: sessionID
        ), let pending else {
            traceStaleDrop(key)
            return
        }

        let resolvedTranslation = translatedText.isEmpty
            ? pending.partialTranslation
            : translatedText

        pendingSegments.removeValue(forKey: key.segmentID)
        pendingSegmentOrder.removeAll { $0 == key.segmentID }
        committedSegmentIDs.insert(key.segmentID)
        refreshPendingDisplayState()

        let item = SubtitleItem(
            id: key.segmentID,
            originalText: pending.sourceText,
            translatedText: resolvedTranslation,
            sourceLanguage: sourceLanguage.displayName,
            isFinal: true
        )

        subtitleHistory.append(item)
        if subtitleHistory.count > 50 {
            subtitleHistory.removeFirst(subtitleHistory.count - 50)
        }

        enqueueForPresentation(item)
    }

    private func refreshPreview() {
        let sourceText = LiveSubtitleSemanticSegmenter.join(
            committedSourceTail,
            unstableASRText
        )
        guard sourceText != currentOriginalText else { return }

        currentOriginalText = sourceText

        guard !sourceText.isEmpty else {
            invalidatePreview(clearDisplayedTranslation: true)
            return
        }

        if !lastPreviewRequestedSourceText.isEmpty,
           !sourceText.hasPrefix(lastPreviewRequestedSourceText) {
            invalidatePreview(clearDisplayedTranslation: false)
            lastPreviewRequestedSourceText = ""
        }

        if !displayedPreviewSourceText.isEmpty,
           !LivePreviewStabilityPolicy.canRetainDisplayedTranslation(
               displayedSource: displayedPreviewSourceText,
               while: sourceText
           ) {
            currentTranslatedText = ""
            displayedPreviewSourceText = ""
        }

        guard LivePreviewStabilityPolicy.isReady(sourceText) else { return }
        schedulePreviewSubmission()
    }

    private func schedulePreviewSubmission() {
        guard previewCoalesceTask == nil else { return }
        let expectedSessionID = sessionID

        previewCoalesceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.previewCoalesceInterval ?? .milliseconds(550))
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
        let sourceText = currentOriginalText
        guard LivePreviewStabilityPolicy.shouldRequest(
            candidate: sourceText,
            after: lastPreviewRequestedSourceText
        ) else {
            return
        }

        previewRevision += 1
        let key = LiveTranslationRequestKey(
            sessionID: sessionID,
            segmentID: previewSegmentID,
            revision: previewRevision,
            kind: .preview
        )
        currentPreviewKey = key
        lastPreviewRequestedSourceText = sourceText

        translationService.translatePreview(
            key: key,
            sourceText,
            context: Array(subtitleHistory.suffix(2)),
            sourceLanguage: sourceLanguage
        ) { [weak self] responseKey, translatedText in
            guard let self,
                  LiveTranslationIdentityGate.acceptsPreview(
                    responseKey: responseKey,
                    currentKey: self.currentPreviewKey,
                    sessionID: self.sessionID
                  ),
                  self.currentOriginalText.hasPrefix(sourceText) else {
                self?.traceStaleDrop(responseKey)
                return
            }
            guard !translatedText.isEmpty else { return }
            self.currentTranslatedText = translatedText
            self.displayedPreviewSourceText = sourceText
        }
    }

    private func refreshPendingDisplayState() {
        guard let firstID = pendingSegmentOrder.first,
              let pending = pendingSegments[firstID] else {
            pendingCommittedOriginalText = ""
            pendingCommittedTranslatedText = ""
            return
        }

        pendingCommittedOriginalText = pending.sourceText
        pendingCommittedTranslatedText = pending.partialTranslation
    }

    private func invalidatePreviewForCommittedBoundary() {
        invalidatePreview(clearDisplayedTranslation: true)
        previewSegmentID = UUID()
        previewRevision = 0
        lastPreviewRequestedSourceText = ""
        displayedPreviewSourceText = ""
    }

    private func invalidatePreview(clearDisplayedTranslation: Bool) {
        previewCoalesceTask?.cancel()
        previewCoalesceTask = nil
        currentPreviewKey = nil
        translationService.cancelPreview()

        if clearDisplayedTranslation {
            currentTranslatedText = ""
            displayedPreviewSourceText = ""
        }
    }

    private func enqueueForPresentation(_ item: SubtitleItem) {
        let now = Date().timeIntervalSinceReferenceDate
        if let next = presentationQueue.enqueue(
            item,
            now: now,
            minimumDwell: minimumCaptionDwell
        ) {
            present(next)
        }
        schedulePresentationAdvanceIfNeeded()
    }

    private func schedulePresentationAdvanceIfNeeded() {
        presentationAdvanceTask?.cancel()
        presentationAdvanceTask = nil

        let now = Date().timeIntervalSinceReferenceDate
        guard let delay = presentationQueue.nextDelay(
            now: now,
            minimumDwell: minimumCaptionDwell
        ) else {
            return
        }

        let expectedSessionID = sessionID
        presentationAdvanceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard let self,
                  self.sessionID == expectedSessionID else { return }
            self.presentationAdvanceTask = nil

            let currentTime = Date().timeIntervalSinceReferenceDate
            if let next = self.presentationQueue.advanceIfReady(
                now: currentTime,
                minimumDwell: self.minimumCaptionDwell
            ) {
                self.present(next)
            }
            self.schedulePresentationAdvanceIfNeeded()
        }
    }

    private func present(_ item: SubtitleItem) {
        // Caption replacement must not inherit a layout animation. Centered
        // text with a different width otherwise appears to slide sideways.
        previousItem = lastCommittedItem
        lastCommittedItem = item
    }

    private func resetPipelineSession() {
        sessionID = UUID()
        silenceTimer?.invalidate()
        silenceTimer = nil
        previewCoalesceTask?.cancel()
        previewCoalesceTask = nil
        presentationAdvanceTask?.cancel()
        presentationAdvanceTask = nil
        currentPreviewKey = nil
        previewSegmentID = UUID()
        previewRevision = 0
        lastPreviewRequestedSourceText = ""
        displayedPreviewSourceText = ""
        committedSourceTail = ""
        unstableASRText = ""
        pendingSegments.removeAll()
        pendingSegmentOrder.removeAll()
        committedSegmentIDs.removeAll()
        presentationQueue.reset()
        currentOriginalText = ""
        currentTranslatedText = ""
        pendingCommittedOriginalText = ""
        pendingCommittedTranslatedText = ""

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
