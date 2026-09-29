// diar_crispasr.h - the Nemotron-3 diarizer's encoder (all layers) + head, run on CrispASR's own ggml.
//
// docs/one-runtime-merge.md: this is the "actual merge" the whole port existed for. The op sequence here is
// NOT new - it is tools/encoder_port.cpp and tools/head_port.cpp's already-verified-byte-exact sequence
// (see docs/one-runtime-merge.md SS13-15), restructured as a reusable class instead of a one-shot CLI tool:
// weights load once, the graph is rebuilt per call (frame count is a graph dimension that changes call to
// call - ensure_encoder_graph in ref/audiocpp does the same thing for the same reason).
//
// What this does NOT reimplement: the mel frontend, streaming window scheduling, the arrival-order
// speaker-cache state, and turn decoding all stay audio.cpp's own code, unmodified, via
// audiocpp_nemotron3_diar_set_external_encoder (ref/audiocpp, deps.lock audiocpp>=4d3de79) - this class is
// exactly what gets plugged into that hook.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace nemo {

class DiarCrispASR {
public:
    // Loads every "encoder.layers.<i>.*" weight set (i = 0.. until one is missing) plus the head
    // ("encoder.final_norm", "sortformer_modules.*") from `gguf_path`. Throws std::runtime_error on any
    // missing tensor - this is the ONE place that must fail loudly rather than silently substitute a wrong
    // shape, since nothing downstream re-validates against the GGUF.
    explicit DiarCrispASR(const std::string & gguf_path, int threads = 2);
    ~DiarCrispASR();

    DiarCrispASR(const DiarCrispASR &) = delete;
    DiarCrispASR & operator=(const DiarCrispASR &) = delete;

    // Matches Session::encode()'s own signature exactly (ref/audiocpp session.h) so this can be wired
    // directly into the external-encoder hook: `embeddings` is `batch * frames * hidden` packed
    // [speaker_cache | fifo | chunk] frames, row-major; `valid_frames` has `batch` entries (only batch==1 is
    // supported - the same restriction Session::process_window_batch already enforces in streaming mode).
    // Returns `batch * frames * num_speakers` probabilities, row-major.
    std::vector<float> encode(
        const std::vector<float> & embeddings,
        int64_t batch,
        int64_t frames,
        const std::vector<int64_t> & valid_frames);

    int64_t hidden_size() const;
    int64_t num_speakers() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace nemo
