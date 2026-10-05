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
