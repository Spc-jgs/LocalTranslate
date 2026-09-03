import Foundation

public struct LiveAudioTimeRange: Hashable, Sendable {
    public let start: TimeInterval
    public let duration: TimeInterval

    public nonisolated var end: TimeInterval { start + duration }

    public static let zero = LiveAudioTimeRange(start: 0, duration: 0)

    public nonisolated init(start: TimeInterval, duration: TimeInterval) {
        self.start = start.isFinite ? max(start, 0) : 0
        self.duration = duration.isFinite ? max(duration, 0) : 0
    }

    public nonisolated func intersects(_ other: LiveAudioTimeRange) -> Bool {
        start < other.end && other.start < end
    }

    public nonisolated func union(_ other: LiveAudioTimeRange) -> LiveAudioTimeRange {
        guard duration > 0 else { return other }
        guard other.duration > 0 else { return self }
        let lower = min(start, other.start)
        let upper = max(end, other.end)
        return LiveAudioTimeRange(start: lower, duration: upper - lower)
    }
}

public struct LiveTranscriptSpan: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case volatile
        case finalized
    }

    public let id: UUID
    public let range: LiveAudioTimeRange
    public let text: String
    public let revision: Int
    public let state: State

    public nonisolated init(
        id: UUID = UUID(),
        range: LiveAudioTimeRange,
        text: String,
        revision: Int = 0,
        state: State
    ) {
        self.id = id
        self.range = range
        self.text = text
        self.revision = revision
        self.state = state
    }

    public nonisolated var isFinalized: Bool {
        if case .finalized = state { return true }
        return false
    }

    public nonisolated var isVolatile: Bool {
        if case .volatile = state { return true }
        return false
    }
}

public struct LiveSpeechRecognitionUpdate: Sendable, Equatable {
    /// Spans crossing the Apple finalization frontier for the first time.
    public let finalizedSpans: [LiveTranscriptSpan]
    /// Full replaceable snapshot that remains after range reconciliation.
    public let volatileSpans: [LiveTranscriptSpan]
    public let finalizedThrough: TimeInterval
    public let latestAudioEnd: TimeInterval

    public nonisolated init(
        finalizedSpans: [LiveTranscriptSpan],
        volatileSpans: [LiveTranscriptSpan],
        finalizedThrough: TimeInterval,
        latestAudioEnd: TimeInterval
    ) {
        self.finalizedSpans = finalizedSpans
        self.volatileSpans = volatileSpans
        self.finalizedThrough = finalizedThrough
        self.latestAudioEnd = latestAudioEnd
    }

    public nonisolated var volatileText: String {
        volatileSpans
            .sorted { $0.range.start < $1.range.start }
            .map(\.text)
            .joined(separator: " ")
    }
}

struct LiveTranscriptFragment: Sendable {
    let text: String
    let range: LiveAudioTimeRange
    let isFinal: Bool
}

struct LiveTranscriptSpanLedger: Sendable {
    private(set) var spans: [LiveTranscriptSpan] = []
    private var emittedFinalizedIDs: Set<UUID> = []
    private var latestAudioEnd: TimeInterval = 0

    nonisolated init() {}

    nonisolated mutating func apply(
        text: String,
        range: LiveAudioTimeRange,
        isFinal: Bool,
        finalizedThrough: TimeInterval
    ) -> LiveSpeechRecognitionUpdate {
        apply(
            fragments: [
                LiveTranscriptFragment(
                    text: text,
                    range: range,
                    isFinal: isFinal
                )
            ],
            finalizedThrough: finalizedThrough
        )
    }

    nonisolated mutating func apply(
        fragments: [LiveTranscriptFragment],
        finalizedThrough: TimeInterval
    ) -> LiveSpeechRecognitionUpdate {
        let incoming = fragments
            .filter { $0.range.duration > 0 }
            .sorted { $0.range.start < $1.range.start }
        for fragment in incoming {
            latestAudioEnd = max(latestAudioEnd, fragment.range.end)
        }

        let previousSpans = spans
        let replacementRanges = incoming.map(\.range)
        spans.removeAll { span in
            span.isVolatile
                && replacementRanges.contains(where: span.range.intersects)
        }

        var claimedIdentities: Set<UUID> = []
        for fragment in incoming {
            let normalized = LiveSubtitleSemanticSegmenter.normalize(fragment.text)
            guard !normalized.isEmpty else { continue }

            let overlapping = previousSpans.filter {
                $0.range.intersects(fragment.range)
            }
            // Word-level fragments that overlap committed audio are ignored,
            // while later non-overlapping words in the same callback can still
            // be inserted by the rest of this batch.
            guard !overlapping.contains(where: \.isFinalized) else { continue }

            let volatileOverlaps = overlapping.filter(\.isVolatile)
            let identity = volatileOverlaps
                .first(where: { !claimedIdentities.contains($0.id) })?.id
                ?? UUID()
            claimedIdentities.insert(identity)
            let revision = (volatileOverlaps.map(\.revision).max() ?? -1) + 1
            spans.append(
                LiveTranscriptSpan(
                    id: identity,
                    range: fragment.range,
                    text: normalized,
                    revision: revision,
                    state: fragment.isFinal || fragment.range.end <= finalizedThrough
                        ? .finalized
                        : .volatile
                )
            )
        }

        spans = spans.map { span in
            guard span.isVolatile,
                  span.range.end <= finalizedThrough else { return span }
            return LiveTranscriptSpan(
                id: span.id,
                range: span.range,
                text: span.text,
                revision: span.revision,
                state: .finalized
            )
        }
        spans.sort {
            if $0.range.start == $1.range.start {
                return $0.range.end < $1.range.end
            }
            return $0.range.start < $1.range.start
        }

        let newlyFinalized = spans.filter {
            $0.isFinalized && !emittedFinalizedIDs.contains($0.id)
        }
        emittedFinalizedIDs.formUnion(newlyFinalized.map(\.id))

        return LiveSpeechRecognitionUpdate(
            finalizedSpans: newlyFinalized,
            volatileSpans: spans.filter(\.isVolatile),
            finalizedThrough: finalizedThrough,
            latestAudioEnd: latestAudioEnd
        )
    }

    nonisolated mutating func reset() {
        spans.removeAll(keepingCapacity: false)
        emittedFinalizedIDs.removeAll(keepingCapacity: false)
        latestAudioEnd = 0
    }
}

struct LiveTranslationWindow: Identifiable, Hashable, Sendable {
    let id: UUID
    let range: LiveAudioTimeRange
    let sourceText: String

    init(
        id: UUID = UUID(),
        range: LiveAudioTimeRange,
        sourceText: String
    ) {
        self.id = id
        self.range = range
        self.sourceText = sourceText
    }
}

struct LiveTranslationWindowPlanner: Sendable {
    private struct TimedWord: Sendable {
        let text: String
        let range: LiveAudioTimeRange
    }

    private var pendingWords: [TimedWord] = []
    private var ingestedSpanIDs: Set<UUID> = []

    var pendingSourceText: String {
        pendingWords.map(\.text).joined(separator: " ")
    }

    var pendingRange: LiveAudioTimeRange? {
        guard let first = pendingWords.first,
              let last = pendingWords.last else { return nil }
        return LiveAudioTimeRange(
            start: first.range.start,
            duration: max(last.range.end - first.range.start, 0)
        )
    }

    mutating func append(finalizedSpans: [LiveTranscriptSpan]) {
        for span in finalizedSpans.sorted(by: { $0.range.start < $1.range.start }) {
            guard span.isFinalized,
                  !ingestedSpanIDs.contains(span.id) else { continue }
            ingestedSpanIDs.insert(span.id)
            pendingWords.append(contentsOf: timedWords(from: span))
        }
        pendingWords.sort { $0.range.start < $1.range.start }
    }

    mutating func drain(
        force: Bool = false,
        minimumWords: Int = 6,
        maximumWords: Int = 12,
        targetDuration: TimeInterval = 2.0,
        lookaheadWords: Int = 1
    ) -> [LiveTranslationWindow] {
        var windows: [LiveTranslationWindow] = []

        while let boundary = nextBoundary(
            force: force,
            minimumWords: minimumWords,
            maximumWords: maximumWords,
            targetDuration: targetDuration,
            lookaheadWords: lookaheadWords
        ) {
            let words = Array(pendingWords.prefix(boundary + 1))
            pendingWords.removeFirst(boundary + 1)
            windows.append(makeWindow(words))
        }

        if force, !pendingWords.isEmpty {
            if let previous = windows.last,
               pendingWords.count < minimumWords,
               wordCount(previous.sourceText) + pendingWords.count <= maximumWords {
                let tail = makeWindow(pendingWords)
                _ = windows.removeLast()
                windows.append(
                    LiveTranslationWindow(
                        id: previous.id,
                        range: previous.range.union(tail.range),
                        sourceText: LiveSubtitleSemanticSegmenter.join(
                            previous.sourceText,
                            tail.sourceText
                        )
                    )
                )
            } else {
                windows.append(makeWindow(pendingWords))
            }
            pendingWords.removeAll(keepingCapacity: true)
        }

        return windows
    }

    mutating func reset() {
        pendingWords.removeAll(keepingCapacity: false)
        ingestedSpanIDs.removeAll(keepingCapacity: false)
    }

    private func nextBoundary(
        force: Bool,
        minimumWords: Int,
        maximumWords: Int,
        targetDuration: TimeInterval,
        lookaheadWords: Int
    ) -> Int? {
        guard !pendingWords.isEmpty else { return nil }

        let punctuationLimit = min(pendingWords.count, maximumWords)
        if punctuationLimit >= minimumWords {
            for index in (minimumWords - 1)..<punctuationLimit
            where closesSemanticUnit(pendingWords[index].text) {
                return index
            }
        }

        let hasLookahead = pendingWords.count >= minimumWords + lookaheadWords
        if hasLookahead {
            let upper = min(maximumWords - 1, pendingWords.count - lookaheadWords - 1)
            if upper >= minimumWords - 1 {
                let duration = pendingWords[upper].range.end - pendingWords[0].range.start
                if pendingWords.count >= maximumWords + lookaheadWords
                    || duration >= targetDuration {
                    for index in stride(from: upper, through: minimumWords - 1, by: -1)
                    where LivePreviewStabilityPolicy.hasSafeTrailingWord(
                        pendingWords[index].text
                    ) {
                        return index
                    }
                }
            }
        }

        if force, pendingWords.count > maximumWords {
            return maximumWords - 1
        }
        return nil
    }

    private func timedWords(from span: LiveTranscriptSpan) -> [TimedWord] {
        let words = span.text.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let wordDuration = span.range.duration / Double(words.count)
        return words.enumerated().map { index, word in
            TimedWord(
                text: word,
                range: LiveAudioTimeRange(
                    start: span.range.start + Double(index) * wordDuration,
                    duration: wordDuration
                )
            )
        }
    }

    private func makeWindow(_ words: [TimedWord]) -> LiveTranslationWindow {
        let first = words.first?.range ?? .zero
        let last = words.last?.range ?? .zero
        return LiveTranslationWindow(
            range: LiveAudioTimeRange(
                start: first.start,
                duration: max(last.end - first.start, 0)
            ),
            sourceText: words.map(\.text).joined(separator: " ")
        )
    }

    private func closesSemanticUnit(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!,;:。？！；，：".contains(last)
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \Character.isWhitespace).count
    }
}

public struct LiveTranslationRequestKey: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case preview
        case final
    }

    public let sessionID: UUID
    public let segmentID: UUID
    public let revision: Int
    public let kind: Kind
    public let audioRange: LiveAudioTimeRange

    public init(
        sessionID: UUID,
        segmentID: UUID,
        revision: Int,
        kind: Kind,
        audioRange: LiveAudioTimeRange = .zero
    ) {
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.revision = revision
        self.kind = kind
        self.audioRange = audioRange
    }
}

struct LiveTranslationIdentityGate {
    static func acceptsPreview(
        responseKey: LiveTranslationRequestKey,
        currentKey: LiveTranslationRequestKey?,
        sessionID: UUID
    ) -> Bool {
        responseKey.kind == .preview
            && responseKey.sessionID == sessionID
            && responseKey == currentKey
    }

    static func acceptsFinal(
        responseKey: LiveTranslationRequestKey,
        pendingKey: LiveTranslationRequestKey?,
        committedSegmentIDs: Set<UUID>,
        sessionID: UUID
    ) -> Bool {
        responseKey.kind == .final
            && responseKey.sessionID == sessionID
            && responseKey == pendingKey
            && !committedSegmentIDs.contains(responseKey.segmentID)
    }
}

struct LiveSubtitleSemanticSegmenter {
    private static let sentenceTerminators: Set<Character> = [
        ".", "?", "!", "。", "？", "！"
    ]

    private static let clauseTerminators: Set<Character> = [
        ",", ";", ":", "，", "；", "："
    ]

    static func extractSegments(
        from text: String,
        force: Bool = false,
        hardWordLimit: Int = 20
    ) -> (segments: [String], remainder: String) {
        var remainder = normalize(text)
        var segments: [String] = []

        while !remainder.isEmpty {
            if let boundary = firstSentenceBoundary(
                in: remainder,
                allowShortSentence: force
            ) {
                let sentence = String(remainder[...boundary])
                if let clauseBoundary = safeClauseBoundary(
                    in: sentence,
                    hardWordLimit: hardWordLimit
                ) {
                    appendSegment(
                        String(remainder[..<clauseBoundary]),
                        to: &segments
                    )
                    remainder = normalize(String(remainder[clauseBoundary...]))
                    continue
                }

                appendSegment(
                    sentence,
                    to: &segments
                )
                remainder = normalize(String(remainder[remainder.index(after: boundary)...]))
                continue
            }

            if wordCount(remainder) >= hardWordLimit,
               let boundary = safeClauseBoundary(
                   in: remainder,
                   hardWordLimit: hardWordLimit
               ) {
                appendSegment(
                    String(remainder[..<boundary]),
                    to: &segments
                )
                remainder = normalize(String(remainder[boundary...]))
                continue
            }

            break
        }

        if force, !remainder.isEmpty {
            appendSegment(remainder, to: &segments)
            remainder = ""
        }

        return (segments, remainder)
    }

    /// 源文本超过上界时，从一个从句边界开始，而不是硬砍最后 N 个词。
    ///
    /// preview 的起点每挪动一次，译文就整段重写一次——「一句话翻译到一半突然
    /// 全被覆盖」正是这么来的。锚在边界上，起点在一句话内保持不动，模型每次
    /// 拿到的都是同一个前缀加一点新内容，译文才有条件只往后长。
    ///
    /// 边界取「最靠前且剩余不超上界」的那个：上下文留得越多，翻译越准，
    /// 而锚点只在真的超界时才往后跳一次。
    static func previewAnchor(in text: String, maximumWords: Int) -> String {
        let normalized = normalize(text)
        let words = normalized
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
        guard words.count > maximumWords else { return normalized }

        var boundaries: [Int] = []
        for (index, word) in words.enumerated() where index + 1 < words.count {
            guard let last = word.last(where: { !$0.isWhitespace }) else { continue }
            if sentenceTerminators.contains(last) || clauseTerminators.contains(last) {
                boundaries.append(index + 1)
            }
        }
        if let start = boundaries.first(where: { words.count - $0 <= maximumWords }) {
            return words[start...].joined(separator: " ")
        }
        return words.suffix(maximumWords).joined(separator: " ")
    }

    static func join(_ lhs: String, _ rhs: String) -> String {
        normalize([lhs, rhs].filter { !$0.isEmpty }.joined(separator: " "))
    }

    nonisolated static func normalize(_ text: String) -> String {
        text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tiny ASR-final fragment such as `Mosh reps.` should not immediately
    /// become its own translated caption while speech is continuing. Walk past
    /// short sentence candidates and merge them with the next complete sentence.
    private static func firstSentenceBoundary(
        in text: String,
        allowShortSentence: Bool
    ) -> String.Index? {
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let boundary = text[searchStart...]
                .firstIndex(where: sentenceTerminators.contains) {
            let candidate = String(text[...boundary])
            if allowShortSentence || wordCount(candidate) >= 4 {
                return boundary
            }
            searchStart = text.index(after: boundary)
        }

        return nil
    }

    /// Prefer a real clause boundary before a long sentence reaches the UI.
    /// This deliberately runs even when a later sentence terminator exists: a
    /// 40-word sentence with commas is several subtitle captions, not one huge
    /// caption. Text without punctuation still stays intact rather than being
    /// cut in the middle of a phrase.
    private static func safeClauseBoundary(
        in text: String,
        hardWordLimit: Int
    ) -> String.Index? {
        let words = text.split(whereSeparator: \Character.isWhitespace)
        guard words.count >= hardWordLimit else { return nil }

        let targetWordCount = max(hardWordLimit, 1)
        let targetWord = words[targetWordCount - 1]
        let targetEnd = targetWord.endIndex
        let prefix = text[..<targetEnd]

        if let clause = prefix.lastIndex(where: clauseTerminators.contains),
           wordCount(String(prefix[...clause])) >= 6 {
            return text.index(after: clause)
        }

        return nil
    }

    private static func appendSegment(
        _ text: String,
        to segments: inout [String]
    ) {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return }
        segments.append(normalized)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \Character.isWhitespace).count
    }
}

struct LivePreviewStabilityPolicy {
    private static let sentenceTerminators: Set<Character> = [
        ".", "?", "!", "。", "？", "！"
    ]

    private static let unsafeTrailingWords: Set<String> = [
        "a", "an", "the", "to", "of", "for", "from", "with", "without",
        "and", "or", "but", "if", "when", "while", "that", "which", "who",
        "because", "although", "though", "unless", "until", "since", "as",
        "than", "then", "before", "after", "into", "onto", "about",
        "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did",
        "can", "could", "will", "would", "should", "may", "might", "must",
        "set", "get", "put", "take", "make", "turn", "look", "go", "come"
    ]

    static func isReady(
        _ text: String,
        minimumWordCount: Int = 4
    ) -> Bool {
        let normalized = LiveSubtitleSemanticSegmenter.normalize(text)
        let words = normalized.split(whereSeparator: \Character.isWhitespace)
        guard words.count >= minimumWordCount else { return false }

        if let lastCharacter = normalized.last,
           sentenceTerminators.contains(lastCharacter) {
            return true
        }

        guard let lastWord = words.last else { return false }
        return hasSafeTrailingWord(String(lastWord))
    }

    static func shouldRequest(
        candidate: String,
        after previousSource: String,
        minimumAddedWords: Int = 3
    ) -> Bool {
        let normalizedCandidate = LiveSubtitleSemanticSegmenter.normalize(candidate)
        let normalizedPrevious = LiveSubtitleSemanticSegmenter.normalize(previousSource)

        guard isReady(normalizedCandidate),
              normalizedCandidate != normalizedPrevious else {
            return false
        }
        guard !normalizedPrevious.isEmpty else { return true }

        guard normalizedCandidate.hasPrefix(normalizedPrevious) else {
            let candidateWords = normalizedCandidate
                .split(whereSeparator: \Character.isWhitespace)
                .map(String.init)
            let previousWords = normalizedPrevious
                .split(whereSeparator: \Character.isWhitespace)
                .map(String.init)
            let overlap = rollingWordOverlap(
                previous: previousWords,
                candidate: candidateWords
            )
            if overlap >= 3 {
                return candidateWords.count - overlap >= minimumAddedWords
            }
            return true
        }

        let candidateCount = wordCount(normalizedCandidate)
        let previousCount = wordCount(normalizedPrevious)
        if candidateCount - previousCount >= minimumAddedWords {
            return true
        }

        return normalizedCandidate.last.map(sentenceTerminators.contains) ?? false
    }

    static func canRetainDisplayedTranslation(
        displayedSource: String,
        while currentSource: String
    ) -> Bool {
        let displayed = LiveSubtitleSemanticSegmenter.normalize(displayedSource)
        let current = LiveSubtitleSemanticSegmenter.normalize(currentSource)
        return !displayed.isEmpty && current.hasPrefix(displayed)
    }

    static func hasSafeTrailingWord(_ word: String) -> Bool {
        let cleanedTail = word
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
        return !cleanedTail.isEmpty && !unsafeTrailingWords.contains(cleanedTail)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \Character.isWhitespace).count
    }

    private static func rollingWordOverlap(
        previous: [String],
        candidate: [String]
    ) -> Int {
        let limit = min(previous.count, candidate.count)
        guard limit > 0 else { return 0 }
        for count in stride(from: limit, through: 1, by: -1) {
            if previous.suffix(count).elementsEqual(candidate.prefix(count)) {
                return count
            }
        }
        return 0
    }
}
