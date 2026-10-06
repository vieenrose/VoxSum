# GPU / NPU for the reader — study and result (2026-10-06)

**Verdict: not viable today with the shipped graphs. The app measures it on each phone, keeps the CPU as the default and unlocks GPU / NPU in Settings only when their test passes.**

## What LiteRT offers (2.2.0)
- `CompiledModel` takes a bitmask of accelerators (`kLiteRtHwAcceleratorCpu | Gpu | Npu`); ops an accelerator cannot take stay on the CPU.
- GPU: ML Drift (OpenCL / OpenGL), `libLiteRtClGlAccelerator.so` in the `litert` AAR (now packaged, 3 MB).
- NPU: Qualcomm AI Engine Direct (QNN / HTP) through a vendor dispatch library (`libLiteRtDispatch_Qualcomm.so` + the `libQnnHtp*` set), AOT or on-device compilation. Documented SoCs include Snapdragon 8 Elite Gen 5 (SM8850, HTP v81, the Poco F9 Ultra's chip) and 8 Elite (SM8750). Google ships NPU-ready Gemma graphs through LiteRT-LM, in a different packaging from the mobile-v1 graphs we use.

## Why the reader's graph does not map onto them
- `prefill_decode_fused.tflite` carries the custom op `voxsum.i8_attention` (the fused int8 attention, a CPU kernel) and Google's int4/int8 blocks.
- Measured on the Note10+ (Adreno 640, LiteRT 2.2.0): the GPU delegate takes **73 of 2,580 nodes** of the decode graph and then fails to build its kernel (`Tensor can be used with BufferDescriptor only with TensorStorageType::BUFFER`), so `LiteRtCreateCompiledModel` returns an error. The app reports "this chip cannot run the reader's operations".
- NPU: no dispatch library ships in the app (about 30 MB of Qualcomm libraries, plus a graph compiled for the chip), so the NPU test reports "this build has no runtime for it". It could not be tried here: no Snapdragon 8 Elite (Gen 5) phone was available.

## What the app does
- **Benchmark** (Settings > Inference > Run benchmark): thread benchmark, then the reader model on CPU and GPU with the same fixed prompt (80 tokens read, 16 written); a card per backend. The NPU is not offered in the app for now (`Backend.offered`); the engine still accepts it.
- **Choice**: CPU is the default. GPU / NPU chips are greyed until their test passed on this phone and app version; a failed load later falls back to the CPU on its own.
- **Crash guard**: a GPU / NPU probe that kills the process is recorded as "crashed" on the next launch and stays off.
- **Status line**: the GPU gauge appears only while the reader runs on the GPU; an NPU tag only while it runs on the NPU (no app-readable NPU load exists).
- Measured on the Note10+: CPU 6.0 tokens/s written, 36 tokens/s read (E4B); GPU and NPU not usable.

## To make it work on a Snapdragon 8 Elite Gen 5
1. A reader graph without the custom attention op (Google's stock graph) for the GPU, or an NPU-compiled graph (AOT for SM8850) from the LiteRT-LM NPU flow.
2. Ship `libLiteRtDispatch_Qualcomm.so` and the QNN HTP v81 libraries (arm64 only), set the dispatch-library directory in the environment options.
3. Run the in-app benchmark on the Poco F9 Ultra: the cards say whether it pays off.
