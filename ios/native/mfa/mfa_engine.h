// mfa_engine.h - the forked LiteRT-LM CPU engine for Gemma-4 mobile graphs (E2B, E4B), as a
// resident in-process library. Refactored from contrib/mobile_fused_attention/cpp/mfa_engine.cc
// (github.com/vieenrose/LiteRT-LM, branch mobile-fused-attention): the --serve loop's prefill /
// step / sample and its "fed" prefix became this class; every fatal path throws instead of
// exit()ing, because the engine now lives in the app's process. See PROVENANCE.md.
#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace mfa {

struct Stats {
    int prefilled = 0;     // tokens prefilled by this request
    int reused = 0;        // prompt tokens already in the KV cache
    int generated = 0;
    double prefill_s = 0, decode_s = 0;
    std::string reason;    // stop | length | cancel | ctx
};

class Engine {
public:
    // dir: the model folder (Section2 embedder, Section3 per-layer embedder); main: the fused
    // prefill/decode graph. weight_cache: XNNPACK weight-cache file, built on first load.
    // Throws std::runtime_error on any failure.
    Engine(const std::string& dir, const std::string& main, int ctx, int threads,
           const std::string& weight_cache);
    ~Engine();

    int context() const;

    // Generate after [ids] (which includes <bos>), reusing the longest prefix already in the
    // cache. max_new = 0 only prefills. on_token returns false to stop. Throws on a bad request.
    std::vector<int> generate(const std::vector<int>& ids, int max_new, float temp, int top_k,
                              float top_p, unsigned seed, const std::function<bool(int)>& on_token,
                              Stats* stats);

    // Callable from any thread: the running generate() stops after its current step.
    void cancel() { cancel_ = true; }

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    std::atomic<bool> cancel_{false};
};

}  // namespace mfa
