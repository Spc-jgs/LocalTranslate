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
    /// 当前主行译文对应的那段原文。
    ///
    /// 原文行原先跟着 `currentOriginalText` 走，那是含 volatile 的最新语音，
    /// 比译文跑得远——屏幕上会出现译文和原文对不上的两行（实测截图里主行是
    /// 「我想这就是我要说的全部内容了」，原文行却是下一句的开头）。宁可原文
    /// 也一起滞后，也不能让两行说的不是同一句。
    @Published public private(set) var displayedSourceText = ""
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
    /// 主行显示到哪一段，由字幕自己分页，不跟 planner 的切分共用边界。
    private var pager = LiveCaptionPager()
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
    /// 当前这段内容第一次出现的时刻。追加不重置，整行改写才重置——
    /// 读者从这段第一次出现就在读了，不该按最后一次追加起算。
    private var contentShownAt: ContinuousClock.Instant?
    private var lastCommitAt: ContinuousClock.Instant?
    private var pendingCaption: PendingCaption?
    private var lastCommittedCaption = ""
    private var pendingFrontRow: String?
    private var frontRowTask: Task<Void, Never>?
    /// 上一行的合并窗口。一批整句在几百毫秒内落地，只显示最后一条。
    private static let frontRowCoalesceInterval: Duration = .milliseconds(400)
    /// 节奏诊断。默认关闭，开着才创建文件、才持有句柄。
    private let diagnostics = LiveSubtitleDiagnosticsLog.shared
    private var lastAnchorSourceText = ""
    /// 每次「改写」自增，View 拿它当动画身份——追加时不变，整行替换才淡入。
    @Published public private(set) var captionRewriteCount = 0

    private let previewCoalesceInterval: Duration = .milliseconds(90)
    private let catchUpCoalesceInterval: Duration = .milliseconds(50)
    private let silenceFlushInterval: TimeInterval = 0.7
    /// 少于这个词数的整句窗口不占上一行、也不翻页。
    ///
    /// planner 的 `force` 路径（静音 flush）绕过它自己的语义判断，把剩下的词
    /// 全部打成一个窗口——实测切出过 1 词的窗口，也切出过 33 词的。一个词的
    /// 译文占住上一行没有信息量，翻页翻掉它等于把主行清空；同传研究里也早有
    /// 结论：输入太短模型只会给出错误的译文。这类窗口照常进历史，
    /// 内容留在主行，等下一个够长的窗口定稿时一并翻页。
    private static let minimumFrontRowWords = 3
    /// 合并后的窗口上界。超过就另起一组，别让一次翻页吞掉一大段。
    private static let maximumCombinedWords = 14

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
        if AppSettings.liveDiagnosticsLogEnabled { diagnostics.begin() }
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
        diagnostics.end(reason: "user-stop")
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
        let trimmedWords = pager.append(finalizedSpans: update.finalizedSpans)
        if trimmedWords > 0 { diagnostics.pageTrimmed(words: trimmedWords) }

        let stableWindows = windowPlanner.drain(force: false)
        diagnostics.plannerDrain(
            force: false,
            windows: stableWindows.count,
            pendingWords: windowPlanner.pendingSourceText
                .split(whereSeparator: \Character.isWhitespace).count
        )
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
                self.diagnostics.plannerDrain(
                    force: true,
                    windows: windows.count,
                    pendingWords: self.windowPlanner.pendingSourceText
                        .split(whereSeparator: \Character.isWhitespace).count
                )
                self.submitStableWindows(windows)
                self.flushPendingCaption()
                self.translationService.setLiveActivity(false)
                self.refreshLiveSource()
            }
        }
    }

    private func submitStableWindows(_ windows: [LiveTranslationWindow]) {
        guard !windows.isEmpty else { return }
        combineWindows(windows).forEach(submitStableWindow)
    }

    /// 一次 drain 切出的窗口按上界并成几组。
    ///
    /// 原先是全部并成一个，理由写在旧注释里——那时整句只进历史，不上字幕条，
    /// 合多大都无所谓。现在整句要驱动翻页和上一行，无上界合并就成了长尾的
    /// 制造机：实测一次静音 flush 切出 10 个窗口，合成 53 词的一个请求，
    /// 翻译慢、上一行放不下、一次翻页翻掉 53 词，主行在等它的过程中变了 10 次。
    ///
    /// 按窗口词数分组看得很清楚：5-9 词的句子平均变 0.78 次，10-14 词变 1.92 次，
    /// 15 词以上变 3.24 次。所以合并要留着（它把 1-2 词的碎窗口并掉），
    /// 但上界压在 14 词。
    private func combineWindows(
        _ windows: [LiveTranslationWindow]
    ) -> [LiveTranslationWindow] {
        var groups: [LiveTranslationWindow] = []
        var pending: LiveTranslationWindow?

        for window in windows {
            guard let current = pending else {
                pending = window
                continue
            }
            let merged = wordCount(current.sourceText)
                + wordCount(window.sourceText)
            if merged <= Self.maximumCombinedWords {
                pending = LiveTranslationWindow(
                    range: current.range.union(window.range),
                    sourceText: LiveSubtitleSemanticSegmenter.join(
                        current.sourceText,
                        window.sourceText
                    )
                )
            } else {
                groups.append(current)
                pending = window
            }
        }
        if let pending { groups.append(pending) }
        return groups
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \Character.isWhitespace).count
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
        // 主行靠这一条翻页，所以说话期间也得跑——走归档队列时它成批堆到静音
        // 才冲出来（实测相邻 segment 行号差为 2 的占一半），主行等不到。
        // 但它也不能去抢 preview 的槽位：那个槽位只有一个位子、新来的还会抢占
        // 正在跑的活，上一版这么改直接把 preview 丢没了（32 秒只上屏 1 次，
        // 延迟涨到 13.8 秒）。enqueueStable 是它自己的队列，排在 preview 之后、
        // 归档之前，谁也不抢占谁。
        translationService.enqueueStable(
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
            diagnostics.commitBlocked(
                reason: "identity",
                windowEnd: key.audioRange.end,
                displayedEnd: displayedAudioEnd
            )
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
        guard !resolved.isEmpty else {
            diagnostics.commitBlocked(
                reason: "empty",
                windowEnd: key.audioRange.end,
                displayedEnd: displayedAudioEnd
            )
            return
        }

        let windowWords = pending.sourceText
            .split(whereSeparator: \Character.isWhitespace).count
        guard windowWords >= Self.minimumFrontRowWords else {
            diagnostics.commitBlocked(
                reason: "tooShort",
                windowEnd: key.audioRange.end,
                displayedEnd: displayedAudioEnd
            )
            refreshLiveSource()
            return
        }

        // 定稿的整句先占住上面那一行。它完整、准确，而且没有必要和正在说的话
        // 抢主行。上一版把这一行绑在「能否上主行」上，而那道门槛几乎恒为假
        // （实测 65 次里挡掉 62 次），于是上一行三分半只换了三次，看着就是
        // 固定在那儿不动。
        // 整句走的是归档队列，说话期间不与 preview 抢 Ollama，静音时才成批
        // 冲出来——实测一批 2-5 条，逐条覆盖上一行就是「一下子走三四条」。
        // 批量补齐时中间那几条早就不是「上一句」了，只有最后一条才是。
        scheduleFrontRow(resolved)
        lastCommittedCaption = resolved
        // 翻页和上一行更新是同一个动作的两面：这句进了上一行，主行就从它之后
        // 重新开始。分开做的话，主行要么凭空缩水，要么把已经定稿的话又显示一遍。
        diagnostics.pageTurn(words: pager.wordCount)
        pager.turnPage(through: key.audioRange.end)
        diagnostics.segmentCommitted(
            words: pending.sourceText
                .split(whereSeparator: \Character.isWhitespace).count,
            characters: resolved.count,
            lag: displayLag
        )

        // 主行只在说话停下来时才让整句接管：讲话还在继续时，preview 已经跑到
        // 更后面，把主行拉回刚说完的那句就是倒退。
        let caughtUpToSpeech = latestRecognizedAudioEnd - key.audioRange.end
            <= silenceFlushInterval + 0.2
        guard caughtUpToSpeech else {
            diagnostics.commitBlocked(
                reason: "stillSpeaking",
                windowEnd: key.audioRange.end,
                displayedEnd: displayedAudioEnd
            )
            refreshLiveSource()
            return
        }
        guard key.audioRange.end > displayedAudioEnd + 0.2 else {
            diagnostics.commitBlocked(
                reason: "behindDisplayed",
                windowEnd: key.audioRange.end,
                displayedEnd: displayedAudioEnd
            )
            refreshLiveSource()
            return
        }
        diagnostics.commitAccepted(
            windowEnd: key.audioRange.end,
            displayedEnd: displayedAudioEnd
        )
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
        // 主行读的是自己那一页，不是 planner 还没切走的部分——planner 一切走
        // pending，后者就骤然只剩 volatile，译文跟着从 38 字缩成 6 字。
        let sourceText = LiveSubtitleSemanticSegmenter.join(
            pager.pageText,
            volatileText
        )

        var range = pager.pageRange
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

        // 只有当新的源文本确实是已翻译那段的延长时才续写；换句了就重新开始，
        // 否则会把上一句的译文接到下一句前面。
        let continuing = LivePreviewStabilityPolicy.canRetainDisplayedTranslation(
            displayedSource: displayedTranslationSourceText,
            while: sourceText
        ) ? currentTranslatedText : ""

        translationService.translatePreview(
            key: key,
            sourceText,
            continuing: continuing,
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
    /// 上界要容得下「一整页 + 还没定稿的 volatile」。页面上界是 24 词，
    /// volatile 常有十来个词，所以取 40——低于这个数就会退回按词数硬截，
    /// 锚点跟着漂，译文整段重写。请求变大让单次翻译慢一些（实测首字节
    /// 160 ms，尚有余量），但重写次数下来了，屏幕上真正发生的变化反而更少。
    private func boundedPreviewCandidate(
        maximumWords: Int = 40
    ) -> (sourceText: String, range: LiveAudioTimeRange) {
        let words = latestLiveSourceText
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
        guard words.count > maximumWords else {
            diagnostics.previewAnchor(
                held: latestLiveSourceText.hasPrefix(lastAnchorSourceText)
                    && !lastAnchorSourceText.isEmpty,
                words: words.count,
                bounded: false
            )
            lastAnchorSourceText = latestLiveSourceText
            return (latestLiveSourceText, latestLiveSourceRange)
        }

        let anchored = LiveSubtitleSemanticSegmenter.previewAnchor(
            in: latestLiveSourceText,
            maximumWords: maximumWords
        )
        let anchoredWordCount = anchored
            .split(whereSeparator: \Character.isWhitespace)
            .count
        diagnostics.previewAnchor(
            held: anchored.hasPrefix(lastAnchorSourceText)
                && !lastAnchorSourceText.isEmpty,
            words: anchoredWordCount,
            bounded: true
        )
        lastAnchorSourceText = anchored
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
            diagnostics.hold(cause: "commitHold")
            return
        }

        let shownFor = contentShownAt.map { $0.duration(to: now) }
            ?? .seconds(3_600)
        let elapsed = lastCaptionChangeAt.map { $0.duration(to: now) }
            ?? .seconds(3_600)
        switch LiveCaptionPresenter.update(
            displayed: currentTranslatedText,
            incoming: text,
            sinceContentShown: shownFor,
            // 定稿是这段话的最终形态，不受阅读门槛约束；内容没变时仍然不重绘。
            bypassHold: isCommitted
        ) {
        case .hold:
            pendingCaption = PendingCaption(
                text: text,
                sourceText: sourceText,
                audioEnd: audioEnd
            )
            diagnostics.hold(cause: "throttle")
            return
        case .append(let value):
            let common = currentTranslatedText.commonPrefix(with: value).count
            let previousLength = currentTranslatedText.count
            currentTranslatedText = value
            diagnostics.caption(
                kind: "append",
                gapMS: milliseconds(elapsed),
                length: value.count,
                previousLength: previousLength,
                commonPrefix: common,
                isCommitted: isCommitted
            )
        case .replace(let value):
            let common = currentTranslatedText.commonPrefix(with: value).count
            let previousLength = currentTranslatedText.count
            currentTranslatedText = value
            captionRewriteCount += 1
            // 换了一段内容，阅读计时重新开始；追加不动它。
            contentShownAt = now
            diagnostics.caption(
                kind: "replace",
                gapMS: milliseconds(elapsed),
                length: value.count,
                previousLength: previousLength,
                commonPrefix: common,
                isCommitted: isCommitted
            )
        }

        pendingCaption = nil
        lastCaptionChangeAt = now
        // 上一行由 handleStableCompletion 在整句定稿时直接更新，不再等它
        // 能不能上主行。这里只记定格起点。
        if isCommitted { lastCommitAt = now }
        currentOriginalText = sourceText
        displayedSourceText = sourceText
        displayedTranslationSourceText = sourceText
        displayedAudioEnd = max(displayedAudioEnd, audioEnd)
        refreshLagState()
    }

    /// 重新评估上一次被压住的译文。讲话时每次识别回调都会走到这里。
    /// 合并同一批整句对上一行的更新，只让最后一条落地。
    private func scheduleFrontRow(_ text: String) {
        pendingFrontRow = text
        guard frontRowTask == nil else { return }
        let expectedSessionID = sessionID
        frontRowTask = Task { [weak self] in
            try? await Task.sleep(for: Self.frontRowCoalesceInterval)
            guard let self,
                  self.sessionID == expectedSessionID,
                  self.isRunning else { return }
            self.frontRowTask = nil
            if let text = self.pendingFrontRow {
                self.pendingFrontRow = nil
                self.previousCaptionText = text
            }
        }
    }

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

    private func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000)
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
        pager.reset()
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
        lastAnchorSourceText = ""
        frontRowTask?.cancel()
        frontRowTask = nil
        pendingFrontRow = nil
        displayedSourceText = ""
        pendingCaption = nil
        lastCaptionChangeAt = nil
        contentShownAt = nil
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
