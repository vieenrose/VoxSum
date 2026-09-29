// engine.h - the composite: one audio timeline, two streaming models, one speaker-tagged transcript.
//
// Written for this repo. Both models run in-process, in the same loop, on the same pieces:
//
//   piece (100 ms)  ->  Nemotron-3 diar stream  ->  turn intervals (refined as we go)
//                 ->  x-asr stream              ->  text delta
//                 ->  Fusion                    ->  characters tagged with a speaker
//
// Feeding the diarizer BEFORE the transcriber per piece is deliberate: attribution needs the turn
// that covers the audio, and a turn that arrives one piece late shifts the first characters of
// every speaker change into the previous speaker.
#pragma once
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "diar_crispasr.h"
#include "fusion.h"

namespace nemo {

struct Config {
    // Push this much SILENCE to the diarizer only, just before stream_finish. The final flush costs a fixed
    // ~5-8.6 s regardless of clip length (45 s clip: 8.74 s, 69 s clip: 8.55 s) - that says graph build for a
    // window size the steady state never produced, not arithmetic over leftover audio. A full silence chunk
    // first should let the flush reuse an already-built graph. 0 = today's behaviour.
    int diar_tail_ms = 0;

    // Touch every page of both model files before the run loop starts. NOT a speedup mechanism: it moves
    // first-pass page faults out of the measured window and into load_s. Kept because it settles whether
    // faults matter on this device at all - and because the honest comparison for any "warm up at load"
    // idea is load_s + wall_s, not wall_s alone.
    bool prefault = false;

    // Skip audiocpp_stream_finish and keep only the turns the stream already committed as events. The finish
    // call costs ~7-9 s per stream REGARDLESS of clip length (3 s clip 7.27, 15 s 8.59, 45 s 8.74, 69 s 8.55)
    // - a fixed prepare/flush, not work proportional to audio. Whether those turns were needed is the test.
    bool diar_no_finish = false;
    std::string xasr_model;         // x-asr-zh-en-q8_0.gguf
    std::string diar_model;         // nemotron-3-diarization-q8_0.gguf
    std::string audio;              // 16 kHz mono PCM16 wav
    int  threads      = 2;
    int  piece_ms     = 100;
    int  chunk_ms     = 480;        // x-asr chunk; also the default ASR latency estimate
    double asr_latency_ms = -1;     // <0 = chunk_ms (the encoder's own window)
    double char_dur_ms    = 90;     // per-character speaking rate used to place a delta in time
    double token_offset_ms = 300;   // a transducer emits a token at the frame where it DECIDED the token,
                                    // not at the audio that produced it, so raw frame times run late. 300 ms
                                    // was derived from the audio - it is the shift that puts 0 of 119 tokens
                                    // inside ground-truth silence on the sequential bilingual clip (3 at
                                    // 0 ms, 2 at 450 ms) - never from a WER or attribution score. See
                                    // tools/validate_timestamps.py; re-derive per model, do not copy it.
    int  gap_fill       = 0;        // 0 nearest, 1 previous-speaker continuation
    int  timing         = 0;        // 0 auto, 1 force model timestamps, 2 force inferred placement
    double gap_snap_ms    = 0;      // attribution tolerance across a between-turns pause; 0 = nearest.
                                    // Not a timid default: the archive scorer that these numbers come
                                    // from drops "Speaker -1" lines from WER entirely, so leaving text
                                    // untagged costs WER (0.2235 vs 0.1765, identical transcript). The
                                    // honest counter is snapped_chars, which is reported either way.
    // Passed to the diarizer as REQUEST options - the family reads its decode config from
    // stream_request_.options, so session options do nothing and a NULL request silently means
    // threshold=0.5, min_frames=0, pad_frames=0. Use {"speaker_threshold","0.35"} and friends.
    // Defaults measured, not copied from upstream (curve in README): speaker_pad_frames bridges gaps where
    // the diarizer fell below threshold mid-turn. DER-lite on the bilingual clips drops 40.9->30.3 (57s)
    // and 45.8->29.3 (45s, never tuned on) at pad=45, with false alarm <= 1.1. Silence/noise/tone still
    // produce ZERO turns at these settings. Raising pad further keeps helping on presentation-style audio
    // and will start merging fast turn-taking, so 45 (~1.7 s) is a middle choice, not the eval optimum.
    // SESSION-scoped diarizer options (audiocpp_options passed to session_create). The split is load-bearing:
    // the decode knobs (speaker_*) are read off the REQUEST, while the streaming geometry and memory sizing -
    // latency_profile, chunk_len, chunk_right_context, fifo_len, spkcache_len, spkcache_update_period,
    // graph_arena_mb, weight_context_mb, weight_type - are SESSION options and the library rejects them on a
    // request with "unknown Nemotron 3 diarization request option".
    // SHIPPED diar streaming geometry: the `custom` profile carrying very_high's own numbers, except
    // spkcache_len=128 instead of 264. Armed phone measurement (witness 2255 MHz): diar leg 11.94 -> 9.75 s
    // on chat69 and 5.99 -> 4.90 s on gate_ms_v2, i.e. composite 0.4701 -> 0.4141 and 0.4618 -> 0.4263.
    // Two controls make this attributable: (a) `custom` fed very_high's own 264 is byte-identical to the
    // shipped build and the same speed, so the win is the speaker cache, not the profile name; (b) 64 is
    // slower than 128 (30.0 s chat69), so this is a minimum, not a monotone "less memory is faster" slope.
    // Speaker memory shorter than the model's 264 frames moves turn boundaries on multi-window audio
    // (chat69 transcript hash changes, gate_ms_v2 does not), so this ships as a deliberate re-bless backed
    // by .auto/validate.sh evidence, not as a byte-identical change. Pass the old value back with
    // --diar-session-opt nemotron_3_diar.spkcache_len=264 to A/B it.
    // Tensor-name prefix for the x-asr half of a merged GGUF bundle ("" = standalone file). Set by
    // --models-bundle; handed to crispasr's loader, which tries "<prefix><name>" before the bare name.
    std::string asr_gguf_prefix;

    // Diarizer streaming geometry (80 ms frames). 2026-09-27: 4 s chunks + 0.96 s lookahead, so the first
    // speaker turn commits at 5.0 s of audio (gate_ms_v2, phone) instead of 30.5 s (the old 340-frame chunks). The model re-encodes its
    // speaker cache + FIFO on every chunk, which is what makes short chunks expensive; with the cache at
    // 128 + 40 frames, phone RTF on gate_ms_v2 is 0.60 (was 0.42); final attribution is equal or better on all 5
    // multi-speaker clips and DER-lite drops 23.28 -> 22.74 % (57 s clip), 15.24 -> 10.00 % (gate_long). The
    // 12-frame lookahead was picked over 8 (57 s DER 30.8 %) among 6 variants on those 2 clips. Measured alternatives: 2 s chunks -> 2.4 s latency, RTF 0.87; the
    // official "low" profile (264 + 264 cache, 0.72 s chunks) -> RTF 3.4, not real time on 2 cores.
    std::vector<std::pair<std::string, std::string>> diar_session_opts = {
        {"nemotron_3_diar.latency_profile",                 "custom"},
        {"nemotron_3_diar.chunk_len",                        "50"},
        {"nemotron_3_diar.chunk_right_context",              "12"},
        {"nemotron_3_diar.fifo_len",                         "40"},
        {"nemotron_3_diar.spkcache_update_period",           "60"},
        {"nemotron_3_diar.spkcache_len",                     "128"},
    };

    std::vector<std::pair<std::string, std::string>> diar_opts = {
        {"speaker_threshold", "0.3"}, {"speaker_pad_frames", "45"}
    };
    // Affinity, in hex cpu masks (0xc0 = cpu6-7 = the two A78 primes on the Dimensity 1300).
    // PROBE, NOT FIX. audio.cpp creates ~8 threads during streaming (measured: 1 thread through init, 10
    // mid-run) and the count does not follow the configured threads. Separating the two engines across the
    // big.LITTLE clusters is the right experiment for the 2-cpu slowdown - but the pool is created LAZILY,
    // so a pass over /proc/self/task finds nothing to move at the start of a run (measured: moved=1,
    // threads=1 at pieces 0-8), and threads created later inherit the creator's mask. The loop re-applies
    // every few pieces for that reason. Until that is proven to work, treat these flags as instrumentation
    // for the open question in README "On the phone", not as the answer to it.
    long main_affinity   = -1;   // mask for the calling (ASR) thread
    long engine_affinity = -1;   // mask for every other thread in the process
    int window_samples = 46900;   // HOP_S of the archive contract: 70400 samples at 24 kHz = 2.933 s
    bool windowed_out   = false;  // emit [k/N] Speaker s: blocks like the streaming baseline does
    bool paced        = false;      // wall-clock 1x, for the realtime demonstration
    bool live_provisional = false;  // re-attribute on every turn update, print revisions to stderr
    bool skip_asr     = false;
    bool skip_diar    = false;
    // docs/one-runtime-merge.md: run the diar encoder+head on CrispASR's own ggml (DiarCrispASR,
    // src/diar_crispasr.h) via audiocpp_nemotron3_diar_set_external_encoder, instead of audio.cpp's own
    // internal graph. Every other piece of the diar family (mel frontend, streaming window scheduling, the
    // arrival-order speaker-cache state, turn decoding) is audio.cpp's own code either way - this flag picks
    // which runtime does JUST the matmul-heavy compute. Default TRUE since 2026-09-27: validated WER-neutral
    // on all 11 clips and measured faster than audio.cpp's own graph on the phone once its activation
    // allocation was fixed (docs/one-runtime-merge.md SS25-26). --no-diar-native restores the old path.
    bool diar_native  = true;
    // VoxSumDroid: split a single-speaker run after a sentence end once it is this long (0 = never).
    double max_segment_s = 0;
    // VoxSumDroid live view: a segment stops changing once it ends this far behind the audio fed.
    // The diarizer revises recent labels for tens of seconds; live-vs-final agreement on 4 meetings is
    // 93.0% at 8 s, 94.7% at 15 s, 95.8% at 30 s. The app passes the user's setting (default 15).
    double live_settle_s = 15.0;
};

struct Segment {
    int    index = 0;
    int    speaker = -1;            // -1 = unattributed audio
    std::string speaker_id;         // diarizer's label, e.g. "speaker_2"
    std::string text;
    double start_s = 0, end_s = 0;
    float  min_confidence = 0.0f;
    std::string asr_text_so_far;    // cumulative transcript at close time (for diffing)
};

// The model's own token timeline, with the speaker each token landed on. Only available when the model
// reports times; the validator (tools/validate_timestamps.py) reads this to check the times against
// ground truth WITHOUT trusting the attributor that consumed them.
struct TokenInfo {
    std::string text;
    double      t_s = 0;
    std::string speaker_id;      // "" = unattributed
    bool        snapped = false;
};

struct Stats {
    double audio_s = 0, wall_s = 0, load_s = 0, asr_compute_s = 0, diar_compute_s = 0;
    double first_partial_s = -1, piece_p95_ms = 0, piece_max_ms = 0;
    double peak_rss_mb = 0;
    double first_turn_audio_s = -1;
    int timing_mode = 0;            // 1 = model-given token timestamps, 0 = inferred placement
    size_t tokens = 0;   // when the diarizer committed its FIRST turn, in audio time.
                                      // This is the attribution floor: no word can be tagged before it.
    size_t turns = 0, segments = 0, speakers = 0, deltas = 0, unattributed_chars = 0, snapped_chars = 0;
    std::vector<double> pass_rtf;
    // Where the uncharged time goes. wall - asr - diar was ~19% of wall and nobody knew why; these split it
    // into the pieces of the loop that are neither engine call. Zero cost unless NEMO_PROF=1.
    // CPU-seconds vs wall-seconds over the whole run: "cores used" is the one number that says whether we
    // are leaving a core idle. The loop is sequential and the ASR leg is reported single-threaded, so the
    // expected value is well under the 2 cores the mask allows - and it separates "CPU-bound and efficient"
    // from "CPU-bound but only one core is working".
    double cpu_s = 0;
    // Wall time of Engine::init (model loads). The RTF metric counts the run loop only, so anything moved
    // into init would look like a speedup without being one. Printing it makes that visible: the honest
    // comparison for any "warm up at load" idea is init_s + wall_s, not wall_s.

    double prof_pushdelta_s = 0, prof_tokenbuild_s = 0, prof_attrfinal_s = 0, prof_drain_s = 0;
};

class Engine {
public:
    Engine(Config cfg) : cfg_(std::move(cfg)), fusion_(16000, 0.0) {}
    ~Engine();

    bool init(std::string& err);
    // Called whenever a segment closes (speaker change or end of input).
    bool run(const std::function<void(const Segment&)>& on_segment, std::string& err);

    // Push-based streaming (VoxSumDroid): the same loop body as run(), fed by the caller instead of a WAV.
    // begin() once, push() any number of 16 kHz mono pieces (any size; split into piece_ms internally),
    // finish() once. live() gives a cheap provisional view in between.
    void begin();
    bool push(const float* pcm, size_t n, std::string& err);
    bool finish(const std::function<void(const Segment&)>& on_segment, std::string& err);
    // VoxSumDroid live view: re-attribute only the unsettled tail (inferred placement, O(tail)).
    // Segments that can no longer change during the live view are appended to [newly_frozen] exactly once;
    // [tail] is everything after them. finish() still re-attributes the whole timeline from scratch.
    void live(std::vector<Segment>& newly_frozen, std::vector<Segment>& tail) {
        live(live_cursor_, cfg_.live_settle_s, newly_frozen, tail);
    }
    // Where a live view has frozen up to in the Fusion timeline. Independent cursors let a harness
    // (tools/nemo-eval --sweep-settle) evaluate several speaker delays in one pass.
    struct LiveCursor { size_t chars = 0, bytes = 0; };
    void live(LiveCursor& cur, double settle_s, std::vector<Segment>& newly_frozen, std::vector<Segment>& tail);
    double fed_s() const { return double(fed_) / 16000.0; }
    // Audio time up to which the diarizer has committed turns (the attribution-stable frontier).
    double committed_turns_s() const;

    const Stats& stats() const { return stats_; }
    std::vector<TokenInfo> token_table() const;
    const std::vector<Turn>& turns() const { return fusion_.turns(); }
    const std::string& transcript() const { return asr_text_; }

private:
    // Tag every buffered delta against the current turn timeline and emit the segments.
    void attribute(const std::function<void(const Segment&)>& on_segment, bool final_pass);

    Config cfg_;
    Fusion fusion_;
    Stats  stats_;
    std::string asr_text_;
    std::map<std::string, int> spk_id_;
    double first_turn_audio_ = -1;
    void* asr_ctx_ = nullptr;
    void* asr_stream_ = nullptr;
    void* registry_ = nullptr;
    void* model_ = nullptr;
    void* session_ = nullptr;
    void* diar_request_ = nullptr;
    std::vector<double> piece_ms_;
    bool push_piece(const float* pcm, size_t n, bool last, std::string& err);
    std::vector<float> pending_;        // < one piece, carried to the next push()
    LiveCursor live_cursor_;            // the app's live view (cfg_.live_settle_s)
    struct SegCounts { size_t segments = 0, pieces = 0, unattributed = 0, snapped_chars = 0; };
    SegCounts build_segments(std::vector<TaggedPiece> pieces, size_t char_base, size_t byte_base,
                             const std::function<void(const Segment&, size_t, size_t)>& emit);
    int64_t fed_ = 0, charged_upto_ = 0;
    size_t turns_seen_ = 0;
    double t0_ = 0;
    std::unique_ptr<DiarCrispASR> diar_crispasr_;   // set only when cfg_.diar_native
};

double rss_mb();      // VmHWM, peak resident set of this process
double now_s();

}  // namespace nemo
