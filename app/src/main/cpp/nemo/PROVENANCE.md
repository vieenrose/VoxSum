# Provenance — app/src/main/cpp/nemo

`engine.{h,cpp}`, `fusion.{h,cpp}`, `diar_crispasr.{h,cpp}` and `wav.h` are vendored from
[vieenrose/nemo-x-asr-diarizer.cpp](https://github.com/vieenrose/nemo-x-asr-diarizer.cpp) at commit
`1ca654c` (Apache-2.0, see `LICENSE`). Its dependency pins (`deps.lock`) match this repo's submodules:
`native/crispasr` 657bc15, `native/crispasr-ggml` 512a020, `native/audiocpp` 8344bbe.

Modified for VoxSumDroid (marked "VoxSumDroid" in the source):
- `Engine::run` split into a push API — `begin()`, `push()`, `finish()` — so microphone and file
  audio stream through the same loop. Output is byte-identical to upstream's `run()` on the
  reference clip (checked with `tools/nemo-eval`).
- Live view: `Engine::live()` + `Fusion::attribute_from()` re-attribute only the unsettled tail and
  freeze segments once they are `Config::live_settle_s` behind the audio and covered by committed
  turns; the segment builder is shared with the final pass (`build_segments`), whose output is
  unchanged (byte-identical on three reference clips).
- `attribute()`: punctuation the ASR emits at a turn start is handed back to the previous speaker, and
  a long single-speaker run is split after a sentence end (`Config::max_segment_s`, off by default).

`nemo_jni.cpp`, `nemo_jni.map` and `crispasr_ggml.cmake` are written for this repo.
