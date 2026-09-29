# Architecture — VoxSum Python → Android

How each piece of the original FastAPI app maps onto the on-device Android app.

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
| NDJSON events | `core/events/TranscriptEvent.kt` | sealed Flow events |
| `asr.py::transcribe_file` + `diarization.py` | `core/asr/NemoStreamEngine.kt` + `cpp/nemo/` | ONE streaming pass: X-ASR (CrispASR) + Nemotron-3 diarization (audio.cpp) on one timeline |
| `summarization.py::summarize_transcript` | `core/llm/Summarizer.kt` | map-reduce, LangChain dropped |
| `get_llm` (lru_cache) | `core/llm/LlmEngine.kt` + `llm_jni.cpp` | one model resident |
| `utils.py` registry + lazy download | `core/models/ModelManager.kt` | revision- and SHA-256-pinned |
| `get_speaker_color` | `data/Session.kt::speakerColor` | same palette idea |
| global `state` (app.js) | `data/Session.kt` | reset on new audio source |
| ffmpeg / yt-dlp ingest | `core/audio/AudioDecoder.kt` (MediaCodec) | ffmpeg removed |

## What changes and why

- **LangChain is dropped.** It was used only for chunking + prompt templates; both are a
  few lines of Kotlin. LLM inference runs on llama.cpp (`core/llm/LlmEngine.kt` over
  `cpp/llm_jni.cpp`) — the same runtime, and the same pinned GGUF, as the desktop build.
- **ffmpeg is dropped.** `ffmpeg-kit` was archived in 2025; MediaCodec covers decode and
  removes a native dep + license question for F-Droid.
- **Podcast/YouTube are optional.** Network ingestion can't be offline anyway; gating it
  keeps the default build free of the `NonFreeNet` anti-feature. Podcast RSS may return as
  an opt-in flavor.
- **Models are openly licensed.** ASR: X-ASR zh-en (Apache-2.0); diarization: Nemotron-3
  Diarization (OpenMDW-1.1); summarizer models are listed in `LlmRegistry.kt`.

## Memory model (the on-device constraint that shapes everything)

A phone can't hold the ASR/diarization models and a multi-GB LLM resident at once.
The service runs the pipeline in two phases with a hard release between them:

```
decode → [streaming ASR + diarization, one pass] → [emit Complete] → release both GGUFs
        → load GGUF (mmap) → summarize (stream) → release LLM
```

This is why summarization is a distinct phase, not interleaved with transcription.

## Streaming ASR + diarization (`app/src/main/cpp/nemo`)

Vendored from [nemo-x-asr-diarizer.cpp](https://github.com/vieenrose/nemo-x-asr-diarizer.cpp)
(`engine`, `fusion`, `diar_crispasr`), with a push API added (`Engine::begin/push/finish/snapshot`)
so microphone and file audio both stream through the same loop. Every 100 ms piece goes to the
Nemotron-3 diarizer first, then to X-ASR; the fusion layer tags each word with the speaker turn
that covers it. Words appear ~0.4 s after they are spoken; turns commit ~5 s behind, so the
Kotlin side emits replace-all `UtteranceSnapshot`s and the last one (after end of input) is final.

Three ggml copies share the process (llama.cpp's, CrispASR's, audio.cpp's). audio.cpp builds as
`libaudiocpp.so` with its ggml hidden behind a version script; CrispASR and its ggml link
statically into `libvoxsum-nemo.so`, which exports only JNI symbols. Both are CMake
ExternalProjects from the `native/audiocpp`, `native/crispasr` and `native/crispasr-ggml`
submodules, compiled for the ARMv8.0 floor like llama.cpp.

`tools/nemo-eval/` drives the same engine on the host for accuracy runs.
