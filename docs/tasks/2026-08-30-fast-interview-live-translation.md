# Fast-interview local live translation design

Status: MVP IMPLEMENTED / SOURCE VERIFIED / RUNTIME ACCEPTANCE PENDING

Date: 2026-08-30

## 1. Product constraint

LocalTranslate remains a lightweight, local-first macOS micro-tool:

- Apple frameworks own system-audio capture and ASR.
- Ollama owns translation and no cloud provider receives transcript content.
- Inactive live subtitles hold no `SCStream`, Speech model, Ollama model, timer,
  queue, or continuously animated UI.
- The overlay follows the speech happening now. It is not a player that must
  replay every completed translation in sequence.

The target scenario is a fast interview with long, weakly punctuated speech.

## 2. Current evidence

### 2.1 Local capacity

- MacBook Pro, Apple M5 Pro, 18 CPU cores, 48 GB unified memory.
- Ollama 0.33.2.
- Relevant installed models:
  - `qwen3.5:4b`, Q4, approximately 3.1 GB loaded model size.
  - `translategemma:4b`, Q4, approximately 2.9 GB loaded model size.

This hardware is sufficient for one warm 4B translation stream. The product
does not need a larger model to solve the observed scheduling problem.

### 2.2 Local model benchmark

One 43-word interview sentence was translated English to Simplified Chinese.
All measured requests used `num_ctx=2048`, `temperature=0`, `think=false` for
the real-time profile.

| Case | Warm total | Output tokens | Output rate | Observation |
| --- | ---: | ---: | ---: | --- |
| `qwen3.5:4b` | 625 ms | 33 | 56.6 tok/s | Good concise output |
| `translategemma:4b` official prompt format | 614 ms | 39 | 68.5 tok/s | Similar end-to-end latency |
| TranslateGemma first load during model switch | 14.4 s | 29 | 69.6 tok/s | Cold switching is unacceptable during speech |

For two warm qwen requests:

- sequential wall time: 1277 ms;
- concurrent wall time: 1209 ms;
- one concurrent request's total latency rose from approximately 524 ms to
  1185 ms.

Conclusion: two app workers do not create useful throughput on this workload.
They increase tail latency and scheduling uncertainty. The live path needs one
foreground translation worker, not concurrent preview and final workers.

`num_predict=64` and `num_ctx=2048` are still appropriate safety bounds, but
they are not the primary speed fix. The sample naturally ended after 33-39
output tokens, so lowering `num_predict` from 140 did not materially accelerate
normal completion.

### 2.3 ASR contract mismatch

`SpeechTranscriber.Result` includes an audio `range`, `isFinal`, and
`resultsFinalizationTime`. Apple's progressive-transcription guidance updates
the transcript by replacing attributed text whose audio time range intersects
the new result, or appending when no range intersects.

The current implementation discards the audio range and reduces each callback
to `(text, isFinal)`. A final callback is then treated as an append-only string
delta. This cannot correctly represent overlapping or revised time ranges and
is a structural source of duplication and ordering risk under long, fast
speech.

Reference:

- https://developer.apple.com/documentation/speech/recognizing-speech-in-live-audio
- https://developer.apple.com/documentation/speech/speechanalyzer/volatilerange

### 2.4 Queue amplification

The current UI lag is produced by two queues:

1. the final Ollama FIFO must translate every semantic segment;
2. the presentation FIFO holds every completed caption for at least 1.2 s.

When speech produces captions faster than either queue drains, latency grows
without bound. Shortening segmentation alone makes this worse by increasing
request count.

## 3. Correct mental model

There are two different products inside the pipeline:

1. **Transcript/history ledger** — complete, ordered, range-indexed and
   append-only after the Apple finalization frontier passes a span.
2. **Live display window** — bounded, replaceable and allowed to skip obsolete
   preview states so it stays near current speech.

History completeness must not force the overlay to replay stale captions.

```text
SCStream audio PTS
        |
SpeechTranscriber.Result(text + audioRange + finalizationTime)
        |
TranscriptSpanLedger
  - finalized spans: immutable
  - volatile spans: replace intersecting range
        |
TranslationWindowPlanner
  - active foreground window (latest wins)
  - archive work (coalesced, background priority)
        |
Single Ollama worker
        |
LiveCaptionState              Transcript history
  - current translation         - ordered stable source
  - current source              - completed translations
  - measured lag                - never replayed through UI FIFO
        |
One focused overlay
```

## 4. Source transcript design

### 4.1 Range-indexed recognition update

Replace the string-only update with:

```swift
struct LiveSpeechRecognitionUpdate {
    let audioRange: CMTimeRange
    let finalizedThrough: CMTime
    let text: AttributedString
    let isFinal: Bool
}
```

The attributed text must retain Apple's audio-time-range attributes long enough
to resolve word boundaries.

### 4.2 Transcript span ledger

`TranscriptSpanLedger` owns ordered, non-overlapping spans:

```swift
struct TranscriptSpan {
    let id: UUID
    var range: CMTimeRange
    var text: String
    var revision: Int
    var state: State // volatile | finalized
}
```

On every result:

1. locate spans whose audio ranges intersect the incoming result;
2. replace that range with the new result instead of appending text;
3. advance the finalized frontier using `resultsFinalizationTime`;
4. mark spans fully before the frontier immutable;
5. normalize whitespace only after range reconciliation.

Invariants:

- volatile text is replace-by-range;
- finalized spans never change;
- no two stored spans overlap;
- reconstructing the timeline produces each audio range once;
- stop/restart creates a new session and rejects old callbacks.

## 5. Translation window planning

### 5.1 Time-bounded windows

Sentence punctuation is useful but cannot be required in interviews. Build
windows from finalized word ranges with these initial bounds:

- target audio duration: 1.8-2.4 s;
- target English size: 8-14 words;
- preferred close: sentence or clause punctuation;
- second choice: finalized word boundary with two-word lookahead;
- unsafe trailing heads such as `set`, `get`, `to`, `that`, and conjunctions
  wait for lookahead;
- maximum additional wait for semantic safety: 450 ms.

These are planner defaults, not UI dwell times. The display has no fixed 1.2 s
minimum.

### 5.2 One foreground worker

Replace independent preview and final workers with one actor-owned scheduler:

```text
foreground slot: exactly one active request
pending slot: latest foreground window only
archive queue: coalesced and processed only when foreground is idle
```

Rules:

- a newer incompatible foreground revision cancels the obsolete request;
- compatible source growth can keep the last complete translation visible;
- completion is accepted only when session, audio range, segment and revision
  all match;
- a stable foreground result can be reused as the history translation for the
  exact same range;
- archive work merges adjacent untranslated finalized spans instead of issuing
  one request per tiny ASR final callback.

### 5.3 Lag-aware catch-up

Define:

```text
displayLag = latestRecognizedAudioEnd - displayedAudioEnd
```

Initial policy:

- `<= 1.5 s`: normal live mode;
- `1.5-3.0 s`: cancel obsolete preview, merge the latest compatible window;
- `> 3.0 s`: stop presenting old windows, translate the newest stable window;
  retain skipped finalized source ranges in history for background translation.

Skipping an obsolete preview is allowed. Rewriting or dropping an already
displayed committed caption is not.

## 6. Ollama real-time profile

Do not change global Ollama environment variables because LocalTranslate must
not alter concurrency for other local tools. Enforce concurrency inside the
app.

Recommended request profile:

```json
{
  "stream": true,
  "think": false,
  "keep_alive": "10m",
  "options": {
    "temperature": 0,
    "num_ctx": 2048,
    "num_predict": 64
  }
}
```

Model decision for the first implementation:

- retain `qwen3.5:4b` as the inherited default;
- do not switch to TranslateGemma merely for speed because the measured warm
  end-to-end difference was only 11 ms on the sample;
- add a separate `liveSubtitlesModel` setting only if later side-by-side quality
  testing justifies a specialized model;
- never switch models while a live session is running;
- preload the selected model at session start and unload it immediately on stop.

Preview requests should carry no translated-history messages. Stable final
windows may carry at most one previous stable pair when terminology continuity
requires it. This bounds prompt evaluation and prevents old context from
dominating a short current phrase.

The final response metrics should be decoded locally:

- `load_duration`;
- `prompt_eval_duration`;
- `eval_duration`;
- `prompt_eval_count`;
- `eval_count`;
- first-token latency measured by the client.

Release builds must not log transcript content.

## 7. Overlay design

The UI is a current-speech instrument, not a transcript stack.

### 7.1 Running state

- Exactly one primary Simplified Chinese caption, maximum two lines.
- Optional source line below it, maximum one line, 60-70% opacity.
- No previous-caption row while speech is active; history belongs in the drawer.
- Always-visible dark translucent material behind text for contrast. Do not rely
  on shadows over arbitrary video content.
- Adaptive width: `min(screenWidth * 0.72, 980 pt)` instead of a fixed 1180 pt.
- Suggested primary type: 26 pt semibold/bold; source: 14-16 pt medium.
- Simplified Chinese target: prefer around 16 characters per line and never
  exceed 23 characters per line when a natural wrap is possible.
- Controls appear only on hover and must not resize the caption layout.

Netflix's authored-caption guide is not a live-translation scheduler, but its
readability constraints support the same visual boundary: two lines maximum,
center placement, and approximately 23 Simplified Chinese characters as an
upper per-line bound.

References:

- https://partnerhelp.netflixstudios.com/hc/en-us/articles/215758617-Timed-Text-Style-Guide-General-Requirements
- https://partnerhelp.netflixstudios.com/hc/en-us/articles/215274938-What-is-the-maximum-number-of-characters-per-line-allowed-in-Timed-Text-assets

### 7.2 Transition behavior

- Atomic text replacement by default.
- Optional 80-120 ms opacity-only crossfade when Reduced Motion is disabled.
- No move, slide, spring, scale, layout animation or fixed dwell timer.
- When lag exceeds 1.5 s, show a small non-animated `追赶中` status in the hover
  toolbar, not another subtitle line.

Apple's typography guidance favors clear weight/size hierarchy and visible
background shapes for legibility. The SwiftUI implementation must also respect
`accessibilityReduceMotion`.

References:

- https://developer.apple.com/design/human-interface-guidelines/typography
- https://developer.apple.com/documentation/mediaaccessibility/captions

## 8. MVP implementation sequence

1. Preserve ASR audio ranges and implement `TranscriptSpanLedger` with focused
   range-overlap tests.
2. Replace preview/final concurrency with the single latest-wins scheduler.
3. Remove the presentation FIFO and fixed minimum dwell.
4. Implement time-bounded translation windows and lag-aware catch-up.
5. Apply the one-current-caption overlay.
6. Add local latency metrics and remove temporary buffer-content diagnostics.
7. Build and run state tests. Runtime interview acceptance remains user-owned.

Do not start with a new Prompt or a larger model. The measured model service is
already faster than the current queueing and finalization path.

## 9. Acceptance gates

For a user-run 60-second English interview at approximately 160-190 words/min:

- source reconstruction has zero duplicated or missing finalized audio ranges;
- foreground pending depth never exceeds one;
- presentation FIFO depth is always zero;
- median displayed lag <= 1.5 s and p95 <= 2.5 s after warm-up;
- no obsolete caption older than 3 s is replayed to the overlay;
- already displayed committed translations never change;
- overlay contains at most two Chinese lines and one source line;
- no horizontal or vertical text motion;
- stop/pause releases capture, Speech resources and the Ollama model;
- inactive app returns to the project's zero-idle resource baseline.

Automated state tests and source build are engineering evidence. The user's
real interview recording is the runtime and UX acceptance gate.

## 10. MVP implementation result

Implemented on 2026-08-30 against baseline commit `83c30cb`:

- `SpeechTranscriber.Result` is retained as word-level attributed fragments
  carrying `audioTimeRange`; whole-result range is only the fallback.
- `LiveTranscriptSpanLedger` reconciles each callback as one batch. Volatile
  ranges are replaced, finalized ranges are immutable, and finalized spans are
  emitted to downstream planning exactly once.
- `LiveTranslationWindowPlanner` uses a 2.2-second target, 6-14-word bounds,
  punctuation preference, two-word lookahead, unsafe trailing-token checks and
  a 700 ms silence flush.
- Preview, current stable translation and archive work share one Ollama worker.
  The foreground slot is latest-wins; displaced stable work moves to history;
  cancellation fully unwinds before the replacement request starts.
- Completion identity includes session, segment, revision, kind and audio
  range. Stale responses cannot overwrite the current caption.
- The presentation FIFO and fixed dwell were removed. The overlay renders one
  large current caption, an optional one-line source, no previous-caption row,
  no text slide animation, and an always-visible contrast surface.
- When measured lag exceeds 3 seconds, volatile preview translation pauses and
  the newest stable window owns the foreground slot. Source history remains
  ordered and committed translations are inserted only once.
- The inherited `qwen3.5:4b` model remains selected. The live request profile is
  `temperature=0`, `num_ctx=2048`, `num_predict=64`, `think=false`, with at most
  one prior stable pair as context.

Engineering verification:

- Focused state harness: `14 passed`.
- Unsigned Xcode source build: `BUILD SUCCEEDED`.
- Diff whitespace check: passed.
- The app was not launched and no interview playback was performed in this
  implementation turn. Display-lag percentiles, real ASR reconstruction and
  visual experience remain the user's runtime acceptance gate.

## 11. First runtime acceptance correction

The first user-run screenshot exposed an English-only regression: a stable
translation request received the foreground identity, but the next partial ASR
callback immediately replaced that identity with a source-only preview state.
After lag crossed three seconds, catch-up mode disabled preview requests, so a
completed stable translation could enter history without becoming the current
caption.

The display pair and live ASR candidate are now separate states:

- partial growth updates only the next translation candidate;
- an in-flight preview or stable request is not replaced on every ASR callback;
- a finalized translation remains visible until another complete translation
  atomically replaces it;
- an incompatible ASR correction may clear only an unstable preview, never a
  finalized displayed translation;
- the initial preview remains allowed before any translated audio range has
  been displayed, even if absolute recognition time has already passed three
  seconds.

Source build after this correction: `BUILD SUCCEEDED`. A repeated interview run
is still required for runtime acceptance.

## 12. Live-first correction after qualitative rejection

The user rejected the final-first runtime tradeoff as both slower and harder to
understand than the original experience. Finalized translation is therefore
removed from the continuous-speech foreground path:

- the current overlay is driven by complete, atomically swapped preview
  translations;
- finalized windows are archive/history work and can seed the overlay only at
  a caught-up silence boundary;
- the preview throttle starts on the first eligible callback instead of
  repeatedly debouncing on every ASR revision;
- preview readiness begins at four words but still rejects unsafe phrase heads
  and connective tails such as `set`, `that` and `because`;
- one preview request is allowed to finish while compatible source continues
  growing; token streaming is never exposed to the UI;
- preview input is capped to the latest 14 words and carries one previous
  displayed translation pair as context;
- a rolling preview shifts only after at least three new words, preventing
  one-word full-caption rewrites;
- the archive worker waits 120 ms before starting so the next live preview can
  claim the single Ollama slot without needless start/cancel churn;
- finalized history windows use 8-16 words and a 2.6-second target for better
  semantic completeness.

Focused state harness remains `14 passed`; unsigned source build remains
`BUILD SUCCEEDED`. Runtime quality remains user-owned acceptance evidence.
