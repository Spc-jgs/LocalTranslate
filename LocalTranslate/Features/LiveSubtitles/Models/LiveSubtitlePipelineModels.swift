import Foundation

public struct LiveSpeechRecognitionUpdate: Sendable, Equatable {
    public let committedDelta: String
    public let unstableText: String

    public nonisolated init(
        committedDelta: String,
        unstableText: String
    ) {
        self.committedDelta = committedDelta
        self.unstableText = unstableText
    }
}

struct LiveSpeechRecognitionState: Sendable {
    private(set) var unstableText = ""

    nonisolated init() {}

    nonisolated mutating func consume(
        text: String,
        isFinal: Bool
    ) -> LiveSpeechRecognitionUpdate {
        let normalized = Self.normalize(text)

        if isFinal {
            unstableText = ""
            return LiveSpeechRecognitionUpdate(
                committedDelta: normalized,
                unstableText: ""
            )
        }

        unstableText = normalized
        return LiveSpeechRecognitionUpdate(
            committedDelta: "",
            unstableText: unstableText
        )
    }

    nonisolated mutating func reset() {
        unstableText = ""
    }

    private nonisolated static func normalize(_ text: String) -> String {
        text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    public init(
        sessionID: UUID,
        segmentID: UUID,
        revision: Int,
        kind: Kind
    ) {
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.revision = revision
        self.kind = kind
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

    static func join(_ lhs: String, _ rhs: String) -> String {
        normalize([lhs, rhs].filter { !$0.isEmpty }.joined(separator: " "))
    }

    static func normalize(_ text: String) -> String {
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
        "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did",
        "can", "could", "will", "would", "should", "may", "might", "must",
        "set", "get", "put", "take", "make", "turn", "look", "go", "come"
    ]

    static func isReady(
        _ text: String,
        minimumWordCount: Int = 5
    ) -> Bool {
        let normalized = LiveSubtitleSemanticSegmenter.normalize(text)
        let words = normalized.split(whereSeparator: \Character.isWhitespace)
        guard words.count >= minimumWordCount else { return false }

        if let lastCharacter = normalized.last,
           sentenceTerminators.contains(lastCharacter) {
            return true
        }

        guard let lastWord = words.last else { return false }
        let cleanedTail = lastWord
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
        return !unsafeTrailingWords.contains(cleanedTail)
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

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \Character.isWhitespace).count
    }
}

struct LiveCaptionPresentationQueue<Element> {
    private(set) var active: Element?
    private(set) var waiting: [Element] = []
    private var activeSince: TimeInterval?

    mutating func enqueue(
        _ element: Element,
        now: TimeInterval,
        minimumDwell: TimeInterval
    ) -> Element? {
        waiting.append(element)
        return advanceIfReady(now: now, minimumDwell: minimumDwell)
    }

    mutating func advanceIfReady(
        now: TimeInterval,
        minimumDwell: TimeInterval
    ) -> Element? {
        guard !waiting.isEmpty else { return nil }

        if let activeSince,
           now - activeSince < minimumDwell {
            return nil
        }

        let next = waiting.removeFirst()
        active = next
        activeSince = now
        return next
    }

    func nextDelay(
        now: TimeInterval,
        minimumDwell: TimeInterval
    ) -> TimeInterval? {
        guard !waiting.isEmpty else { return nil }
        guard let activeSince else { return 0 }
        return max(minimumDwell - (now - activeSince), 0)
    }

    mutating func reset() {
        active = nil
        waiting.removeAll(keepingCapacity: false)
        activeSince = nil
    }
}
