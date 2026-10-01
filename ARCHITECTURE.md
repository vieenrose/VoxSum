# Architecture — VoxSum Python → Android

How each piece of the original FastAPI app maps onto the on-device Android app, and how the
Android-only parts (live meeting reader, session library, queue) fit together.

## The core inversion: HTTP streaming → Kotlin Flow

VoxSum's defining pattern is the **NDJSON streaming contract**: long endpoints return a
`StreamingResponse` of typed JSON lines, and `frontend/app.js` renders incrementally.

On-device there is no HTTP. The same typed events become
[`TranscriptEvent`](app/src/main/java/studio/voxsum/core/events/TranscriptEvent.kt), emitted
as a `Flow` from a **foreground service** and collected by Compose. Incremental rendering
(append new utterances, never full rebuild) is preserved.

| Python (`src/`) | Android | Notes |
|---|---|---|
| `server/routers/api.py` (HTTP) | `service/TranscriptionService.kt` | foreground service, not a router |
| NDJSON events | `core/events/TranscriptEvent.kt` | sealed Flow events; `AgentEvent`s ride inside for the Agent panel |
| `asr.py::transcribe_file` + `diarization.py` | `core/asr/NemoStreamEngine.kt` + `cpp/nemo/` | ONE streaming pass: X-ASR (CrispASR) + Nemotron-3 diarization (audio.cpp) on one timeline |
| `summarization.py::summarize_transcript` | `core/reader/` (`MeetingReader`, `ReaderLane`, `ReaderProtocol`) | live reading agent over a KV-keeping llama.cpp session |
| `get_llm` (lru_cache) | `core/llm/LlmEngine.kt` + `cpp/llm_jni.cpp` | one model resident |
| `utils.py` registry + lazy download | `core/models/ModelManager.kt`, `LlmRegistry.kt` | revision- and SHA-256-pinned |
| `get_speaker_color` | `data/Session.kt::speakerColor` | same palette idea |
| global `state` (app.js) | `data/Session.kt` | reset on new audio source |
| ffmpeg / yt-dlp ingest | `core/audio/AudioDecoder.kt` (MediaCodec), `online/` | ffmpeg removed |

## What changes and why

- **LangChain is dropped.** It was used only for chunking + prompt templates; both are a
  few lines of Kotlin. Inference runs on llama.cpp, the same runtime as the desktop build.
- **The summarizer is an agent, not a map-reduce.** The model reads the transcript as it
  arrives and writes typed, cited notes (see "Meeting reader"); the summary is written from
  those notes. The old chunked summarizer, verifier and action-item extractor are gone —
  action items are the reader's `ACTION` notes.
- **ffmpeg is dropped.** `ffmpeg-kit` was archived in 2025; MediaCodec covers decode and
  removes a native dependency and a license question.
- **Podcast/YouTube are optional.** Network ingestion (`online/`, NewPipeExtractor from JitPack)
  can't be offline anyway; the only other network traffic is the model download and a daily
  update check. Releases are GitHub APKs only (`RELEASING.md`).
- **Models are openly licensed.** ASR: X-ASR zh-en (Apache-2.0); diarization: Nemotron-3
  Diarization (OpenMDW-1.1); summarizer: the Gemma-4-E2B meeting agent (Apache-2.0).

## Three concurrent lanes

With ~8 GB of RAM (`LIVE_READER_MIN_RAM` = 7 GiB of `totalMem`), recording and imports run three
lanes at once:

```
mic/decode → [NemoStreamEngine: ASR + diarization] → UtteranceSnapshot (stable prefix)
                                                        ↓ ReaderLane (low-priority thread)
                              MeetingReader: prefill segments while people talk → every ~2k tokens
                              a reading turn writes typed, cited notes → prose summary at stop
```

ASR keeps priority — it is the only lane that loses data when late; the reader queues lines and
catches up. Below the RAM gate the old order stays: ASR + diarization, release, then the reader
post-hoc over the finished transcript (same protocol). The queue drain transcribes every item,
then loads the reader once for all of them.

## Streaming ASR + diarization (`app/src/main/cpp/nemo`)

Vendored from [nemo-x-asr-diarizer.cpp](https://github.com/vieenrose/nemo-x-asr-diarizer.cpp)
(`engine`, `fusion`, `diar_crispasr`), with a push API added (`Engine::begin/push/finish/snapshot`)
so microphone and file audio both stream through the same loop. Every 100 ms piece goes to the
Nemotron-3 diarizer first, then to X-ASR; the fusion layer tags each word with the speaker turn
that covers it. Words appear ~0.4 s after they are spoken; turns commit ~5 s behind, so the
Kotlin side emits replace-all `UtteranceSnapshot`s and the last one (after end of input) is final.

Speakers are always produced: there is no switch to turn diarization off, and re-running it on the
same audio gives the same tags. The only setting is the *live* speaker delay (5–30 s), which
changes when the booth freezes a line's speaker, not the saved transcript.

Three ggml copies share the process (llama.cpp's, CrispASR's, audio.cpp's). audio.cpp builds as
`libaudiocpp.so` with its ggml hidden behind a version script; CrispASR and its ggml link
statically into `libvoxsum-nemo.so`, which exports only JNI symbols. Both are CMake
ExternalProjects from the `native/audiocpp`, `native/crispasr` and `native/crispasr-ggml`
submodules, compiled for `armv8.2-a+dotprod` like llama.cpp (ARMv8.0 devices are unsupported,
checked by `core/power/CpuSupport.kt`).

`tools/nemo-eval/` drives the same engine on the host for accuracy runs.

## Meeting reader (`core/reader/`)

The summarizer is a Gemma-4-E2B model fine-tuned as a reading agent (pinned in `LlmRegistry`; the
weights and `system_prompt.txt` live together under `v5/` and must stay paired).

- **Session.** `llm_jni.cpp` exposes a KV-keeping llama.cpp session (`nativeAppend`,
  `nativeGenerateContinue`, `nativeReset`) wrapped by `ReaderLlm`; every call runs on the lane's
  single thread.
- **Protocol.** `ReaderProtocol` + `MeetingReader` are a port of upstream `eval/phone_live.py`
  (vieenrose/meeting-summarizer): journal header, ~20 s segments, a window closed at ~2,000 tokens,
  a reading turn of up to 400 tokens writing `NOTE [m:ss] (TYPE) text` lines (DECISION, ACTION,
  NUMBER, OPEN-ISSUE, PROPOSAL), a guard that files suggestions as PROPOSAL (`reclassify`), and a
  restart with a compacted journal when the 8,192-token budget would be passed. The model was
  trained on this exact text, so deviations cost quality.
- **Parity.** `ReaderParityTest` replays a golden produced by running the real `phone_live.py`
  (`tools/reader-parity/make_golden.py`); the Kotlin output must stay byte-identical.
- **After reading.** `ReaderLane.prose` writes the summary as prose from the notes with one extra
  call (not part of the upstream protocol; fallback: the notes grouped by type), then the title.
  Action items are the journal's `ACTION` notes.
- **UI.** `AgentEvent`s (state, fed segments, streamed reply tokens, kept/dropped notes) drive the
  Agent strip in the booth and the Agent panel on the session screen (`ui/AgentPanel.kt`). Notes
  are working notes, not minutes: decisions, actions and numbers carry a "check" chip that jumps
  to the quoted line.

## Sessions, library and queue

- **Recordings are saved the moment you stop** (`core/library/SessionLibrary.kt`, `RecordingRecovery`),
  so a crash or a wrong tap loses nothing; an interrupted capture is offered for recovery.
- **Processing queue** (`core/library/ProcessingQueue.kt`): persistent, survives app kills, and
  batches work so each model loads once per batch. "Next talk" saves and starts the next
  recording while the previous one waits in the queue.
- **Session files** (`core/session/VoxsumSession.kt`): a finished session embeds transcript,
  speakers, summary, action items and notes into the `.m4a`, which plays anywhere and reopens in
  VoxSum (legacy `.ogg` sessions still open, but are no longer written). Autosave (`SessionAutosave`) keeps edits.
- **Exports** (`core/export/`): PDF, Markdown, plain text and SRT/VTT/LRC subtitles.
- **Edits** (`data/SpeakerEdits.kt`): reassign a line to another speaker, merge two speakers,
  rename; these are pure relabels, the saved file round-trips them.
- **Chinese script.** All generated and transcribed text is normalized to Traditional or
  Simplified through OpenCC (`core/text/OpenCcConverter.kt`).

## UI (`ui/`)

Compose, Material 3, one palette object (`ui/theme`) with light, dark and e-ink variants. The
screens are `StudioScreen` (library and first run), `CaptureScreen` (the booth), the session screen
in `MainActivity` (Summary · Transcript · Actions tabs and the player), and `SettingsContent`.
