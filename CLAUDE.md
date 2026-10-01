# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

VoxSum for Android: a fully offline audio → speaker-labelled transcript → summary app (Kotlin + Jetpack Compose, native llama.cpp via JNI). A port of a Python/FastAPI app; `ARCHITECTURE.md` maps each Python piece to its Android counterpart.

## Commands

```bash
git submodule update --init          # NOT --recursive: audio.cpp's nested submodule is an SSH URL
./gradlew assembleDebug              # arm64-v8a by default; override with -PvoxsumAbi=x86_64 (emulator)
./gradlew testDebugUnitTest          # JVM unit tests (app/src/test)
./gradlew testDebugUnitTest --tests 'studio.voxsum.core.llm.SummarizerTest'   # single class/method
scripts/test-on-device.sh [serial]   # instrumented tests on a device — use this, NOT connectedAndroidTest
```

- `connectedAndroidTest` uninstalls the release-signed app first, wiping the user's sessions and ~1.7 GB of models. `scripts/test-on-device.sh` installs under `-PisolatedTestId` (`studio.voxsum.androidtest`) so it coexists; read its header for known "Unable to resolve activity" pitfalls.
- `tools/nemo-eval/build_host.sh` builds a host driver of the ASR+diarization engine (see `tools/nemo-eval/README.md` for the AMI/AISHELL-4 accuracy run); `tools/validate_llm.py`, `tools/faithfulness.py` — offline LLM/summary quality checks.
- Only `:app` is in the Gradle build; `shared/` and `desktop/` are not included modules.

## Architecture

- **Pipeline runs in a foreground service** (`service/TranscriptionService.kt`) and emits typed `core/events/TranscriptEvent` values as a Kotlin `Flow`; Compose UI renders incrementally (append, never rebuild). This replaces the original NDJSON streaming contract.
- **Three concurrent lanes (live mode, 8 GB phones: gate `LIVE_READER_MIN_RAM` = 7 GiB of totalMem)**: ASR + diarization, and the meeting reader reading the transcript as it becomes stable — both resident at once, the reader on a low-priority thread (ASR is the only lane that loses data when late). Below that RAM the reader runs after transcription (same protocol). The queue drain transcribes everything, then loads the reader once.
- **ASR + diarization is ONE streaming engine**: nemo-x-asr-diarizer, vendored in `app/src/main/cpp/nemo` (X-ASR via CrispASR + Nemotron-3 diarization via audio.cpp, fused per word). Kotlin side: `core/asr/NemoStreamEngine.kt`, which emits replace-all `UtteranceSnapshot`s (speaker labels near the live edge are provisional ~5 s). Three ggml copies share the process — audio.cpp's is hidden in `libaudiocpp.so`, CrispASR's is static inside `libvoxsum-nemo.so` (JNI-only exports); never make them share symbols. Everything native is built for `armv8.2-a+dotprod` (`VOXSUM_ARM_ARCH` in CMakeLists.txt); ARMv8.0 devices are refused at launch (`CpuSupport.kt`). No i8mm: the Dimensity reference phones lack it.
- **Summarizer = live meeting reader** (`core/reader/`): Gemma-4-E2B meeting agent **v5** (pinned in `LlmRegistry`, weights+prompt under `v5/`, must stay paired) over a KV-keeping llama.cpp session (`nativeAppend` / `nativeGenerateContinue` / `nativeReset` in `llm_jni.cpp`). `ReaderProtocol.kt` + `MeetingReader.kt` are a port of upstream `eval/phone_live.py` (vieenrose/meeting-summarizer) — the model is fine-tuned on that exact text; `ReaderParityTest` replays a golden made by running the REAL `phone_live.py` (`tools/reader-parity/make_golden.py`) and must stay byte-identical. Summary = prose written from the notes by one extra call after reading (`ReaderLane.prose`, not part of the upstream protocol; fallback: notes grouped by type); `AgentEvent`s drive the Agent panel (`ui/AgentPanel.kt`).
- **Models** (`core/models/ModelManager.kt`): lazily downloaded, HF-revision- and SHA-256-pinned.
- **Sessions/library** (`core/session`, `core/library`, `data/Session.kt`): recordings are saved immediately on stop; a persistent processing queue survives app kills and batches work so the LLM loads once per batch. Finished sessions embed transcript + summary into the `.m4a`.
- Network sources (podcast, YouTube via NewPipeExtractor from JitPack) live in `online/` and are optional.

## Build/release notes

- NDK is pinned (`27.2.12479018`); minSdk 26. Native deps are submodules: `native/llama.cpp`, `native/audiocpp`, `native/crispasr`, `native/crispasr-ggml` (CrispASR's own nested ggml is replaced by the last via `nemo/crispasr_ggml.cmake`).
- Releases: bump `versionCode`/`versionName` in `app/build.gradle.kts`, push a `v*` tag; `.github/workflows/release.yml` builds a signed APK and attaches it to a GitHub Release (no F-Droid). See `RELEASING.md`.
- The app supports English and 繁體中文 only (`values/`, `values-zh-rTW/`) — keep user-facing strings in sync across both. The README is Chinese only.
