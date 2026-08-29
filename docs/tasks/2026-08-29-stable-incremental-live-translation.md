# Stable Incremental Live Translation · Design and MVP

- Status: FROZEN_FOR_MVP
- Date: 2026-08-29
- Scope: `Features/LiveSubtitles`
- Execution rule: source transcript stability first; do not optimize the prompt or replace the Ollama model in this MVP.

## 1. Problem statement

The current live-subtitle pipeline treats volatile ASR output as if it were committed text. A growing partial result is segmented and translated repeatedly, fixed-size word chunks are locked before ASR finalization, and asynchronous translation callbacks mutate shared UI state without segment or revision validation. The visible outcomes are repeated or reordered source text, unstable full-line translation rewrites, premature translation of incomplete phrases such as `set` before `set up`, mixed English and Chinese, and stale responses clearing or overwriting newer captions.

Apple `SpeechTranscriber` produces one or more volatile revisions for an audio range and then a final result for that range. Volatile text must replace the current volatile value; only `isFinal` text may be appended to committed ASR state. Punctuation is a segmentation hint, not a substitute for the framework's finalization signal.

References:

- https://developer.apple.com/documentation/speech/speechtranscriber/result
- https://developer.apple.com/videos/play/wwdc2025/277/

## 2. Goals

1. Represent ASR state explicitly as `committed transcript + unstable partial`.
2. Prevent source duplication caused by volatile/final merging and word-count offsets.
3. Segment only stable source text into immutable committed caption segments.
4. Retain low latency through a separate, replaceable preview translation path.
5. Represent translation state as `committed translation + preview translation`.
6. Reject stale Ollama stream chunks and completions using session, segment, and revision identity.
7. Guarantee that a committed subtitle is append-only and is never changed by later ASR revisions.
8. Release capture, ASR, timers, and translation tasks when stopped or when the source language changes.

## 3. Non-goals

- No prompt optimization.
- No Ollama model replacement or model-parameter benchmarking.
- No new third-party dependency.
- No replacement of ScreenCaptureKit or Apple Speech frameworks.
- No persistent transcript migration or database work.
- No broad redesign of the subtitle overlay.
- No audio denoising, echo cancellation, or VAD model replacement.

## 4. Evidence from the current implementation

### 4.1 ASR contract violation

`RecognitionEngine.consume` currently promotes punctuation-ending volatile text to `isFinal` and clears `currentTranscript`. A later revision or real final result for the same audio range can therefore no longer replace the old text. This is a direct duplication path.

### 4.2 Unstable text is locked by word count

`LiveSubtitlesViewModel` uses `committedASRWordCount`, locks the first four words whenever five partial words are visible, and queues those words as final translation. This treats volatile text as immutable and can split phrasal verbs and clauses.

### 4.3 Stale callback mutation

Translation jobs have no request identity. Their callbacks append to or clear shared `locked/current` fields. A callback from an older logical segment may arrive after ASR has advanced and mutate the newer segment.

### 4.4 UI state conflation

When translation is empty, the translation row falls back to the active original text. The UI therefore cannot distinguish a committed translation, an unstable translation preview, and untranslated source text.

### 4.5 Audio overlap is not proven

The capture layer passes copied `SCStream` buffers directly to the analyzer and contains no explicit rolling audio window. Runtime sample PTS/duration evidence is still required before attributing duplication to audio overlap. The MVP adds lightweight debug tracing rather than changing the capture algorithm speculatively.

## 5. Invariants

The implementation must preserve these invariants:

1. `committedASRText` contains only text from `SpeechTranscriber.Result.isFinal == true`.
2. `unstableASRText` is replaced by each volatile revision; it is never appended to history.
3. A source segment receives a stable `segmentID` before final translation is queued.
4. A committed segment is immutable and appended to history at most once.
5. Preview translation is identified by `(sessionID, previewSegmentID, revision)`.
6. Final translation is identified by `(sessionID, segmentID, sourceText)`.
7. A callback updates state only when its identity still matches the expected state.
8. Preview callbacks never write committed translation or history.
9. Final callbacks never clear unrelated active/preview state.
10. Stop, clear, and language change invalidate the session before cancelling work.

## 6. Target data flow

```text
SCStream buffers
  -> SpeechAnalyzer
  -> ASRUpdate(sessionID, committedDelta?, unstableReplacement)
  -> TranscriptState(committedBuffer, unstablePartial)
  -> SemanticSegmenter
       -> committed SourceSegment(s), immutable
       -> preview candidate, revisioned
  -> LiveTranslationService
       -> final FIFO jobs keyed by sessionID + segmentID
       -> latest-wins preview keyed by sessionID + previewID + revision
  -> SubtitlePresentationState
       -> committed items
       -> preview source + preview translation
  -> SwiftUI
```

## 7. ASR state design

Replace the delegate payload `(text, isFinal)` with an explicit update:

```swift
struct LiveSpeechRecognitionUpdate: Sendable {
    let committedDelta: String
    let unstableText: String
}
```

For the MVP, `RecognitionEngine` keeps only the bounded volatile snapshot:

```swift
private var volatileTranscript = AttributedString()
```

Result handling:

- If `result.isFinal`, emit `result.text` once as `committedDelta` and clear `volatileTranscript`.
- Otherwise, replace `volatileTranscript` with `result.text`.
- Emit the committed delta and current volatile value after every non-empty update.
- Never derive ASR finality from punctuation, length, or a timer.
- Reset the volatile value on stop/start/language change.

The ViewModel appends committed deltas to its stable tail. This follows the framework's progressive-transcription contract, removes audio-range substring replacement, and avoids repeatedly copying an unbounded full-session transcript.

## 8. Semantic segmentation

The ViewModel owns a committed-source buffer and a consumed character cursor. It never uses word-count alignment against volatile revisions.

### 8.1 Committed segment boundaries

Consume only new committed ASR text. Emit an immutable source segment at the first applicable boundary:

1. Sentence punctuation (`.`, `?`, `!`, `。`, `？`, `！`).
2. A clause punctuation boundary such as comma/semicolon when the candidate has enough words to stand alone.
3. A silence boundary when committed text is available.
4. A hard length cap, cut at the latest safe punctuation or whitespace boundary.

The MVP may keep the rules intentionally small: sentence punctuation, silence, and a conservative hard cap. It must not cut a fixed four-word prefix from volatile text.

### 8.2 Preview candidate

The preview source is:

```text
unsegmented committed tail + unstable ASR partial
```

It is allowed to change. Each distinct normalized value increments `previewRevision`. A short debounce/coalescing window may be used to avoid sending every character-level change, but it must not delay committed segment translation.

Preview content is never appended to subtitle history.

### 8.3 Silence

The silence timer snapshots the current session identity. On fire:

- If the session changed, do nothing.
- If committed tail exists, emit it as a committed segment.
- If only volatile text exists, keep it as preview; do not promote it to committed ASR text.

## 9. Translation scheduling

Introduce request keys:

```swift
struct TranslationRequestKey: Hashable, Sendable {
    enum Kind: Sendable { case preview, final }
    let sessionID: UUID
    let segmentID: UUID
    let revision: Int
    let kind: Kind
}
```

### 9.1 Preview channel

- One in-flight request and one latest pending snapshot.
- Every streamed chunk carries the key supplied at enqueue time.
- The ViewModel accepts a chunk only when it matches the current preview key.
- A newer preview revision invalidates all older chunks, even if cancellation is delayed.
- Preview failure leaves committed captions unchanged and may fall back to no preview translation.

### 9.2 Final channel

- FIFO queue of immutable committed source segments.
- A completion is accepted only when session and segment IDs match an existing pending segment.
- Completion promotes that one segment into immutable `SubtitleItem` history.
- Completion does not clear current preview fields.
- Duplicate completion for a committed segment is ignored by segment ID.

### 9.3 Lifecycle

`stop`, `clearSubtitles`, and `setSourceLanguage` first create a new session identity, invalidate timers and active keys, and then cancel translation tasks. Late callbacks fail identity checks.

## 10. Presentation state

The overlay receives separate state:

```swift
@Published var committedItems: [SubtitleItem]
@Published var previewOriginalText: String
@Published var previewTranslatedText: String
```

Rendering rules:

- The active committed subtitle uses only committed translation.
- Preview translation is rendered separately with reduced emphasis.
- If preview translation is empty, do not substitute English into the translation row.
- Original preview remains visible in bilingual/original modes.
- Promotion from preview to committed is atomic by segment ID.
- Previously committed items never change when a later revision arrives.

## 11. Diagnostics

Debug-only tracing should include:

- Audio buffer sequence, PTS, duration, and discontinuity delta.
- ASR result sequence, range, `isFinal`, committed text hash, and volatile text hash.
- Segment ID, boundary reason, source text hash.
- Translation request key, start, first token, completion, cancellation, and stale-drop decision.

No transcript text should be persisted solely for diagnostics.

## 12. MVP file scope

Expected implementation files:

- `Features/LiveSubtitles/Services/LiveSpeechRecognizer.swift`
- `Features/LiveSubtitles/Services/LiveTranslationService.swift`
- `Features/LiveSubtitles/ViewModels/LiveSubtitlesViewModel.swift`
- `Features/LiveSubtitles/Views/LiveSubtitlesView.swift`
- `Features/LiveSubtitles/Models/SubtitleItem.swift` only if segment identity belongs in the model
- `Tests/LiveSubtitlePipelineStateTests.swift` as a standalone focused state harness, avoiding broad Xcode project churn

`SystemAudioCaptureService.swift` may receive debug-only sequence/PTS tracing, but its capture and conversion behavior is otherwise frozen.

## 13. MVP acceptance scenarios

### A. Partial phrase growth

Input revisions:

```text
you should now set
you should now set up
you should now set up the project
```

Expected:

- Volatile source is replaced, never appended.
- No committed source or history entry before a true final result or committed-text boundary.
- Preview may change, but the committed translation does not.

### B. Volatile then final for the same range

Expected:

- Final text appears exactly once in committed ASR state.
- Volatile text is cleared.
- No repeated prefix in the next phrase.

### C. Stale preview stream

Revision 1 response is intentionally delayed after revision 2 starts.

Expected: every revision 1 chunk is rejected after revision 2 becomes current.

### D. Final translation overlaps new preview

A final segment request completes after the next segment preview has started.

Expected: the old final segment is committed once; the new preview remains untouched.

### E. Silence then framework final

Expected: no duplicate history entry and no word-count offset carried into the next phrase.

### F. Stop/restart and language change

Expected: old callbacks, timers, committed tail, and preview state cannot enter the new session.

### G. Runtime audio continuity

Expected: captured buffer PTS is monotonic and adjacent within an explicit tolerance. Any overlap or gap is reported as runtime evidence rather than inferred from text.

## 14. Verification gates

1. Focused state-transition tests for scenarios A-F.
2. `xcodebuild -project LocalTranslate.xcodeproj -scheme LocalTranslate build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`.
3. Manual runtime recording with diagnostic logs for scenario G.
4. Confirm no Prompt, model selection, or unrelated feature files changed as part of this MVP.

Source build success is not runtime proof. If runtime recording is unavailable, audio continuity and real Ollama timing remain `NOT_VERIFIED`.

Focused state-test command:

```bash
test_bin="$(mktemp -d)/live-subtitle-pipeline-tests"
xcrun swiftc \
  LocalTranslate/Features/LiveSubtitles/Models/LiveSubtitlePipelineModels.swift \
  Tests/LiveSubtitlePipelineStateTests.swift \
  -o "$test_bin"
"$test_bin"
```

## 15. MVP implementation evidence

- Implementation: `MVP_IMPLEMENTED` on 2026-08-29.
- Focused state harness: 8 scenarios passed.
- Source build: `BUILD SUCCEEDED` with unsigned local build settings.
- Prompt and Ollama model selection: unchanged by this MVP.
- Runtime ScreenCaptureKit PTS continuity: `NOT_VERIFIED`; debug diagnostics are present for the next recording.
- Real Ollama latency and visual recording review: `NOT_VERIFIED` until an audio/video source is exercised manually.

## 16. Runtime acceptance and MVP v2 correction

The 37.96-second recording `录屏2026-08-29 22.32.23_副本.mov` changed the visual
runtime gate from `NOT_VERIFIED` to `FAILED` for MVP v1. It did not visibly
reproduce source-text overlap or a stale response overwriting a newer revision,
but it exposed three remaining state-machine defects:

1. Preview translation still accepted incomplete phrases. `The benef` appeared
   as `受益人`, and growing partials caused whole-preview semantic rewrites.
2. Every ASR revision cleared the displayed preview before a replacement was
   ready. The preview worker continued an obsolete request while the identity
   gate correctly discarded its chunks, leaving several seconds of source-only
   UI. Final work also prevented the preview worker from running.
3. Final translations advanced the visible caption directly from callback
   completion order. A long sentence remained behind the audio, then multiple
   FIFO completions advanced within one second and skipped normal reading time.

MVP v2 therefore adds these invariants without changing the Prompt or model:

- A preview request requires a clause-shaped candidate, a minimum word count,
  and a safe trailing token. Incomplete tails such as `set`, `that`, or
  `The benef` remain source-only.
- Preview candidates are coalesced, complete atomically, and retain the last
  compatible translation until a newer complete response is accepted.
- Final and preview workers are independent. A stable final source streams into
  its own pending-final presentation state instead of hiding all translation
  until completion.
- Completed captions enter a source-ordered presentation queue with a 1.2-second
  minimum dwell time. Callback bursts cannot skip captions.
- The overlay renders at most two semantic time layers: the current committed
  caption and one next-state row (pending final or replaceable preview).
- Long committed text is cut only at punctuation. Tiny final sentences wait for
  following context unless silence explicitly forces a flush.

MVP v2 verification:

- Focused state harness: 13 scenarios passed.
- Unsigned Xcode build: `BUILD SUCCEEDED`.
- Prompt and Ollama model selection: unchanged by MVP v2.
- A second runtime recording with real audio/Ollama timing: `NOT_VERIFIED`.

## 17. Screenshot acceptance and MVP v3 presentation correction

The 2026-08-30 screenshot showed that MVP v2 still gave the wrong visual
priority to the last completed caption. The older translation was large and
bright while the speech currently being processed was smaller and gray. It
also showed one sentence spanning almost the full overlay width.

MVP v3 applies three presentation rules:

- A long completed sentence is segmented at safe clause punctuation before
  the sentence terminator is considered. The default clause window is 20 words
  and a clause must contain at least 6 words; unpunctuated text is never cut at
  arbitrary whitespace.
- While there is pending-final or preview content, that active speech is the
  large, bright caption. The last committed caption is retained only as a
  single-line, low-emphasis context row.
- Caption replacement is not wrapped in an implicit SwiftUI layout animation.
  A centered line can therefore no longer appear to slide sideways as its
  width changes.

MVP v3 verification:

- Focused state harness: 14 scenarios passed, including a three-clause long
  sentence reconstructed without dropped or duplicated words.
- Runtime visual acceptance remains owned by the user's next Xcode run.
