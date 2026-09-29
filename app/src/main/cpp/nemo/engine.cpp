// engine.cpp - see engine.h. Written for this repo; the model runtimes it calls are upstream
// (CrispASR's xasr stream, audio.cpp's Nemotron-3 diar stream) and are attributed in PROVENANCE.md.
#include "engine.h"
#include "wav.h"

#include <algorithm>
#include <cstdio>
#include <map>
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <sched.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/resource.h>
#include <cstdlib>
#include <cstring>
#include <map>

#include <ctime>

#include "xasr.h"                       // CrispASR (MIT) - x-asr streaming Zipformer2
#include "audiocpp.h"                   // audio.cpp (Apache-2.0) - Nemotron-3 diarization stream

namespace nemo {

// Trampoline for audiocpp_nemotron3_diar_set_external_encoder's C function-pointer contract (see
// diar_crispasr.h / docs/one-runtime-merge.md): user_data is the DiarCrispASR instance this Engine owns.
// Ownership rule from audiocpp.h's own doc comment on this typedef: malloc() the return buffer, audio.cpp
// frees it after copying.
static int diar_native_encode(
    void* user_data,
    const float* embeddings, int64_t batch, int64_t frames, int64_t hidden,
    const int64_t* valid_frames,
    float** out_probabilities, int64_t* out_len) {
    auto* diar = static_cast<DiarCrispASR*>(user_data);
    try {
        std::vector<float> emb(embeddings, embeddings + batch * frames * hidden);
        std::vector<int64_t> vf(valid_frames, valid_frames + batch);
        auto probs = diar->encode(emb, batch, frames, vf);
        float* buf = static_cast<float*>(std::malloc(probs.size() * sizeof(float)));
        if (!buf) return 1;
        std::memcpy(buf, probs.data(), probs.size() * sizeof(float));
        *out_probabilities = buf;
        *out_len = static_cast<int64_t>(probs.size());
        return 0;
    } catch (...) {
        return 1;
    }
}

double now_s() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return double(ts.tv_sec) + 1e-9 * ts.tv_nsec;
}

double rss_mb() {
    FILE* f = std::fopen("/proc/self/status", "r");
    if (!f) return 0.0;
    char line[256];
    double v = 0;
    while (std::fgets(line, sizeof(line), f)) {
        if (!std::strncmp(line, "VmHWM", 5)) { std::sscanf(line + 6, "%lf", &v); break; }
    }
    std::fclose(f);
    return v / 1024.0;
}

Engine::~Engine() {
    if (asr_stream_) xasr_stream_free((xasr_stream*)asr_stream_);
    if (asr_ctx_) xasr_free((xasr_context*)asr_ctx_);
    if (diar_request_) audiocpp_request_free((audiocpp_request*)diar_request_);
    if (session_) audiocpp_session_free((audiocpp_session*)session_);
    if (model_) audiocpp_model_free((audiocpp_model*)model_);
    if (registry_) audiocpp_registry_free((audiocpp_registry*)registry_);
}

// Apply cpu affinity per thread. Affinity is per-thread on Linux, so taskset on the process applies to
// every thread and cannot separate the two engines - which is exactly the problem here.
static int apply_affinity(long main_mask, long engine_mask) {
    const pid_t self = getpid();
    DIR* d = opendir("/proc/self/task");
    if (!d) return -1;
    int moved = 0, kept = 0;
    struct dirent* e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        const pid_t tid = (pid_t)std::atoi(e->d_name);
        const long m = (tid == self) ? main_mask : engine_mask;
        if (m < 0) { kept++; continue; }
        cpu_set_t cs;
        CPU_ZERO(&cs);
        for (int b = 0; b < 64; b++) if (m & (1L << b)) CPU_SET(b, &cs);
        if (sched_setaffinity(tid, sizeof(cs), &cs) == 0) moved++; else kept++;
    }
    closedir(d);
    return moved;
}

// Turns carried by a diar result, in the shape fusion_ wants. Shared by the per-piece drain and the tail push.
void harvest_turns(const audiocpp_result* r, std::vector<Turn>& out) {
    if (!r) return;
    const size_t k = audiocpp_result_speaker_turn_count(r);
    for (size_t i = 0; i < k; i++) {
        int64_t s0 = 0, s1 = 0; float conf = 0; const char* sid = nullptr; const char* txt = nullptr;
        if (audiocpp_result_speaker_turn(r, i, &s0, &s1, &sid, &conf, &txt) == AUDIOCPP_OK) {
            out.push_back(Turn{s0, s1, sid ? sid : "", conf});
        }
    }
}

namespace {
// Read the file in strides so the page cache holds it. A plain read() of the whole file into a buffer would
// cost an allocation the size of the model; 64 KB at a time is enough to fault every 4 KB page in.
void prefault_file(const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return;
    std::fseek(f, 0, SEEK_END);
    const long sz = std::ftell(f);
    std::rewind(f);
    char buf[65536];
    volatile long got = 0;
    for (long off = 0; off < sz; off += (long)sizeof buf) {
        const size_t n = std::fread(buf, 1, sizeof buf, f);
        if (!n) break;
        got += (long)buf[0];           // touch, or the compiler may drop the read
    }
    (void)got;
    std::fclose(f);
}
}  // namespace

bool Engine::init(std::string& err) {
    const double init_t0 = now_s();
    {                                    // thread-count probe, its own scope on purpose
        DIR* d0 = opendir("/proc/self/task");
        int n0 = 0; if (d0) { while (readdir(d0)) n0++; closedir(d0); }
        if (getenv("NEMO_DEBUG_THREADS"))
            std::fprintf(stderr, "[threads] at Engine::init entry: %d\n", n0 - 2);
    }

    auto nthr = []{ DIR* d = opendir("/proc/self/task"); int n = 0; if (d) { while (readdir(d)) n++; closedir(d); } return n - 2; };
    const bool dbg_thr = getenv("NEMO_DEBUG_THREADS") != nullptr;

    const bool prof_on = getenv("NEMO_PROF") != nullptr;   // timers stay off unless asked for
    const double t0 = now_s();
    if (!cfg_.skip_asr) {
        if (cfg_.xasr_model.empty()) { err = "--xasr-model required (or --no-asr)"; return false; }
        xasr_context_params p = xasr_context_default_params();
        p.n_threads = cfg_.threads;
        p.verbosity = 0;
        // xasr_context_default_params() sets use_gpu = TRUE, and xasr_init then calls
        // crispasr_init_gpu_backend() unconditionally when it is set. On a GPU-less phone that is not a
        // clean "fall back to cpu": it cost ~3.5x on the ASR leg (rtf 0.748 vs the standalone probe's
        // 0.389-0.215 on the same model and params), which is exactly the kind of stable, mask-independent
        // penalty I spent a long time misattributing to thread pools and page faults. Always say cpu.
        p.use_gpu = false;
        p.chunk_ms = cfg_.chunk_ms;
        // Bundle support: the loader reads this once from the environment. Set it before init, and always
        // set it (empty included) so a previous bundle run in the same process cannot leak its prefix.
        ::setenv("CRISPASR_GGUF_PREFIX", cfg_.asr_gguf_prefix.c_str(), 1);
        asr_ctx_ = xasr_init_from_file(cfg_.xasr_model.c_str(), p);
        if (!asr_ctx_) { err = "x-asr model failed to load: " + cfg_.xasr_model; return false; }
        asr_stream_ = xasr_stream_init((xasr_context*)asr_ctx_);
        if (!asr_stream_) { err = "xasr_stream_init failed"; return false; }
    }
    if (!cfg_.skip_diar) {
        if (cfg_.diar_model.empty()) { err = "--diar-model required (or --no-diar)"; return false; }
        audiocpp_status st = audiocpp_registry_create(nullptr, (audiocpp_registry**)&registry_);
    if (dbg_thr) std::fprintf(stderr, "[threads] after registry: %d\n", nthr());
        if (st != AUDIOCPP_OK) { err = std::string("diar registry: ") + audiocpp_last_error(); return false; }
        audiocpp_model_config mc{};
        mc.family_hint = "nemotron_3_diar";
        st = audiocpp_model_load((audiocpp_registry*)registry_, cfg_.diar_model.c_str(), &mc, nullptr,
                                 (audiocpp_model**)&model_);
    if (dbg_thr) std::fprintf(stderr, "[threads] after model_load: %d\n", nthr());
        if (st != AUDIOCPP_OK) { err = std::string("diar model load: ") + audiocpp_last_error(); return false; }
        audiocpp_backend_config bc{};
        bc.backend = "cpu";
        bc.device = 0;
        bc.threads = cfg_.threads;
        // Defaults first, CLI last, collapsed into a map so an explicit --diar-session-opt always wins.
        // Appending the CLI pairs to a vector leaves "who wins" up to the library's internals, and an
        // A/B that silently keeps the default when the flag says otherwise is worse than no flag at all.
        std::map<std::string, std::string> session_map;
        for (const auto& kv : cfg_.diar_session_opts) session_map[kv.first] = kv.second;
        // Native encoder: audio.cpp never runs its own encoder+head, so don't let it upload their weights
        // (~100 MB duplicate of what DiarCrispASR holds). Read once at session construction; always set it
        // (to 0 included) so a previous run in the same process cannot leak it.
        ::setenv("AUDIOCPP_NEMOTRON3_DIAR_EXTERNAL_ENCODER", cfg_.diar_native ? "1" : "0", 1);
        audiocpp_options* sopts = audiocpp_options_create();
        if (!sopts) { err = "audiocpp_options_create failed"; return false; }
        for (const auto& kv : session_map) {
            if (audiocpp_options_set(sopts, kv.first.c_str(), kv.second.c_str()) != AUDIOCPP_OK) {
                err = "diar session option " + kv.first + "=" + kv.second + ": " + audiocpp_last_error();
                audiocpp_options_free(sopts);
                return false;
            }
        }
        st = audiocpp_session_create((audiocpp_model*)model_, "diar", "streaming", &bc, sopts,
                                     (audiocpp_session**)&session_);
        if (sopts) audiocpp_options_free(sopts);   // the API copies the map into the session
    if (dbg_thr) std::fprintf(stderr, "[threads] after session_create: %d\n", nthr());
        if (st != AUDIOCPP_OK) { err = std::string("diar session (streaming): ") + audiocpp_last_error(); return false; }
        if (cfg_.diar_native) {
            try {
                diar_crispasr_ = std::make_unique<DiarCrispASR>(cfg_.diar_model, cfg_.threads);
            } catch (const std::exception& e) {
                err = std::string("diar_native: DiarCrispASR load failed: ") + e.what();
                return false;
            }
            st = audiocpp_nemotron3_diar_set_external_encoder(
                (audiocpp_session*)session_, &diar_native_encode, diar_crispasr_.get());
            if (st != AUDIOCPP_OK) {
                err = std::string("diar_native: set_external_encoder: ") + audiocpp_last_error();
                return false;
            }
        }
        // The decode knobs live on the REQUEST (session.cpp reads decode_config(stream_request_.options)),
        // so build one instead of passing NULL. It stays alive for the run: freeing it after stream_start
        // would leave the family reading a dangling map, or quietly fall back to the defaults, and a
        // threshold sweep that silently used 0.5 everywhere is the kind of result I do not want to report.
        if (!cfg_.diar_opts.empty()) {
            audiocpp_request* req = audiocpp_request_create();
            if (!req) { err = "audiocpp_request_create failed"; return false; }
            for (const auto& kv : cfg_.diar_opts) {
                audiocpp_status os = audiocpp_request_set_option(req, kv.first.c_str(), kv.second.c_str());
                if (os != AUDIOCPP_OK) {
                    err = "diar option " + kv.first + "=" + kv.second + ": " + audiocpp_last_error();
                    audiocpp_request_free(req);
                    return false;
                }
            }
            diar_request_ = req;
            st = audiocpp_stream_start((audiocpp_session*)session_, req);
    if (dbg_thr) std::fprintf(stderr, "[threads] after stream_start: %d\n", nthr());
        } else {
            st = audiocpp_stream_start((audiocpp_session*)session_, nullptr);
        }
        if (st != AUDIOCPP_OK) { err = std::string("diar stream_start: ") + audiocpp_last_error(); return false; }
    }
    if (cfg_.prefault) prefault_file(cfg_.xasr_model), prefault_file(cfg_.diar_model);
    stats_.load_s = now_s() - t0;   // the prefault is deliberately INSIDE this: the point is to charge it
    double latency = cfg_.asr_latency_ms;
    if (latency < 0) latency = cfg_.chunk_ms;    // the encoder's own window is its floor
    fusion_ = Fusion(16000, latency / 1000.0);
    fusion_.set_char_dur_ms(cfg_.char_dur_ms);
    fusion_.set_gap_snap_ms(cfg_.gap_snap_ms);
    fusion_.set_gap_fill(cfg_.gap_fill == 1 ? Fusion::GapFill::PREVIOUS : Fusion::GapFill::NEAREST);
    return true;
}

// Tag every buffered delta against the turn timeline as it stands. Locals only, so calling it twice
// (a provisional live pass and the final pass) does not double-count anything.
// Rebuild the character timeline from the model's own token timestamps. Returns true only when the
// result reproduces the streamed transcript byte for byte, which is what makes this path safe to prefer:
// a token-time table that disagrees with the text means one of the two is broken, and silently attributing
// against the wrong timeline is exactly the "plausible output, wrong numbers" failure this project keeps
// hitting. Frame k covers audio from k * 40 ms (10 ms fbank hop, encoder downsampling 4; measured 25.6 Hz
// including the tail padding, so 40 ms is the mapping and not a guess).
static bool push_timed_tokens(Fusion& out, xasr_context* ctx, xasr_stream* stream, const std::string& expect,
                              double offset_ms) {
    const int32_t* ids = nullptr;
    const int64_t* frames = nullptr;
    int n = 0;
    if (!stream || xasr_stream_token_times(stream, &ids, &frames, &n) != 0 || n <= 0) return false;
    out.clear_text();
    std::string prev;
    for (int i = 0; i < n; i++) {
        char* all = xasr_tokens_to_text(ctx, ids, i + 1);      // cumulative decode with the SAME function
        std::string cur = all ? all : "";                      // that produced the streamed text, so the
        std::free(all);                                        // two can be compared instead of assumed equal
        if (cur.size() < prev.size()) return false;            // not append-only -> times cannot be mapped
        std::string piece = cur.substr(prev.size());
        prev = cur;
        // 40 ms per encoder frame, minus the decision lag the greedy loop introduces (see engine.h).
        const int64_t at = frames[i] * 640 - (int64_t)(offset_ms * 16.0);
        const int64_t next = (i + 1 < n) ? frames[i + 1] * 640 - (int64_t)(offset_ms * 16.0) : at + 40 * 16;
        out.push_token(piece, std::max<int64_t>(0, at), std::max(next, at + 1));
    }
    return out.text() == expect;
}

std::vector<TokenInfo> Engine::token_table() const {
    std::vector<TokenInfo> out;
#ifdef NEMO_HAVE_TOKEN_TIMES
    const int32_t* ids = nullptr;
    const int64_t* frames = nullptr;
    int n = 0;
    if (!asr_stream_ || xasr_stream_token_times((xasr_stream*)asr_stream_, &ids, &frames, &n) != 0 || n <= 0)
        return out;
    std::string prev;
    for (int i = 0; i < n; i++) {
        char* all = xasr_tokens_to_text((xasr_context*)asr_ctx_, ids, i + 1);
        std::string cur = all ? all : "";
        std::free(all);
        if (cur.size() < prev.size()) break;
        TokenInfo ti;
        ti.text = cur.substr(prev.size());
        ti.t_s = double(frames[i]) * 0.040 - cfg_.token_offset_ms / 1000.0;
        bool sn = false;
        const Turn* t = fusion_.covering((int64_t)(ti.t_s * 16000.0), 640, &sn);
        ti.speaker_id = t ? t->speaker : std::string();
        ti.snapped = sn;
        prev = cur;
        out.push_back(std::move(ti));
    }
#endif
    return out;
}

// Byte length of the punctuation (and spaces) a piece starts with - CJK full-width and ASCII.
static size_t leading_punct_bytes(const std::string& t) {
    static const char* marks[] = {"\xef\xbc\x8c", "\xe3\x80\x82", "\xe3\x80\x81", "\xef\xbc\x9f",
                                  "\xef\xbc\x81", "\xef\xbc\x9b", "\xef\xbc\x9a", ",", ".", "?", "!", ";", ":", " "};
    size_t i = 0;
    for (bool hit = true; hit && i < t.size();) {
        hit = false;
        for (const char* m : marks) {
            const size_t n = std::strlen(m);
            if (t.compare(i, n, m) == 0) { i += n; hit = true; break; }
        }
    }
    return i;
}

static bool ends_sentence(const std::string& t) {
    size_t e = t.find_last_not_of(' ');
    if (e == std::string::npos) return false;
    const std::string s = t.substr(0, e + 1);
    for (const char* m : {"\xe3\x80\x82", "\xef\xbc\x9f", "\xef\xbc\x81", ".", "?", "!"}) {
        const size_t n = std::strlen(m);
        if (s.size() >= n && s.compare(s.size() - n, n, m) == 0) return true;
    }
    return false;
}

// Pieces -> segments: the one builder behind the final pass and the live view. [char_base]/[byte_base]
// locate the first piece in the Fusion timeline; every segment is reported with the char and byte index
// just past its last character, so the live view can resume attribution exactly at a segment boundary.
Engine::SegCounts Engine::build_segments(
        std::vector<TaggedPiece> pieces, size_t char_base, size_t byte_base,
        const std::function<void(const Segment&, size_t, size_t)>& emit) {
    std::map<std::string, int>& spk_id = spk_id_;
    SegCounts n;
    Segment open;
    int idx = 0;
    size_t cur_c = char_base, cur_b = byte_base;       // next char/byte of the piece stream
    size_t open_c = cur_c, open_b = cur_b;             // just past the open segment's last char

    auto close = [&](const Segment& s) {
        Segment done = s;
        done.index = ++idx;
        emit(done, open_c, open_b);
    };
    auto take = [&](const std::string& t) {            // text appended to the open segment
        open.text += t;
        cur_c += codepoints(t).size();
        cur_b += t.size();
        open_c = cur_c;
        open_b = cur_b;
    };
    for (TaggedPiece& p : pieces) {
        // VoxSumDroid: punctuation the ASR emitted at a turn start ends the PREVIOUS speaker's
        // sentence ("？ 你有那么好抓吗") - hand it back before the speaker change closes that segment.
        if (!open.text.empty() && !p.speaker.empty() && p.speaker != open.speaker_id) {
            const size_t k = leading_punct_bytes(p.text);
            if (k) { take(p.text.substr(0, k)); p.text.erase(0, k); }
            if (p.text.empty()) continue;
        }
        // VoxSumDroid: a long single-speaker run becomes several segments, cut after a sentence end once
        // it is max_segment_s long (hard cut at 2x without punctuation) - one tap-to-seek line per
        // sentence group instead of a minutes-long monologue.
        if (cfg_.max_segment_s > 0 && !open.text.empty() && p.speaker == open.speaker_id) {
            const double len = open.end_s - open.start_s;
            if ((len >= cfg_.max_segment_s && ends_sentence(open.text)) || len >= 2 * cfg_.max_segment_s) {
                close(open);
                open.text.clear();
                open.start_s = p.start_s;
                open.end_s = p.end_s;
                open.min_confidence = p.min_confidence;
            }
        }
        // Text the diarizer left uncovered keeps the label it was already under instead of opening a
        // "Speaker -1" segment. This is not a hedge: the scorer WER is measured with drops every line it
        // cannot parse a speaker from, so an untagged island silently DELETES words from the transcript
        // (0.1765 -> 0.2235 on the bilingual gate with an identical character stream). The count is still
        // reported as unattributed_chars, so the honesty lives in the telemetry, not in the layout.
        if (p.speaker.empty() && !open.text.empty()) {
            n.unattributed += codepoints(p.text).size();
            take(p.text);
            open.end_s = std::max(open.end_s, p.end_s);
            continue;
        }
        n.pieces++;
        n.snapped_chars += p.snapped ? codepoints(p.text).size() : 0;
        const std::string& want = p.speaker;
        if (open.text.empty() || want != open.speaker_id) {
            if (!open.text.empty()) close(open);
            if (!want.empty()) {
                auto it = spk_id.find(want);
                if (it == spk_id.end()) it = spk_id.emplace(want, (int)spk_id.size()).first;
                open.speaker = it->second;
                open.speaker_id = want;
            } else {
                open.speaker = -1;
                open.speaker_id.clear();
                n.unattributed += codepoints(p.text).size();
            }
            open.text.clear();
            open.start_s = p.start_s;
            open.end_s = p.end_s;
            open.min_confidence = p.min_confidence;
        }
        take(p.text);
        open.end_s = std::max(open.end_s, p.end_s);
        open.min_confidence = std::min(open.min_confidence, p.min_confidence);
    }
    if (!open.text.empty()) close(open);
    n.segments = idx;
    return n;
}

void Engine::live(LiveCursor& cur, double settle_s, std::vector<Segment>& newly_frozen,
                  std::vector<Segment>& tail) {
    struct Built { Segment seg; size_t end_c, end_b; };
    std::vector<Built> segs;
    build_segments(fusion_.attribute_from(cur.chars, cur.bytes), cur.chars, cur.bytes,
                   [&](const Segment& seg, size_t c, size_t b) { segs.push_back({seg, c, b}); });
    // A segment freezes once the diarizer has committed turns past it AND it is live_settle_s behind
    // the audio fed; the last segment never freezes (it may still grow).
    const double horizon = std::min(fed_s() - settle_s, committed_turns_s());
    size_t k = 0;
    for (; k + 1 < segs.size() && segs[k].seg.end_s <= horizon; k++) {
        newly_frozen.push_back(segs[k].seg);
        cur.chars = segs[k].end_c;
        cur.bytes = segs[k].end_b;
    }
    for (; k < segs.size(); k++) tail.push_back(segs[k].seg);
}

void Engine::attribute(const std::function<void(const Segment&)>& on_segment, bool final_pass) {
    const Fusion* use = &fusion_;
    Fusion timed = fusion_;
    // The two paths are both live at runtime (not compile-time), because the useful comparison is the same
    // model, same audio, same turns, with only the character timeline coming from a different place.
    bool want_tokens = cfg_.timing != 2;
#ifdef NEMO_HAVE_TOKEN_TIMES
    if (want_tokens && asr_stream_ &&
        push_timed_tokens(timed, (xasr_context*)asr_ctx_, (xasr_stream*)asr_stream_, asr_text_,
                          cfg_.token_offset_ms)) {
        use = &timed;
        stats_.timing_mode = 1;
    } else
#endif
    {
        stats_.timing_mode = 0;
    }

    const SegCounts n = build_segments(use->attribute_all(), 0, 0,
                                       [&](const Segment& seg, size_t, size_t) { on_segment(seg); });

    if (final_pass) {
        if (const char* dump = getenv("NEMO_DUMP_TIMELINE")) {
            FILE* f = std::fopen(dump, "w");
            if (f) {
                const auto cps = codepoints(use->text());
                const auto& sp = use->spans();
                std::fprintf(f, "[\n");
                for (size_t i = 0; i < cps.size() && i < sp.size(); i++)
                    std::fprintf(f, "%s  {\"c\": \"%s\", \"t\": %.3f}\n", i ? ",\n" : "",
                                 use->text().substr(cps[i].first, cps[i].second).c_str(),
                                 double(sp[i].start) / 16000.0);
                std::fprintf(f, "]\n");
                std::fclose(f);
            }
        }
    }
    stats_.segments = n.segments;
    stats_.unattributed_chars = n.unattributed;
    stats_.snapped_chars = n.snapped_chars;
    stats_.speakers = spk_id_.size();
    if (final_pass && getenv("NEMO_DEBUG_ATTR")) {
        std::fprintf(stderr, "[attrib] %zu pieces, %zu turns, %zu chars, timing=%s\n", n.pieces,
                     use->turns().size(), use->chars(), stats_.timing_mode ? "tokens" : "inferred");
    }
}

bool Engine::run(const std::function<void(const Segment&)>& on_segment, std::string& err) {
    Wav wav;
    if (!Wav::load(cfg_.audio, wav, err)) return false;
    if (wav.rate != 16000) wav.to_16k();
    begin();
    // Fed in piece-sized blocks so paced runs keep their wall-clock meaning; push() re-chunks anyway.
    const size_t piece = size_t(cfg_.piece_ms) * 16000 / 1000;
    for (size_t off = 0; off < wav.pcm.size(); off += piece) {
        if (!push(wav.pcm.data() + off, std::min(piece, wav.pcm.size() - off), err)) return false;
        if (cfg_.paced) {                       // 1x wall clock, so latency means what it says
            const double sl = t0_ + double(fed_) / 16000.0 - now_s();
            if (sl > 0) { timespec ts{(long)sl, (long)((sl - (long)sl) * 1e9)}; nanosleep(&ts, nullptr); }
        }
    }
    return finish(on_segment, err);
}

void Engine::begin() {
    // Set the calling thread's mask now, and every other thread's mask as they appear (see push_piece).
    if (cfg_.main_affinity >= 0 || cfg_.engine_affinity >= 0) apply_affinity(cfg_.main_affinity, -1);
    pending_.clear();
    fed_ = charged_upto_ = 0;
    turns_seen_ = 0;
    t0_ = now_s();
}

double Engine::committed_turns_s() const {
    int64_t e = 0;
    for (const Turn& t : fusion_.turns()) e = std::max(e, t.end);
    return double(e) / 16000.0;
}

bool Engine::push(const float* pcm, size_t n, std::string& err) {
    const size_t piece = size_t(cfg_.piece_ms) * 16000 / 1000;
    pending_.insert(pending_.end(), pcm, pcm + n);
    size_t off = 0;
    for (; pending_.size() - off >= piece; off += piece)
        if (!push_piece(pending_.data() + off, piece, false, err)) return false;
    pending_.erase(pending_.begin(), pending_.begin() + off);
    return true;
}

bool Engine::push_piece(const float* pcm, size_t n, bool last, std::string& err) {
    const int rate = 16000;
    const int64_t off = fed_;
    const size_t piece_idx = size_t(off) / (size_t(cfg_.piece_ms) * rate / 1000);
    const bool aff_cfg = cfg_.main_affinity >= 0 || cfg_.engine_affinity >= 0;
    // The diarizer creates its worker pool on FIRST COMPUTE and later threads inherit the creator's
    // mask, so re-apply on a small period.
    if (aff_cfg && piece_idx % 4 == 0) apply_affinity(cfg_.main_affinity, cfg_.engine_affinity);
    const bool prof_on = getenv("NEMO_PROF") != nullptr;
    const double a0 = now_s();

    // 1. diarizer first: attribution needs the turn that covers this audio
    if (!cfg_.skip_diar && n > 0) {
        const double d0 = now_s();
        audiocpp_event* ev = nullptr;
        audiocpp_status st = audiocpp_stream_push((audiocpp_session*)session_, pcm, n, rate, 1, off, &ev);
        if (st != AUDIOCPP_OK) { err = std::string("diar stream_push: ") + audiocpp_last_error(); return false; }
        std::vector<Turn> snapshot;
        harvest_turns(ev ? audiocpp_event_as_result(ev) : nullptr, snapshot);
        if (ev) audiocpp_event_free(ev);
        for (;;) {                                   // a family may queue several events per push
            audiocpp_event* more = nullptr;
            if (audiocpp_stream_next_event((audiocpp_session*)session_, &more) != AUDIOCPP_OK || !more) break;
            harvest_turns(audiocpp_event_as_result(more), snapshot);
            audiocpp_event_free(more);
        }
        if (!snapshot.empty()) {
            if (first_turn_audio_ < 0) first_turn_audio_ = double(off + n) / rate;
            fusion_.update_turns(snapshot);
            turns_seen_ = fusion_.turns().size();
        }
        stats_.diar_compute_s += now_s() - d0;
    }

    // 2. transcriber
    std::string delta;
    if (!cfg_.skip_asr) {
        const double s0 = now_s();
        char* full = xasr_stream_accept((xasr_stream*)asr_stream_, pcm, (int)n, last);
        std::string cur = full ? full : "";
        std::free(full);
        delta = cur.size() > asr_text_.size() ? cur.substr(asr_text_.size()) : "";
        asr_text_ = cur;
        stats_.asr_compute_s += now_s() - s0;
    }
    fed_ += (int64_t)n;

    // 3. pin the delta to the audio it decodes: it describes audio up to (fed - latency).
    if (!delta.empty()) {
        const double pd0 = prof_on ? now_s() : 0.0;
        int64_t horizon = last ? fed_ : fed_ - (int64_t)(fusion_.latency_s() * rate);
        if (horizon < charged_upto_) horizon = charged_upto_;
        if (cfg_.timing != 1) fusion_.push_delta(delta, charged_upto_, horizon);
        if (prof_on) stats_.prof_pushdelta_s += now_s() - pd0;
        charged_upto_ = horizon;
        stats_.deltas++;
        if (stats_.first_partial_s < 0) stats_.first_partial_s = now_s() - t0_;
    }
    piece_ms_.push_back((now_s() - a0) * 1000.0);
    stats_.wall_s = now_s() - t0_;
    return true;
}

bool Engine::finish(const std::function<void(const Segment&)>& on_segment, std::string& err) {
    const int rate = 16000;
    // The remainder (possibly empty) is the last piece: it flushes the ASR.
    if (!push_piece(pending_.data(), pending_.size(), true, err)) return false;
    pending_.clear();
    const int64_t total = fed_;
    const bool prof_on = getenv("NEMO_PROF") != nullptr;

    // Diarizer-only tail: the ASR never sees it, so text cannot shift from this side.
    if (cfg_.diar_tail_ms > 0 && !cfg_.skip_diar) {
        std::vector<float> zeros(size_t(cfg_.diar_tail_ms) * rate / 1000, 0.0f);
        const double d0 = now_s();
        audiocpp_event* ev = nullptr;
        audiocpp_status st = audiocpp_stream_push((audiocpp_session*)session_, zeros.data(), (int)zeros.size(),
                                                 rate, 1, (int64_t)total, &ev);
        if (st != AUDIOCPP_OK) { err = std::string("diar tail push: ") + audiocpp_last_error(); return false; }
        std::vector<Turn> snapshot;
        harvest_turns(ev ? audiocpp_event_as_result(ev) : nullptr, snapshot);
        if (ev) audiocpp_event_free(ev);
        for (;;) {
            audiocpp_event* more = nullptr;
            if (audiocpp_stream_next_event((audiocpp_session*)session_, &more) != AUDIOCPP_OK || !more) break;
            harvest_turns(audiocpp_event_as_result(more), snapshot);
            audiocpp_event_free(more);
        }
        if (!snapshot.empty()) fusion_.update_turns(snapshot);
        stats_.diar_compute_s += now_s() - d0;
    }

    const double drain0 = prof_on ? now_s() : 0.0;
    // Drain the diarizer's final turns (this also closes the turn still open at end-of-audio).
    if (!cfg_.skip_diar && !cfg_.diar_no_finish) {
        audiocpp_result* res = nullptr;
        if (audiocpp_stream_finish((audiocpp_session*)session_, &res) == AUDIOCPP_OK && res) {
            std::vector<Turn> snapshot;
            harvest_turns(res, snapshot);
            if (!snapshot.empty()) fusion_.update_turns(snapshot);
            audiocpp_result_free(res);
        }
    }
    if (prof_on) stats_.prof_drain_s = now_s() - drain0;
    attribute(on_segment, true);

    stats_.audio_s = double(total) / rate;
    stats_.wall_s = now_s() - t0_;
    {   // getrusage(RUSAGE_SELF) counts every thread, so cores = cpu/wall is honest.
        struct rusage ru;
        if (getrusage(RUSAGE_SELF, &ru) == 0)
            stats_.cpu_s = double(ru.ru_utime.tv_sec) + ru.ru_utime.tv_usec / 1e6
                         + double(ru.ru_stime.tv_sec) + ru.ru_stime.tv_usec / 1e6;
    }
    stats_.turns = fusion_.turns().size();
    stats_.first_turn_audio_s = first_turn_audio_;
#ifdef NEMO_HAVE_TOKEN_TIMES
    { const int32_t* id; const int64_t* fr; int nn = 0;
      if (asr_stream_ && xasr_stream_token_times((xasr_stream*)asr_stream_, &id, &fr, &nn) == 0) stats_.tokens = (size_t)nn; }
#endif
    std::vector<double> sorted = piece_ms_;
    std::sort(sorted.begin(), sorted.end());
    if (!sorted.empty()) {
        stats_.piece_p95_ms = sorted[size_t(0.95 * (sorted.size() - 1))];
        stats_.piece_max_ms = sorted.back();
    }
    stats_.peak_rss_mb = rss_mb();
    return true;
}

}  // namespace nemo
