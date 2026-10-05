# Provenance of `mfa/`

The mobile meeting reader's engine (voxsumdroid-integration.md §13, meeting-summarizer).

| File | Source |
|---|---|
| `i8_attn.cc`, `i8_attn.h` | github.com/vieenrose/LiteRT-LM, branch `mobile-fused-attention`, `contrib/mobile_fused_attention/cpp/`, unchanged |
| `mfa_engine.cc`, `mfa_engine.h` | the same directory's `mfa_engine.cc`, refactored into a resident library (option B of §13.3): the `--serve` loop's prefill / step / sample and its prefix reuse became `mfa::Engine`; every fatal path throws instead of `exit()`, because the engine runs in the app's process; synced with fork commit `bd9d499` (embedder-table page release) |
| `mfa_jni.cpp` | written for VoxSum: JNI for `MfaEngine` and the SentencePiece `SpTokenizer` |
| `third_party/litert/c/*.h` | github.com/google-ai-edge/LiteRT tag `v2.1.6`, `litert/c/` (Apache-2.0, `third_party/LICENSE-LiteRT`) — the C API of the `libLiteRt.so` in the `com.google.ai.edge.litert:litert:2.1.6` AAR |
| `third_party/litert/build_common/build_config.h` | generated from that tag's `build_config.h.in`, with GPU and NPU disabled |

`libLiteRt.so` itself is not vendored: the Gradle task `extractLiteRt` takes it from the AAR.

## iOS copy (ios/native/mfa)
Same sources as the Android `cpp/mfa/`, except `i8_attn.cc`: its five `#pragma omp parallel for` loops became `par_static` / `par_dynamic` (OpenMP when present, libdispatch on Apple, which has no OpenMP). `mfa_c.{h,cpp}` is the C surface the Swift side calls (twin of `mfa_jni.cpp`).
