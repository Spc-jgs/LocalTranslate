import Foundation

@main
struct LiveSubtitlePipelineStateTests {
    static func main() {
        volatileRangeReplacesInsteadOfAppending()
        nonOverlappingVolatileRangesRemainOrdered()
        finalizationEmitsEachSpanExactlyOnce()
        finalizedSpanCannotBeRewritten()
        wordLevelBatchPreservesCommittedAndAddsNewTail()
        plannerPrefersSemanticPunctuation()
        plannerUsesBoundedLookaheadWithoutPunctuation()
        plannerWaitsForUnsafeTrailingWord()
        silenceFlushesTheStableTail()
        plannerNeverDropsOrDuplicatesWords()
        previewReadinessRejectsIncompletePhrases()
        compatiblePreviewGrowthRetainsDisplayedTranslation()
        requestRevisionAndRangeRejectStaleKey()
        finalIdentityRejectsDuplicateAndOldSession()
        print("LiveSubtitlePipelineStateTests: 14 passed")
    }

    private static func volatileRangeReplacesInsteadOfAppending() {
        var ledger = LiveTranscriptSpanLedger()
        let first = ledger.apply(
            text: "you should now set",
            range: range(0, 2),
            isFinal: false,
            finalizedThrough: 0
        )
        expect(first.volatileText == "you should now set", "first partial missing")

        let revised = ledger.apply(
            text: "you should now set up",
            range: range(0, 2.5),
            isFinal: false,
            finalizedThrough: 0
        )
        expect(
            revised.volatileSpans.count == 1,
            "overlapping partial must replace, not append"
        )
        expect(
            revised.volatileText == "you should now set up",
            "replacement must expose only the latest revision"
        )
        expect(
            revised.volatileSpans[0].revision == 1,
            "range replacement must advance its revision"
        )
    }

    private static func nonOverlappingVolatileRangesRemainOrdered() {
        var ledger = LiveTranscriptSpanLedger()
        _ = ledger.apply(
            text: "second range",
            range: range(2, 2),
            isFinal: false,
            finalizedThrough: 0
        )
        let update = ledger.apply(
            text: "first range",
            range: range(0, 2),
            isFinal: false,
            finalizedThrough: 0
        )
        expect(
            update.volatileText == "first range second range",
            "range ledger must reconstruct audio order"
        )
    }

    private static func finalizationEmitsEachSpanExactlyOnce() {
        var ledger = LiveTranscriptSpanLedger()
        _ = ledger.apply(
            text: "set up the project",
            range: range(0, 2),
            isFinal: false,
            finalizedThrough: 0
        )
        let finalized = ledger.apply(
            text: "set up the project",
            range: range(0, 2),
            isFinal: true,
            finalizedThrough: 2
        )
        expect(finalized.finalizedSpans.count == 1, "final must emit once")
        expect(finalized.volatileSpans.isEmpty, "final must leave no volatile copy")

        let duplicate = ledger.apply(
            text: "set up the project",
            range: range(0, 2),
            isFinal: true,
            finalizedThrough: 2
        )
        expect(duplicate.finalizedSpans.isEmpty, "duplicate final must not re-emit")
    }

    private static func finalizedSpanCannotBeRewritten() {
        var ledger = LiveTranscriptSpanLedger()
        _ = ledger.apply(
            text: "immutable source",
            range: range(0, 2),
            isFinal: true,
            finalizedThrough: 2
        )
        let malformedRevision = ledger.apply(
            text: "rewritten source plus tail",
            range: range(0, 2.5),
            isFinal: false,
            finalizedThrough: 2
        )
        expect(
            malformedRevision.volatileSpans.isEmpty,
            "a callback overlapping committed audio must not rewrite it"
        )
        expect(
            malformedRevision.finalizedSpans.isEmpty,
            "an immutable span must not be emitted twice"
        )
    }

    private static func wordLevelBatchPreservesCommittedAndAddsNewTail() {
        var ledger = LiveTranscriptSpanLedger()
        _ = ledger.apply(
            text: "committed",
            range: range(0, 1),
            isFinal: true,
            finalizedThrough: 1
        )
        let update = ledger.apply(
            fragments: [
                LiveTranscriptFragment(
                    text: "wrong",
                    range: range(0, 1),
                    isFinal: false
                ),
                LiveTranscriptFragment(
                    text: "new tail",
                    range: range(1, 1),
                    isFinal: false
                )
            ],
            finalizedThrough: 1
        )
        expect(
            ledger.spans.first?.text == "committed",
            "word batch must not rewrite committed audio"
        )
        expect(
            update.volatileText == "new tail",
            "non-overlapping tail in the same callback must still be accepted"
        )
    }

    private static func plannerPrefersSemanticPunctuation() {
        var planner = LiveTranslationWindowPlanner()
        planner.append(finalizedSpans: [
            span(
                "one two three four five six seven eight, nine ten eleven twelve",
                start: 0,
                duration: 3.6
            )
        ])
        let windows = planner.drain()
        expect(windows.count == 1, "a clause boundary should produce one window")
        expect(
            windows[0].sourceText == "one two three four five six seven eight,",
            "planner must close at punctuation before a hard word cut"
        )
        expect(
            planner.pendingSourceText == "nine ten eleven twelve",
            "lookahead must remain available for the next window"
        )
    }

    private static func plannerUsesBoundedLookaheadWithoutPunctuation() {
        var planner = LiveTranslationWindowPlanner()
        let source = words(1...18)
        planner.append(finalizedSpans: [span(source, start: 0, duration: 5.4)])
        let windows = planner.drain()
        expect(windows.count == 1, "long speech must not wait for punctuation forever")
        expect(
            windows[0].sourceText == words(1...16),
            "normal window must remain within sixteen words"
        )
        expect(
            planner.pendingSourceText == words(17...18),
            "two finalized lookahead words must not be consumed"
        )
    }

    private static func plannerWaitsForUnsafeTrailingWord() {
        var planner = LiveTranslationWindowPlanner()
        planner.append(finalizedSpans: [
            span(
                "one two three four five six seven set nine ten",
                start: 0,
                duration: 3
            )
        ])
        expect(
            planner.drain().isEmpty,
            "window must wait when its only eligible boundary ends with a phrase head"
        )
    }

    private static func silenceFlushesTheStableTail() {
        var planner = LiveTranslationWindowPlanner()
        planner.append(finalizedSpans: [
            span("a short stable tail", start: 1, duration: 1.2)
        ])
        let windows = planner.drain(force: true)
        expect(windows.count == 1, "silence must flush finalized tail")
        expect(windows[0].sourceText == "a short stable tail", "flush changed text")
        expect(planner.pendingSourceText.isEmpty, "flush must drain pending words")
    }

    private static func plannerNeverDropsOrDuplicatesWords() {
        var planner = LiveTranslationWindowPlanner()
        let source = words(1...32)
        planner.append(finalizedSpans: [span(source, start: 0, duration: 8)])
        let windows = planner.drain(force: true)
        let reconstructed = windows.map(\.sourceText).joined(separator: " ")
        expect(reconstructed == source, "window planning must preserve every word once")
        expect(
            windows.allSatisfy { wordCount($0.sourceText) <= 16 },
            "forced windows must still honor the maximum length"
        )
    }

    private static func previewReadinessRejectsIncompletePhrases() {
        expect(!LivePreviewStabilityPolicy.isReady("The benef"), "short fragment leaked")
        expect(
            LivePreviewStabilityPolicy.isReady("We can start today"),
            "a safe four-word clause should translate promptly"
        )
        expect(
            !LivePreviewStabilityPolicy.isReady("you should now set"),
            "phrasal-verb head must remain source-only"
        )
        expect(
            !LivePreviewStabilityPolicy.isReady("The benefit there is that"),
            "connective tail must wait for its complement"
        )
        expect(
            LivePreviewStabilityPolicy.isReady("The benefit is that Mosh stays connected"),
            "complete clause-shaped preview should stay low latency"
        )
        expect(
            !LivePreviewStabilityPolicy.shouldRequest(
                candidate: "The benefit is that Mosh stays connected today",
                after: "The benefit is that Mosh stays connected"
            ),
            "one added word must not trigger a whole-preview request"
        )
        expect(
            !LivePreviewStabilityPolicy.shouldRequest(
                candidate: words(2...15),
                after: words(1...14)
            ),
            "one-word rolling-window shift must not trigger a rewrite"
        )
        expect(
            LivePreviewStabilityPolicy.shouldRequest(
                candidate: words(4...17),
                after: words(1...14)
            ),
            "three new rolling-window words should trigger the next caption"
        )
    }

    private static func compatiblePreviewGrowthRetainsDisplayedTranslation() {
        expect(
            LivePreviewStabilityPolicy.canRetainDisplayedTranslation(
                displayedSource: "It is basically a drop-in replacement",
                while: "It is basically a drop-in replacement for SSH"
            ),
            "compatible growth should keep the last complete preview visible"
        )
        expect(
            !LivePreviewStabilityPolicy.canRetainDisplayedTranslation(
                displayedSource: "It is basically a drop-in replacement",
                while: "It was originally designed as a replacement"
            ),
            "meaningful correction must clear incompatible translation"
        )
    }

    private static func requestRevisionAndRangeRejectStaleKey() {
        let sessionID = UUID()
        let segmentID = UUID()
        let old = LiveTranslationRequestKey(
            sessionID: sessionID,
            segmentID: segmentID,
            revision: 1,
            kind: .preview,
            audioRange: range(0, 2)
        )
        let current = LiveTranslationRequestKey(
            sessionID: sessionID,
            segmentID: segmentID,
            revision: 2,
            kind: .preview,
            audioRange: range(0, 2.5)
        )
        expect(
            !LiveTranslationIdentityGate.acceptsPreview(
                responseKey: old,
                currentKey: current,
                sessionID: sessionID
            ),
            "older preview revision and range must fail identity validation"
        )
        expect(
            LiveTranslationIdentityGate.acceptsPreview(
                responseKey: current,
                currentKey: current,
                sessionID: sessionID
            ),
            "exact current preview must pass identity validation"
        )
    }

    private static func finalIdentityRejectsDuplicateAndOldSession() {
        let sessionID = UUID()
        let segmentID = UUID()
        let key = LiveTranslationRequestKey(
            sessionID: sessionID,
            segmentID: segmentID,
            revision: 0,
            kind: .final,
            audioRange: range(4, 2)
        )
        expect(
            LiveTranslationIdentityGate.acceptsFinal(
                responseKey: key,
                pendingKey: key,
                committedSegmentIDs: [],
                sessionID: sessionID
            ),
            "pending final must be accepted"
        )
        expect(
            !LiveTranslationIdentityGate.acceptsFinal(
                responseKey: key,
                pendingKey: key,
                committedSegmentIDs: [segmentID],
                sessionID: sessionID
            ),
            "duplicate final must be rejected"
        )
        expect(
            !LiveTranslationIdentityGate.acceptsFinal(
                responseKey: key,
                pendingKey: key,
                committedSegmentIDs: [],
                sessionID: UUID()
            ),
            "old-session final must be rejected"
        )
    }

    private static func span(
        _ text: String,
        start: TimeInterval,
        duration: TimeInterval
    ) -> LiveTranscriptSpan {
        LiveTranscriptSpan(
            range: range(start, duration),
            text: text,
            state: .finalized
        )
    }

    private static func range(
        _ start: TimeInterval,
        _ duration: TimeInterval
    ) -> LiveAudioTimeRange {
        LiveAudioTimeRange(start: start, duration: duration)
    }

    private static func words(_ range: ClosedRange<Int>) -> String {
        range.map { "w\($0)" }.joined(separator: " ")
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \Character.isWhitespace).count
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("LiveSubtitlePipelineStateTests failed: \(message)")
        }
    }
}
