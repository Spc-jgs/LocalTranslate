import Foundation

@main
struct LiveSubtitlePipelineStateTests {
    static func main() {
        volatileRecognitionReplacesThenFinalizes()
        partialPhraseRemainsUncommitted()
        sentenceBoundaryLeavesRemainder()
        multipleSentencesDrainInOrder()
        longSentenceUsesClauseBoundaries()
        silenceForcesOnlyStableTail()
        hardLimitPreservesEveryWord()
        hardLimitDoesNotCutAtArbitraryWhitespace()
        shortFinalFragmentWaitsForContinuation()
        previewReadinessRejectsIncompletePhrases()
        compatiblePreviewGrowthRetainsDisplayedTranslation()
        presentationQueueEnforcesMinimumDwell()
        requestRevisionRejectsStaleKey()
        finalIdentityRejectsDuplicateAndOldSession()
        print("LiveSubtitlePipelineStateTests: 14 passed")
    }

    private static func volatileRecognitionReplacesThenFinalizes() {
        var state = LiveSpeechRecognitionState()
        let first = state.consume(text: "you should now set", isFinal: false)
        expect(first.committedDelta.isEmpty, "volatile text must not commit")
        expect(first.unstableText == "you should now set", "first volatile snapshot missing")

        let revised = state.consume(text: "you should now set up", isFinal: false)
        expect(revised.committedDelta.isEmpty, "revised volatile text must not commit")
        expect(revised.unstableText == "you should now set up", "volatile text must replace")

        let final = state.consume(text: "you should now set up", isFinal: true)
        expect(final.committedDelta == "you should now set up", "final must emit once as delta")
        expect(final.unstableText.isEmpty, "final must clear volatile text")

        _ = state.consume(text: "discard me", isFinal: false)
        let emptyFinal = state.consume(text: "", isFinal: true)
        expect(emptyFinal.committedDelta.isEmpty, "empty final must not invent source")
        expect(emptyFinal.unstableText.isEmpty, "empty final must still clear volatile UI")
    }

    private static func partialPhraseRemainsUncommitted() {
        let first = LiveSubtitleSemanticSegmenter.extractSegments(
            from: "you should now set"
        )
        expect(first.segments.isEmpty, "unfinished phrase must not commit")
        expect(first.remainder == "you should now set", "partial must remain replaceable")

        let revised = LiveSubtitleSemanticSegmenter.extractSegments(
            from: "you should now set up the project"
        )
        expect(revised.segments.isEmpty, "revised phrase must still be preview-only")
        expect(
            revised.remainder == "you should now set up the project",
            "volatile revision must replace the earlier preview"
        )
    }

    private static func sentenceBoundaryLeavesRemainder() {
        let result = LiveSubtitleSemanticSegmenter.extractSegments(
            from: "Set up the project. Then run the app"
        )
        expect(result.segments == ["Set up the project."], "sentence must commit once")
        expect(result.remainder == "Then run the app", "tail must remain active")
    }

    private static func multipleSentencesDrainInOrder() {
        let result = LiveSubtitleSemanticSegmenter.extractSegments(
            from: "This is the first sentence. This is the second sentence! Third"
        )
        expect(
            result.segments == [
                "This is the first sentence.",
                "This is the second sentence!"
            ],
            "finalized sentences must preserve order"
        )
        expect(result.remainder == "Third", "last incomplete tail must remain")
    }

    private static func longSentenceUsesClauseBoundaries() {
        let source = "That's that is different than a lot of the other approaches, which is I have all of these applications and I am going to expose them to the wide internet, and then you have to put some sort of authentication or access control in front of it."
        let result = LiveSubtitleSemanticSegmenter.extractSegments(from: source)
        expect(
            result.segments == [
                "That's that is different than a lot of the other approaches,",
                "which is I have all of these applications and I am going to expose them to the wide internet,",
                "and then you have to put some sort of authentication or access control in front of it."
            ],
            "a long punctuated sentence must become readable semantic captions"
        )
        expect(result.remainder.isEmpty, "complete long sentence must fully drain")
    }

    private static func silenceForcesOnlyStableTail() {
        let result = LiveSubtitleSemanticSegmenter.extractSegments(
            from: "a framework-finalized phrase without punctuation",
            force: true
        )
        expect(result.segments.count == 1, "silence must flush a stable tail")
        expect(result.remainder.isEmpty, "forced stable tail must be consumed")
    }

    private static func hardLimitPreservesEveryWord() {
        let source = (1...30).map { "w\($0)" }.joined(separator: " ")
        let result = LiveSubtitleSemanticSegmenter.extractSegments(from: source)
        let reconstructed = LiveSubtitleSemanticSegmenter.join(
            result.segments.joined(separator: " "),
            result.remainder
        )
        expect(reconstructed == source, "hard segmentation must not drop or duplicate words")
    }

    private static func hardLimitDoesNotCutAtArbitraryWhitespace() {
        let source = (1...30).map { "word\($0)" }.joined(separator: " ")
        let result = LiveSubtitleSemanticSegmenter.extractSegments(from: source)
        expect(
            result.segments.isEmpty,
            "long text without punctuation must not be cut into an incomplete phrase"
        )
        expect(result.remainder == source, "uncut long text must remain in the stable tail")
    }

    private static func shortFinalFragmentWaitsForContinuation() {
        let short = LiveSubtitleSemanticSegmenter.extractSegments(from: "Mosh reps.")
        expect(short.segments.isEmpty, "tiny framework-final fragment must wait for context")

        let continued = LiveSubtitleSemanticSegmenter.extractSegments(
            from: "Mosh reps. Now you need Mosh installed on every machine."
        )
        expect(
            continued.segments == ["Mosh reps. Now you need Mosh installed on every machine."],
            "tiny fragment must merge with the next complete sentence"
        )
    }

    private static func previewReadinessRejectsIncompletePhrases() {
        expect(
            !LivePreviewStabilityPolicy.isReady("The benef"),
            "two-word ASR fragment must not trigger Chinese preview"
        )
        expect(
            !LivePreviewStabilityPolicy.isReady("you should now set"),
            "phrasal-verb head must remain source-only"
        )
        expect(
            !LivePreviewStabilityPolicy.isReady("The benefit there is that"),
            "unsafe connective tail must wait for its complement"
        )
        expect(
            LivePreviewStabilityPolicy.isReady("The benefit is that Mosh stays connected"),
            "complete clause-shaped preview should remain low latency"
        )
        expect(
            !LivePreviewStabilityPolicy.shouldRequest(
                candidate: "The benefit is that Mosh stays connected today",
                after: "The benefit is that Mosh stays connected"
            ),
            "one added word must not trigger another whole-preview request"
        )
    }

    private static func compatiblePreviewGrowthRetainsDisplayedTranslation() {
        expect(
            LivePreviewStabilityPolicy.canRetainDisplayedTranslation(
                displayedSource: "It is basically a drop-in replacement",
                while: "It is basically a drop-in replacement for SSH"
            ),
            "compatible source growth must keep the last complete preview visible"
        )
        expect(
            !LivePreviewStabilityPolicy.canRetainDisplayedTranslation(
                displayedSource: "It is basically a drop-in replacement",
                while: "It was originally designed as a replacement"
            ),
            "meaningful ASR correction must clear an incompatible preview"
        )
    }

    private static func presentationQueueEnforcesMinimumDwell() {
        var queue = LiveCaptionPresentationQueue<String>()
        let first = queue.enqueue("first", now: 0, minimumDwell: 1.2)
        expect(first == "first", "first completed caption must present immediately")

        let tooSoon = queue.enqueue("second", now: 0.2, minimumDwell: 1.2)
        expect(tooSoon == nil, "next caption must not skip the active dwell interval")
        expect(queue.active == "first", "first caption must remain active during dwell")

        let ready = queue.advanceIfReady(now: 1.2, minimumDwell: 1.2)
        expect(ready == "second", "queued caption must advance in source order")
        expect(queue.active == "second", "second caption must become active after dwell")
    }

    private static func requestRevisionRejectsStaleKey() {
        let sessionID = UUID()
        let segmentID = UUID()
        let old = LiveTranslationRequestKey(
            sessionID: sessionID,
            segmentID: segmentID,
            revision: 1,
            kind: .preview
        )
        let current = LiveTranslationRequestKey(
            sessionID: sessionID,
            segmentID: segmentID,
            revision: 2,
            kind: .preview
        )
        expect(
            !LiveTranslationIdentityGate.acceptsPreview(
                responseKey: old,
                currentKey: current,
                sessionID: sessionID
            ),
            "older preview revision must fail identity validation"
        )
        expect(
            LiveTranslationIdentityGate.acceptsPreview(
                responseKey: current,
                currentKey: current,
                sessionID: sessionID
            ),
            "current preview revision must pass identity validation"
        )
    }

    private static func finalIdentityRejectsDuplicateAndOldSession() {
        let sessionID = UUID()
        let segmentID = UUID()
        let key = LiveTranslationRequestKey(
            sessionID: sessionID,
            segmentID: segmentID,
            revision: 0,
            kind: .final
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

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("LiveSubtitlePipelineStateTests failed: \(message)")
        }
    }
}
