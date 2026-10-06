# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

VoxSum for Android: a fully offline audio → speaker-labelled transcript → summary app (Kotlin + Jetpack Compose, native engines via JNI). A port of a Python/FastAPI app; `docs/ARCHITECTURE.md` maps each Python piece to its Android counterpart.

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
- **ASR + diarization is ONE streaming engine**: nemo-x-asr-diarizer, vendored in `app/src/main/cpp/nemo` (X-ASR via CrispASR + Nemotron-3 diarization via audio.cpp, fused per word). Kotlin side: `core/asr/NemoStreamEngine.kt`, which emits replace-all `UtteranceSnapshot`s (speaker labels near the live edge are provisional ~5 s). Two ggml copies share the process — audio.cpp's is hidden in `libaudiocpp.so`, CrispASR's is static inside `libvoxsum-nemo.so` (JNI-only exports); never make them share symbols. Everything native is built for `armv8.2-a+dotprod` (`VOXSUM_ARM_ARCH` in CMakeLists.txt); ARMv8.0 devices are refused at launch (`CpuSupport.kt`). No i8mm: the Dimensity reference phones lack it.
- **Summarizer = live meeting reader** (`core/reader/`): Gemma-4 meeting agent in Google's mobile graph format — E2B mobile-v1 by default, E4B selectable on 8 GB phones (pinned in `LlmRegistry` with its `system_prompt.txt`, must stay paired) — on the forked LiteRT-LM CPU engine (`cpp/mfa/`, `core/llm/MfaEngine.kt`; stock `libLiteRt.so` from the LiteRT AAR, SentencePiece tokenizer). The engine reuses the longest cached prompt prefix instead of sessions; `MfaSession` is the `ReaderLlm`. 4k context: `ReaderBudget.MOBILE` (window 1500, journal 1200) and title/prose on notes compacted to 3,900 chars. `ReaderProtocol.kt` + `MeetingReader.kt` are a port of upstream `eval/phone_live.py` (vieenrose/meeting-summarizer) — the model is fine-tuned on that exact text; `ReaderParityTest` replays goldens made by running the REAL `phone_live.py` (`tools/reader-parity/make_golden.py`; `--mobile` for the 4k one, with `compact_notes`) and must stay byte-identical. Summary = prose written from the notes by one extra call after reading (`ReaderLane.prose`, not part of the upstream protocol; fallback: notes grouped by type); `AgentEvent`s drive the Agent panel (`ui/AgentPanel.kt`). llama.cpp was removed 2026-10-03.
- **Threads** (`core/hw/HwProfile.kt`, `ThreadBench.kt`): `HwInfo.threads()` feeds every native engine. Auto = a ~1 s first-launch benchmark (re-run per SoC + app version, or from Settings > Inference) measuring every count from 2 to all the cores, keeping the fewest threads within 5 % of the best, else the cpufreq heuristic (2..4, never above the core count); Settings has an Auto chip and, with Auto off, a slider from 2 to the core count. A reader failure at >2 threads caps Auto at 2 until the next benchmark; live mode also needs ≥ 6 cores.
- **Backends** (`core/hw/Backend.kt`, `docs/GPU_NPU.md`): the reader runs on CPU by default; `MfaEngine.load(..., backend)` can ask LiteRT for GPU / NPU, but both are hidden from users (`Backend.offered` = CPU only; with more entries Settings shows the picker + a card per backend). The Settings benchmark loads the reader on each backend with a fixed prompt, keeps a card per result, and the GPU is selectable only once its test passed (a crash leaves a flag that marks the backend failed at next launch; a failed load falls back to CPU). Today GPU fails to compile the fused graph (Adreno 640: 73 of 2,580 nodes) and no NPU dispatch library ships. The status line shows GPU / NPU only while the reader uses them.
- **Models** (`core/models/ModelManager.kt`): lazily downloaded, HF-revision- and SHA-256-pinned.
- **Sessions/library** (`core/session`, `core/library`, `data/Session.kt`): recordings are saved immediately on stop; a persistent processing queue survives app kills and batches work so the LLM loads once per batch. Finished sessions embed transcript + summary into the `.m4a`.
- Network sources (podcast, YouTube via NewPipeExtractor from JitPack) live in `online/` and are optional.

## Build/release notes

- NDK is pinned (`29.0.14206865`); minSdk 26. Native deps are submodules: `native/sentencepiece`, `native/audiocpp`, `native/crispasr`, `native/crispasr-ggml` (CrispASR's own nested ggml is replaced by the last via `nemo/crispasr_ggml.cmake`).
- Releases: bump `versionCode`/`versionName` in `app/build.gradle.kts`, push a `v*` tag; `.github/workflows/release.yml` builds a signed APK and attaches it to a GitHub Release (no F-Droid). Every release gets notes in English (what changed for users, fixes with their issue numbers, install line): after the workflow creates the release, `gh release edit vX.Y.Z --notes-file <file>`.
- The app supports English, 繁體中文 and 简体中文 (`values/`, `values-zh-rTW/`, `values-zh-rCN/`) — keep user-facing strings in sync across all three. `values-zh-rCN` is generated from zh-TW (OpenCC `TSPhrases`/`TSCharacters` plus a Taiwan→mainland UI vocabulary); `ResourceLanguageTest` guards keys, placeholders and script purity. The Settings language (`AppLanguage`: system / English / 繁體 / 简体) sets the interface AND the Han script of everything generated (transcript, summary, title, actions, agent notes, library titles). The README is Chinese only.
