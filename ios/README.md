# VoxSum iOS — native engine feasibility (2026-10-05)

Built on a MacBook Pro 16,3 (Intel, macOS 15.7, Xcode 26.2, iOS 26.2 SDK) with `ios/native/build_ios.sh`
(cmake 3.31.6 installed in `~/tools`; Homebrew is not writable there).

| Piece | Result |
|---|---|
| CrispASR x-asr + pinned ggml fork (static) | builds: simulator x86_64 and device arm64 |
| audio.cpp diarization (`libaudiocpp.dylib`, ggml hidden, 75 exported symbols, 0 `ggml_*`) | builds: simulator x86_64 and device arm64 |
| `nemo/` glue (engine, fusion, diar_crispasr) | compiles for iOS arm64 (syntax check) |
| `mfa/` LiteRT-LM fork (mfa_engine.cc, i8_attn.cc) | compiles for iOS arm64 (syntax check) |
| LiteRT runtime | `CLiteRTLM.xcframework` v0.17.1 exports the full LiteRT C API incl. `LiteRtAddCustomOpKernelOption` → the fused-attention custom op can link against it |

Changes needed vs Android: deployment target 17.0 (`std::to_chars`), `ru_minflt` (profiling only) patched out of
audio.cpp, a no-op `set_xcode_property` for sentencepiece, OpenMP off (CrispASR kernels run single-threaded
until an iOS libomp is wired in), Metal/Accelerate/BLAS off.

Known limits: CLiteRTLM ships arm64 device + arm64 simulator slices only — no x86_64 — so this Intel Mac can
build but not run the reader in the simulator; running needs a real iPhone (no signing identity configured yet).
Not done yet: JNI → C/Swift bridge for nemo and mfa, linking `libvoxsum-nemo`, Xcode/SwiftUI project.

## CLI check on the iOS simulator (`build_nemo_eval.sh`)

`nemo_eval` (the app's engine, driven from the command line) built for iphonesimulator x86_64 and run with
`xcrun simctl spawn` on an iPhone 17 Pro simulator, on `diar_ref_2spk_123s.wav` (123 s, 2 speakers), against the
Linux host build of the same sources:

| | Linux host (4 threads) | iOS simulator (x86_64, no OpenMP) |
|---|---|---|
| speakers / diarizer turns | 2 / 57 | 2 / 57 |
| transcript text | — | identical (similarity 1.0000) |
| speaker label per second | — | 108/119 agree (91 %); the host agrees with itself at 119/119 across 1 and 4 threads |
| wall / RTF | 47 s / 0.38 | 208 s / 1.69 (1.4 GHz Intel i5, single-threaded — not representative of an iPhone) |

The label differences start where speech overlaps (~48 s) and are ±10–20 ms on most turn edges. Likely cause: the
iOS build uses baseline x86 SIMD kernels (`GGML_NATIVE=OFF`) where the host build uses AVX2, i.e. float-rounding
differences in the diarizer — not verified. `engine.cpp` needs `apple_sched_shim.h` (Linux CPU affinity).

## État (reader + app)

- Le lecteur de réunion (protocole, `MeetingReader`, `ReaderSummarizer`) est porté en Swift, identique octet par octet aux goldens Android (`tests/run.sh`).
- `native/mfa/` : moteur LiteRT (CPU) + SentencePiece compilés pour iOS arm64 (`native/build_mfa_lib.sh`). Lien/ABI avec `CLiteRTLM.xcframework` à valider sur un iPhone.
- Simulateur Intel : x86_64 uniquement, donc `StubLlm` (notes simulées) ; `MfaSession` n'est compilé que pour l'appareil.
- Prochain pas sur iPhone : signature (Apple ID), `build_app.sh iphoneos arm64` (lien mfa + sentencepiece + CLiteRTLM, à intégrer au bundle), téléchargement des modèles du lecteur, mesure de vitesse ASR (ggml sans OpenMP = mono-thread).
