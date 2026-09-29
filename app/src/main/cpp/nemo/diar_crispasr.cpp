// diar_crispasr.cpp - see diar_crispasr.h. The op sequence here is copied from tools/encoder_port.cpp
// (all-layers loop) and tools/head_port.cpp (final_norm..sigmoid), both verified byte-identical against
// audio.cpp's own output (docs/one-runtime-merge.md SS13-15) - restructured into a class that loads weights
// once and answers repeated encode() calls, instead of a one-shot CLI tool.
//
// Two-context design, mirroring ref/audiocpp's own split between BackendWeightStore (persistent) and
// EncoderGraph (rebuilt per shape): `weights_ctx_` holds every weight tensor, created and fed EXACTLY ONCE at
// construction; `graph_` (DiarCrispASR::Impl::Graph) holds only the activation tensors (input, mask) and the
// compute nodes for one frame count T, rebuilt only when T changes, referencing the SAME weight tensors by
// pointer across rebuilds - a graph node's src tensors are free to live in a different ggml_context than the
// node itself, the same way any ggml-based inference reuses persistent weights across per-step graphs.
//
// Why this matters here specifically, not just in general: audio.cpp's own "stop padding streaming windows"
// optimisation (this project's biggest early win, ideas.md) means the packed [speaker_cache|fifo|chunk]
// length is almost never the same from one streaming window to the next - so a FIRST version of this file
// that rebuilt everything (weights included) whenever T changed was, in effect, re-uploading ~100 MB of Q8_0
// weights on nearly every call. That version's own measurement: peak RSS 2.8 GB, "load" (encode-call) time
// alone over 3 s per call, and RTF WORSE than the audio.cpp path it was meant to replace. This version's
// weight upload happens exactly once, at construction.
#include "diar_crispasr.h"

#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "gguf.h"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

namespace nemo {
namespace {

// Opens the GGUF file ONCE and answers every tensor lookup against that same open file/context - the first
// version of this file called gguf_init_from_file (a full header reparse) plus fopen/fread/fclose separately
// for EACH of ~350 tensors; opening once and doing a linear name scan per lookup is negligible CPU (a few
// hundred string compares against ~360 tensor names) against the real cost, which was the repeated file
// opens and header reparses.
struct GgufReader {
    gguf_context * g = nullptr;
    ggml_context * ctx = nullptr;
    FILE * fh = nullptr;

    ~GgufReader() {
        if (fh != nullptr) fclose(fh);
        if (g != nullptr) gguf_free(g);
        if (ctx != nullptr) ggml_free(ctx);
    }

    bool open(const std::string & path) {
        g = gguf_init_from_file(path.c_str(), (struct gguf_init_params){ true, &ctx });
        if (g == nullptr) return false;
        fh = fopen(path.c_str(), "rb");
        return fh != nullptr;
    }

    bool has(const char * name) const {
        for (int64_t i = 0; i < gguf_get_n_tensors(g); i++) {
            if (strcmp(gguf_get_tensor_name(g, i), name) == 0) return true;
        }
        return false;
    }

    bool read(const char * name, std::vector<uint8_t> & out, int64_t ne[4]) const {
        for (int64_t i = 0; i < gguf_get_n_tensors(g); i++) {
            if (strcmp(gguf_get_tensor_name(g, i), name) != 0) continue;
            const size_t n = gguf_get_tensor_size(g, i);
            out.resize(n);
            fseek(fh, (long) (gguf_get_data_offset(g) + gguf_get_tensor_offset(g, i)), SEEK_SET);
            if (fread(out.data(), 1, n, fh) != n) return false;
            const struct ggml_tensor * t = ggml_get_tensor(ctx, name);
            for (int d = 0; d < 4; d++) ne[d] = t ? t->ne[d] : 0;
            return true;
        }
        return false;
    }
};

std::vector<float> bf16_to_f32(const std::vector<uint8_t> & raw) {
    std::vector<float> out(raw.size() / 2);
    for (size_t i = 0; i < out.size(); i++) {
        const uint16_t bits = (uint16_t) ((uint16_t) raw[2 * i] | ((uint16_t) raw[2 * i + 1] << 8));
        uint32_t u = ((uint32_t) bits) << 16;
        float f;
        memcpy(&f, &u, 4);
        out[i] = f;
    }
    return out;
}

void feed_raw(ggml_tensor * t, const std::vector<uint8_t> & b) { ggml_backend_tensor_set(t, b.data(), 0, b.size()); }
void feed_f32(ggml_tensor * t, const std::vector<float> & v) { ggml_backend_tensor_set(t, v.data(), 0, v.size() * sizeof(float)); }
void feed_f32_as_f16(ggml_tensor * t, const std::vector<float> & v) {
    std::vector<ggml_fp16_t> f16(v.size());
    ggml_fp32_to_fp16_row(v.data(), f16.data(), (int64_t) v.size());
    ggml_backend_tensor_set(t, f16.data(), 0, f16.size() * sizeof(ggml_fp16_t));
}

// audio.cpp's own semantics (encoder.cpp attention_mask(), streaming.cpp): key positions >= the row's valid
// length are masked with -10000, for every query row - the mask depends only on key validity, not query
// position (see docs/one-runtime-merge.md's note on why the diar encoder's attention is bidirectional and
// its carried state cannot be cached).
std::vector<float> attention_mask(int64_t valid_frames, int64_t frames) {
    std::vector<float> values(static_cast<size_t>(frames * frames), 0.0f);
    for (int64_t query = 0; query < frames; query++) {
        for (int64_t key = valid_frames; key < frames; key++) {
            values[static_cast<size_t>(query * frames + key)] = -10000.0f;
        }
    }
    return values;
}

// audio.cpp's own convention (encoder.cpp rope_table()). Returns ne=[HALF, T, HEADS, 1] (HALF fastest),
// matching layer0_rope_cos/sin.f32's own on-disk layout confirmed in docs/one-runtime-merge.md SS13.
std::vector<float> rope_table(int64_t heads, int64_t frames, int64_t head_dim, float theta, bool cosine) {
    const int64_t half = head_dim / 2;
    std::vector<float> out(static_cast<size_t>(half * frames * heads));
    for (int64_t h = 0; h < heads; h++) {
        for (int64_t t = 0; t < frames; t++) {
            for (int64_t d = 0; d < half; d++) {
                const double freq = 1.0 / std::pow((double) theta, (2.0 * (double) d) / (double) head_dim);
                const double angle = (double) t * freq;
                const double v = cosine ? std::cos(angle) : std::sin(angle);
                out[static_cast<size_t>((h * frames + t) * half + d)] = (float) v;
            }
        }
    }
    return out;
}

long minflt_now() {
    FILE * f = fopen("/proc/self/stat", "r");
    if (!f) return -1;
    char b[1024];
    const bool ok = fgets(b, sizeof b, f) != nullptr;
    fclose(f);
    if (!ok) return -1;
    char * p = strrchr(b, ')');
    if (!p) return -1;
    int field = 2;
    for (char * t = strtok(p + 1, " "); t; t = strtok(nullptr, " ")) if (++field == 10) return atol(t);
    return -1;
}

}  // namespace

struct DiarCrispASR::Impl {
    ggml_backend_t backend = nullptr;
    int threads = 2;
    int64_t hidden = 512, heads = 8, head_dim = 64, intermediate = 2048;
    float rope_theta = 10000.0f;
    const float eps = 1e-5f;
    int64_t num_speakers = 8, head_hidden = 192, upsample_factor = 8, upsample_kernel = 3;
    int n_layers = 0;

    // The persistent weight context: created once, fed once, never rebuilt. Every tensor pointer below stays
    // valid for the lifetime of this Impl and is referenced (never copied) by every per-shape Graph's ops.
    ggml_context * weights_ctx = nullptr;
    ggml_backend_buffer_t weights_buf = nullptr;

    struct LayerTensors {
        ggml_tensor * w_qkv = nullptr, * w_out = nullptr, * w_ffn_in = nullptr, * w_ffn_out = nullptr;
        ggml_tensor * n1w = nullptr, * n1b = nullptr, * n2w = nullptr, * n2b = nullptr;
        ggml_tensor * ob = nullptr, * fib = nullptr, * fob = nullptr;
    };
    std::vector<LayerTensors> layers;
    ggml_tensor * enw = nullptr, * enb = nullptr;   // encoder.embed_norm - applied BEFORE layer 0 (see encode())
    ggml_tensor * fnw = nullptr, * fnb = nullptr, * epw = nullptr, * epb = nullptr;
    ggml_tensor * usw = nullptr, * usb = nullptr, * hhw = nullptr, * hhb = nullptr, * shw = nullptr, * shb = nullptr;

    // Per-shape activation graph, reused across encode() calls with the SAME frame count. Rebuilt whenever T
    // changes (which, given audio.cpp's own no-padding streaming optimisation, is most calls in steady
    // state) - but a rebuild here only touches ~10 small activation tensors and the compute-node graph, NOT
    // any weight, so it is cheap regardless of how often it happens.
    struct Graph {
        ggml_context * ctx = nullptr;
        ggml_context * leaf_ctx = nullptr;   // in/mask/cos/sin only - own buffer, never touched by gallocr
        ggml_gallocr_t alloc = nullptr;
        ggml_backend_buffer_t buf = nullptr;
        int64_t frames = -1;
        ggml_tensor * in = nullptr;
        ggml_tensor * mask = nullptr;
        ggml_tensor * out = nullptr;
        ggml_cgraph * gf = nullptr;
        ~Graph() {
            if (alloc != nullptr) ggml_gallocr_free(alloc);
            if (buf != nullptr) ggml_backend_buffer_free(buf);
            if (ctx != nullptr) ggml_free(ctx);
            if (leaf_ctx != nullptr) ggml_free(leaf_ctx);
        }
    };
    std::unique_ptr<Graph> graph;

    ~Impl() {
        graph.reset();
        if (weights_buf != nullptr) ggml_backend_buffer_free(weights_buf);
        if (weights_ctx != nullptr) ggml_free(weights_ctx);
        if (backend != nullptr) ggml_backend_free(backend);
    }
};

DiarCrispASR::DiarCrispASR(const std::string & gguf_path, int threads) : impl_(new Impl()) {
    Impl & m = *impl_;
    // DIARCRISPASR_THREADS: override for measurement only. Tried as a fix for the kernel-time gap in
    // docs/one-runtime-merge.md SS21 (this backend's own separate ggml_backend_cpu_init() spins up its own
    // thread pool alongside x-asr's) - forcing 1 thread made wall time WORSE (19.8s -> 25.7s on
    // gate_ms_v2.wav), so the second thread is doing real, useful parallel work, not just contention
    // overhead. Kept as a diagnostic so that negative result isn't re-discovered by trying it again.
    if (const char * override_threads = getenv("DIARCRISPASR_THREADS")) threads = atoi(override_threads);
    m.threads = threads;
    m.backend = ggml_backend_cpu_init();
    if (m.backend == nullptr) throw std::runtime_error("DiarCrispASR: ggml_backend_cpu_init failed");
    ggml_backend_cpu_set_n_threads(m.backend, threads);

    GgufReader reader;
    if (!reader.open(gguf_path)) throw std::runtime_error("DiarCrispASR: failed to open " + gguf_path);

    int n_layers = 0;
    while (reader.has(("encoder.layers." + std::to_string(n_layers) + ".norm1.weight").c_str())) n_layers++;
    if (n_layers == 0) throw std::runtime_error("DiarCrispASR: no encoder layers found in " + gguf_path);
    m.n_layers = n_layers;

    // Raw bytes are needed only long enough to feed the persistent weight tensors below; nothing keeps them
    // after that (the first version of this file kept a second, host-side copy of every weight for the life
    // of the object - this one does not).
    struct Loaded { std::vector<uint8_t> raw; std::vector<float> f32; int64_t ne[4] = {0, 0, 0, 0}; };
    struct LoadedLayer {
        Loaded w_qkv, w_out, w_ffn_in, w_ffn_out;
        Loaded n1w, n1b, n2w, n2b, ob, fib, fob;
    };
    std::vector<LoadedLayer> raw_layers(static_cast<size_t>(n_layers));
    auto load_raw = [&](const std::string & name, Loaded & dst) {
        if (!reader.read(name.c_str(), dst.raw, dst.ne)) throw std::runtime_error("DiarCrispASR: missing " + name);
    };
    auto load_bf16 = [&](const std::string & name, Loaded & dst) {
        load_raw(name, dst);
        dst.f32 = bf16_to_f32(dst.raw);
    };
    // encoder.embed_norm is the ONE F16 (not BF16) tensor this class reads - reinterpreting it as BF16
    // silently produces garbage weights, not an error.
    auto load_f16 = [&](const std::string & name, Loaded & dst) {
        load_raw(name, dst);
        dst.f32.resize(dst.raw.size() / 2);
        ggml_fp16_to_fp32_row(reinterpret_cast<const ggml_fp16_t *>(dst.raw.data()), dst.f32.data(), (int64_t) dst.f32.size());
    };
    for (int i = 0; i < n_layers; i++) {
        const std::string lp = "encoder.layers." + std::to_string(i) + ".";
        auto & l = raw_layers[static_cast<size_t>(i)];
        load_raw(lp + "attn.w_qkv.weight", l.w_qkv);
        load_raw(lp + "attn.out_proj.weight", l.w_out);
        load_raw(lp + "ffn.net.0.weight", l.w_ffn_in);
        load_raw(lp + "ffn.net.3.weight", l.w_ffn_out);
        load_bf16(lp + "norm1.weight", l.n1w);   load_bf16(lp + "norm1.bias", l.n1b);
        load_bf16(lp + "norm2.weight", l.n2w);   load_bf16(lp + "norm2.bias", l.n2b);
        load_bf16(lp + "attn.out_proj.bias", l.ob);
        load_bf16(lp + "ffn.net.0.bias", l.fib); load_bf16(lp + "ffn.net.3.bias", l.fob);
    }
    m.hidden = raw_layers[0].n1w.ne[0];

    Loaded embed_norm_w, embed_norm_b, final_norm_w, final_norm_b, enc_proj_w, enc_proj_b, upsample_w, upsample_b,
           head_hidden_w, head_hidden_b, speaker_w, speaker_b;
    load_f16("encoder.embed_norm.weight", embed_norm_w);
    load_f16("encoder.embed_norm.bias", embed_norm_b);
    load_bf16("encoder.final_norm.weight", final_norm_w);
    load_bf16("encoder.final_norm.bias", final_norm_b);
    load_raw("sortformer_modules.encoder_proj.weight", enc_proj_w);
    load_bf16("sortformer_modules.encoder_proj.bias", enc_proj_b);
    load_bf16("sortformer_modules.subpixel_upsample.weight", upsample_w);
    load_bf16("sortformer_modules.subpixel_upsample.bias", upsample_b);
    load_raw("sortformer_modules.first_hidden_to_hidden.weight", head_hidden_w);
    load_bf16("sortformer_modules.first_hidden_to_hidden.bias", head_hidden_b);
    load_raw("sortformer_modules.single_hidden_to_spks.weight", speaker_w);
    load_bf16("sortformer_modules.single_hidden_to_spks.bias", speaker_b);

    m.head_hidden = enc_proj_w.ne[1];
    m.num_speakers = speaker_w.ne[1];
    m.upsample_kernel = upsample_w.ne[0];
    m.upsample_factor = upsample_w.ne[2] / upsample_w.ne[1];
    // head_dim/heads cannot be recovered from any tensor shape alone (512 = 8x64 = 16x32 = ...) - settled
    // empirically against audio.cpp's real runtime trace in this session's earlier port work
    // (docs/one-runtime-merge.md SS9-13): head_dim=64, heads=8. Also the literal defaults in ref/audiocpp's
    // own EncoderConfig for this exact model (assets.h), an independent second confirmation.
    m.heads = 8;
    m.head_dim = m.hidden / m.heads;

    // --- create and feed the persistent weight context, once ------------------------------------------------
    size_t tensor_count = 0;
    for (auto & l : raw_layers) { (void) l; tensor_count += 11; }
    tensor_count += 10;  // head
    m.weights_ctx = ggml_init({ggml_tensor_overhead() * (tensor_count + 16), nullptr, true});
    if (m.weights_ctx == nullptr) throw std::runtime_error("DiarCrispASR: ggml_init (weights) failed");
    ggml_context * wctx = m.weights_ctx;

    m.layers.resize(static_cast<size_t>(n_layers));
    for (int i = 0; i < n_layers; i++) {
        auto & raw = raw_layers[static_cast<size_t>(i)];
        auto & l = m.layers[static_cast<size_t>(i)];
        l.w_qkv     = ggml_new_tensor_2d(wctx, GGML_TYPE_Q8_0, raw.w_qkv.ne[0], raw.w_qkv.ne[1]);
        l.w_out     = ggml_new_tensor_2d(wctx, GGML_TYPE_Q8_0, raw.w_out.ne[0], raw.w_out.ne[1]);
        l.w_ffn_in  = ggml_new_tensor_2d(wctx, GGML_TYPE_Q8_0, raw.w_ffn_in.ne[0], raw.w_ffn_in.ne[1]);
        l.w_ffn_out = ggml_new_tensor_2d(wctx, GGML_TYPE_Q8_0, raw.w_ffn_out.ne[0], raw.w_ffn_out.ne[1]);
        l.n1w = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, (int64_t) raw.n1w.f32.size());
        l.n1b = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, (int64_t) raw.n1b.f32.size());
        l.n2w = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, (int64_t) raw.n2w.f32.size());
        l.n2b = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, (int64_t) raw.n2b.f32.size());
        l.ob  = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, (int64_t) raw.ob.f32.size());
        l.fib = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, (int64_t) raw.fib.f32.size());
        l.fob = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, (int64_t) raw.fob.f32.size());
    }
    m.enw = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, embed_norm_w.ne[0]);
    m.enb = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, embed_norm_b.ne[0]);
    m.fnw = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, final_norm_w.ne[0]);
    m.fnb = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, final_norm_b.ne[0]);
    m.epw = ggml_new_tensor_2d(wctx, GGML_TYPE_Q8_0, enc_proj_w.ne[0], enc_proj_w.ne[1]);
    m.epb = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, enc_proj_b.ne[0]);
    m.usw = ggml_new_tensor_3d(wctx, GGML_TYPE_F16, upsample_w.ne[0], upsample_w.ne[1], upsample_w.ne[2]);
    m.usb = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, upsample_b.ne[0]);
    m.hhw = ggml_new_tensor_2d(wctx, GGML_TYPE_Q8_0, head_hidden_w.ne[0], head_hidden_w.ne[1]);
    m.hhb = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, head_hidden_b.ne[0]);
    m.shw = ggml_new_tensor_2d(wctx, GGML_TYPE_Q8_0, speaker_w.ne[0], speaker_w.ne[1]);
    m.shb = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, speaker_b.ne[0]);

    m.weights_buf = ggml_backend_alloc_ctx_tensors(wctx, m.backend);
    if (m.weights_buf == nullptr) throw std::runtime_error("DiarCrispASR: weight buffer allocation failed");

    for (int i = 0; i < n_layers; i++) {
        auto & raw = raw_layers[static_cast<size_t>(i)];
        auto & l = m.layers[static_cast<size_t>(i)];
        feed_raw(l.w_qkv, raw.w_qkv.raw);       feed_raw(l.w_out, raw.w_out.raw);
        feed_raw(l.w_ffn_in, raw.w_ffn_in.raw); feed_raw(l.w_ffn_out, raw.w_ffn_out.raw);
        feed_f32(l.n1w, raw.n1w.f32); feed_f32(l.n1b, raw.n1b.f32);
        feed_f32(l.n2w, raw.n2w.f32); feed_f32(l.n2b, raw.n2b.f32);
        feed_f32(l.ob, raw.ob.f32);   feed_f32(l.fib, raw.fib.f32); feed_f32(l.fob, raw.fob.f32);
    }
    feed_f32(m.enw, embed_norm_w.f32);   feed_f32(m.enb, embed_norm_b.f32);
    feed_f32(m.fnw, final_norm_w.f32);   feed_f32(m.fnb, final_norm_b.f32);
    feed_raw(m.epw, enc_proj_w.raw);     feed_f32(m.epb, enc_proj_b.f32);
    feed_f32_as_f16(m.usw, upsample_w.f32); feed_f32(m.usb, upsample_b.f32);
    feed_raw(m.hhw, head_hidden_w.raw);  feed_f32(m.hhb, head_hidden_b.f32);
    feed_raw(m.shw, speaker_w.raw);      feed_f32(m.shb, speaker_b.f32);
    // raw_layers and the head Loaded locals go out of scope here - the only host-side copy of the weights
    // that survives is the one still needed for reference (none - the backend buffer above owns it now).
}

DiarCrispASR::~DiarCrispASR() = default;

int64_t DiarCrispASR::hidden_size() const { return impl_->hidden; }
int64_t DiarCrispASR::num_speakers() const { return impl_->num_speakers; }

std::vector<float> DiarCrispASR::encode(
    const std::vector<float> & embeddings,
    int64_t batch,
    int64_t frames,
    const std::vector<int64_t> & valid_frames) {
    if (batch != 1 || valid_frames.size() != 1) {
        throw std::runtime_error("DiarCrispASR::encode: only batch==1 is supported (streaming mode)");
    }
    Impl & m = *impl_;
    const int64_t H = m.hidden, T = frames, HD = m.head_dim, HEADS = m.heads, HALF = HD / 2;
    if (static_cast<int64_t>(embeddings.size()) != H * T) {
        throw std::runtime_error("DiarCrispASR::encode: embeddings size does not match hidden*frames");
    }
    ggml_backend_t backend = m.backend;
    const int n_layers = m.n_layers;

    if (getenv("DIARCRISPASR_DEBUG_T") != nullptr) fprintf(stderr, "DIARCRISPASR_T %lld\n", (long long) T);
    // DIARCRISPASR_PROF: per-call phase timing. Used to settle whether --diar-native's ~11% "diar_s" gap
    // (docs/one-runtime-merge.md SS16) was graph-rebuild/allocation overhead - it isn't: compute_ms alone is
    // ~3.1-3.6s per call (confirmed in total isolation via tools/diar_crispasr_bench.cpp, no engine/ASR
    // running), dwarfing rebuild_ms (tens to ~200ms) and feed_ms (~2ms). This also surfaced a real
    // measurement artifact in the composite's own [stats] line, unrelated to this class: see
    // docs/one-runtime-merge.md SS19.
    const bool prof = getenv("DIARCRISPASR_PROF") != nullptr;
    const auto t_call0 = prof ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
    const long pf0 = prof ? minflt_now() : 0;
    double ms_rebuild = 0.0;
    if (!m.graph || m.graph->frames != T) {
        // (Re)build the ACTIVATION graph for this frame count. Cheap regardless of how often it happens -
        // ~10 small tensors plus the compute-node graph, referencing the persistent weight tensors above by
        // pointer. No weight is created, fed, or touched here.
        //
        // Free the OLD graph's buffer before allocating the new one, not after: since packed frame counts
        // almost never repeat (audio.cpp's own no-padding optimisation), this rebuild runs on nearly every
        // call, and the two buffers are large enough (a 31-layer flash-attention activation graph, not the
        // "~10 small tensors" of just the leaves) that holding both alive during the swap - the previous
        // order, where the new buffer was allocated before `m.graph` released the old one - measured a
        // reproducible 1568 MB peak RSS on a 45 s clip versus audio.cpp's own 396 MB for the same clip.
        m.graph.reset();
        auto g = std::make_unique<Impl::Graph>();
        g->frames = T;
        const size_t arena_bytes =
            ggml_tensor_overhead() * (size_t) (60 * n_layers + 64) +
            ggml_graph_overhead_custom((size_t) (96 * n_layers + 128), false);
        g->ctx = ggml_init({arena_bytes, nullptr, true});
        if (g->ctx == nullptr) throw std::runtime_error("DiarCrispASR::encode: ggml_init failed");
        ggml_context * ctx = g->ctx;

        // Inputs live in their OWN context with their own buffer. They used to share `ctx` with every compute
        // node, and ggml_backend_alloc_ctx_tensors(ctx) then allocated ALL of those nodes (not just these four,
        // as the old comment claimed) in one flat buffer with zero reuse - ~1.7 GB at T=548, first-touched on
        // the first compute after every rebuild: the 8x page-fault gap and the 1.5-2 GB peak RSS of
        // docs/one-runtime-merge.md SS23-25. gallocr now places the intermediates with lifetime-based reuse,
        // and skips these four because they already have data, so it can never overwrite cos/sin.
        g->leaf_ctx = ggml_init({ggml_tensor_overhead() * 8, nullptr, true});
        if (g->leaf_ctx == nullptr) throw std::runtime_error("DiarCrispASR::encode: ggml_init (leaf) failed");
        ggml_tensor * in   = ggml_new_tensor_2d(g->leaf_ctx, GGML_TYPE_F32, H, T);
        ggml_tensor * mask = ggml_new_tensor_4d(g->leaf_ctx, GGML_TYPE_F16, T, T, 1, 1);
        ggml_tensor * cos  = ggml_new_tensor_4d(g->leaf_ctx, GGML_TYPE_F32, HALF, T, HEADS, 1);
        ggml_tensor * sin  = ggml_new_tensor_4d(g->leaf_ctx, GGML_TYPE_F32, HALF, T, HEADS, 1);

        // --- encoder layer, tools/encoder_port.cpp's proven op sequence, unchanged -------------------------
        const auto build_layer = [&](ggml_tensor * x, int i) {
            const auto & w = m.layers[static_cast<size_t>(i)];
            ggml_tensor * n1 = ggml_add(ctx, ggml_mul(ctx, ggml_norm(ctx, x, m.eps), w.n1w), w.n1b);
            ggml_tensor * qkv = ggml_cont(ctx, ggml_mul_mat(ctx, w.w_qkv, n1));
            // Q materialises a contiguous copy (cont -> reshape -> permute), same as ref/audiocpp's own
            // GroupedQueryAttentionModule does for its query tensor unconditionally (encoder.cpp:
            // `ensure_backend_addressable_layout(ctx, q_heads)`, called regardless of lowering variant).
            const auto heads_fn = [&](int64_t off) {
                ggml_tensor * sl = ggml_view_2d(ctx, qkv, H, T, qkv->nb[1], (size_t) off * ggml_element_size(qkv));
                return ggml_permute(ctx, ggml_reshape_4d(ctx, ggml_cont(ctx, sl), HD, HEADS, T, 1), 0, 2, 1, 3);
            };
            // K and V skip that copy: a single strided ggml_view_4d directly on qkv reproduces the exact same
            // [HD, T, HEADS, 1] logical tensor heads_fn builds via cont+reshape+permute, with zero elements
            // copied. This mirrors ref/audiocpp's own FlashGroupedViewKV lowering (view_kv=true - K/V pass
            // straight through, only Q gets materialised) - found by diffing this port against that file
            // while chasing the residual ~5% --diar-native gap (docs/one-runtime-merge.md SS19-20). Must
            // produce byte-identical results to the cont-based form since it is the same memory, viewed
            // differently, not a numerical change - verified below, not assumed.
            const auto heads_view_fn = [&](int64_t off) {
                return ggml_view_4d(ctx, qkv, HD, T, HEADS, 1,
                                     qkv->nb[1], (size_t) HD * qkv->nb[0], (size_t) HD * qkv->nb[0] * HEADS,
                                     (size_t) off * ggml_element_size(qkv));
            };
            ggml_tensor * q0 = heads_fn(0), * k0 = heads_view_fn(H), * v = heads_view_fn(2 * H);
            const auto rope_fn = [&](ggml_tensor * t) {
                ggml_tensor * x1 = ggml_view_4d(ctx, t, HALF, T, HEADS, 1, t->nb[1], t->nb[2], t->nb[3], 0);
                ggml_tensor * x2 = ggml_view_4d(ctx, t, HALF, T, HEADS, 1, t->nb[1], t->nb[2], t->nb[3], HALF * t->nb[0]);
                ggml_tensor * c = ggml_repeat(ctx, cos, x1), * s = ggml_repeat(ctx, sin, x1);
                return ggml_concat(ctx, ggml_sub(ctx, ggml_mul(ctx, x1, c), ggml_mul(ctx, x2, s)),
                                    ggml_add(ctx, ggml_mul(ctx, x2, c), ggml_mul(ctx, x1, s)), 0);
            };
            ggml_tensor * q = rope_fn(q0), * k = rope_fn(k0);
            ggml_tensor * attn = ggml_flash_attn_ext(ctx, q, k, v, mask, 1.0f / std::sqrt((float) HD), 0.0f, 0.0f);
            ggml_flash_attn_ext_set_prec(attn, GGML_PREC_F32);
            attn = ggml_reshape_2d(ctx, ggml_cont(ctx, attn), H, T);
            ggml_tensor * o = ggml_add(ctx, ggml_mul_mat(ctx, w.w_out, attn), w.ob);
            ggml_tensor * x1 = ggml_add(ctx, x, o);
            ggml_tensor * n2 = ggml_add(ctx, ggml_mul(ctx, ggml_norm(ctx, x1, m.eps), w.n2w), w.n2b);
            ggml_tensor * ff_in  = ggml_add(ctx, ggml_mul_mat(ctx, w.w_ffn_in, n2), w.fib);
            ggml_tensor * ff_gel = ggml_gelu_erf(ctx, ff_in);
            ggml_tensor * ff_out = ggml_add(ctx, ggml_mul_mat(ctx, w.w_ffn_out, ff_gel), w.fob);
            return ggml_add(ctx, x1, ff_out);
        };
        // encoder.embed_norm: audio.cpp's encoder graph LayerNorms its input BEFORE layer 0
        // (ref/audiocpp encoder.cpp, `weights.embed_norm`). tools/encoder_port.cpp started from the
        // AUDIOCPP_DUMP_LAYER0 `layer0_in` dump, which is already post-embed_norm, so the port never had this
        // op - and every encode() since the wiring commit ran on un-normalised input (docs/one-runtime-merge.md
        // SS26: 100% of outputs differed from audio.cpp, max |delta| 0.97; WER held, diarization did not).
        ggml_tensor * stage = ggml_add(ctx, ggml_mul(ctx, ggml_norm(ctx, in, m.eps), m.enw), m.enb);
        for (int i = 0; i < n_layers; i++) stage = build_layer(stage, i);

        // --- head, tools/head_port.cpp's proven op sequence, unchanged --------------------------------------
        ggml_tensor * fn = ggml_add(ctx, ggml_mul(ctx, ggml_norm(ctx, stage, m.eps), m.fnw), m.fnb);
        ggml_tensor * proj = ggml_add(ctx, ggml_mul_mat(ctx, m.epw, fn), m.epb);
        ggml_tensor * proj_t = ggml_cont(ctx, ggml_transpose(ctx, proj));
        // audio.cpp's unpatched ggml_conv_1d builds an F16 im2col, i.e. rounds this input to F16 before the
        // dot; CrispASR's forked one keeps F32 (docs/one-runtime-merge.md, the ~1e-3 conv1d gap). Round-trip
        // through F16 here so both runtimes see the same input values - the gap was enough to flip borderline
        // speaker decisions on 3 of 11 validation clips (SS26).
        proj_t = ggml_cast(ctx, ggml_cast(ctx, proj_t, GGML_TYPE_F16), GGML_TYPE_F32);
        ggml_tensor * conv = ggml_conv_1d(ctx, m.usw, proj_t, 1, (int) (m.upsample_kernel / 2), 1);
        ggml_tensor * bias_bc = ggml_reshape_2d(ctx, m.usb, 1, m.head_hidden * m.upsample_factor);
        conv = ggml_add(ctx, conv, bias_bc);
        ggml_tensor * conv_t = ggml_cont(ctx, ggml_transpose(ctx, conv));
        ggml_tensor * up = ggml_reshape_2d(ctx, conv_t, m.head_hidden, T * m.upsample_factor);
        ggml_tensor * r1 = ggml_relu(ctx, up);
        ggml_tensor * hh = ggml_add(ctx, ggml_mul_mat(ctx, m.hhw, r1), m.hhb);
        ggml_tensor * r2 = ggml_relu(ctx, hh);
        ggml_tensor * sh = ggml_add(ctx, ggml_mul_mat(ctx, m.shw, r2), m.shb);
        ggml_tensor * out = ggml_sigmoid(ctx, sh);

        g->gf = ggml_new_graph_custom(ctx, (size_t) (96 * n_layers + 128), false);
        ggml_build_forward_expand(g->gf, out);
        ggml_set_output(out);
        ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors(g->leaf_ctx, backend);
        if (buf == nullptr) throw std::runtime_error("DiarCrispASR::encode: alloc failed");
        g->buf = buf;
        g->alloc = ggml_gallocr_new(ggml_backend_get_default_buffer_type(backend));
        ggml_gallocr_alloc_graph(g->alloc, g->gf);

        // RoPE tables depend only on T (this rebuild's key) - feed once per distinct T, not on every call.
        feed_f32(cos, rope_table(HEADS, T, HD, m.rope_theta, true));
        feed_f32(sin, rope_table(HEADS, T, HD, m.rope_theta, false));

        g->in = in; g->mask = mask; g->out = out;
        m.graph = std::move(g);
        if (prof) ms_rebuild = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t_call0).count();
    }

    // Every call, cached or not: the activation inputs. `mask` depends on valid_frames[0], which can differ
    // call to call even at the same T, so - unlike the RoPE tables above - it cannot be pinned to rebuild.
    const auto t_feed0 = prof ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
    Impl::Graph & g = *m.graph;
    ggml_backend_tensor_set(g.in, embeddings.data(), 0, embeddings.size() * sizeof(float));
    {
        const auto mvals = attention_mask(valid_frames[0], T);
        std::vector<ggml_fp16_t> mf16(mvals.size());
        ggml_fp32_to_fp16_row(mvals.data(), mf16.data(), (int64_t) mvals.size());
        ggml_backend_tensor_set(g.mask, mf16.data(), 0, mf16.size() * sizeof(ggml_fp16_t));
    }
    const auto t_compute0 = prof ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
    const long pf1 = prof ? minflt_now() : 0;

    if (ggml_backend_graph_compute(backend, g.gf) != GGML_STATUS_SUCCESS) {
        throw std::runtime_error("DiarCrispASR::encode: graph compute failed");
    }
    const auto t_readback0 = prof ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
    const long pf2 = prof ? minflt_now() : 0;

    std::vector<float> result((size_t) ggml_nelements(g.out));
    ggml_backend_tensor_get(g.out, result.data(), 0, result.size() * sizeof(float));
    if (prof) {
        const auto t_end = std::chrono::steady_clock::now();
        fprintf(stderr, "DIARCRISPASR_PROF T=%lld rebuild_ms=%.2f feed_ms=%.2f compute_ms=%.2f readback_ms=%.2f total_ms=%.2f\n",
                (long long) T, ms_rebuild,
                std::chrono::duration<double, std::milli>(t_compute0 - t_feed0).count(),
                std::chrono::duration<double, std::milli>(t_readback0 - t_compute0).count(),
                std::chrono::duration<double, std::milli>(t_end - t_readback0).count(),
                std::chrono::duration<double, std::milli>(t_end - t_call0).count());
        fprintf(stderr, "DIARCRISPASR_PF T=%lld pre_compute=%ld compute=%ld\n", (long long) T, pf1 - pf0, pf2 - pf1);
    }
    return result;
}

}  // namespace nemo
