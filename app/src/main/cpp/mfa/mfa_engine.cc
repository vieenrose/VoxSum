// mfa_engine.cc - see mfa_engine.h. The model protocol is unchanged from the upstream driver:
//   - the cache length is the magic number 32003 in the graph, replaced at load by `ctx`;
//   - token -> embedder -> embeddings, token -> per-layer embedder -> PLE;
//   - prefill_128: positions start.., causal bool mask, param_tensor = [start, start+n, start+n];
//   - the int8 KV caches are inputs AND outputs of both signatures, one buffer each, in place;
//   - the last prompt token is fed by the first decode step.
#include "mfa_engine.h"

#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#ifdef __ANDROID__
#include <sched.h>
#include <sys/system_properties.h>
#endif

#include <algorithm>
#include <map>
#include <random>
#include <stdexcept>
#include <thread>

#include "i8_attn.h"
#include "litert/c/litert_common.h"
#include "litert/c/litert_compiled_model.h"
#include "litert/c/litert_custom_op_kernel.h"
#include "litert/c/litert_environment.h"
#include "litert/c/litert_environment_options.h"
#include "litert/c/litert_model.h"
#include "litert/c/litert_opaque_options.h"
#include "litert/c/litert_options.h"
#include "litert/c/litert_tensor_buffer.h"
#include "litert/c/litert_tensor_buffer_requirements.h"

namespace mfa {
namespace {

[[noreturn]] void fail(const std::string& what) { throw std::runtime_error(what); }
#define ENSURE(x)                                                                              \
    do {                                                                                       \
        LiteRtStatus s_ = (x);                                                                 \
        if (s_ != kLiteRtStatusOk) fail(std::string(#x) + " -> " + std::to_string((int)s_)); \
    } while (0)

// Pins the calling thread to the upper-tier cores (max frequency above the lowest tier). The
// XNNPACK pool and the OpenMP team are created from this thread and inherit the mask; left to the
// scheduler, a 4-thread decode lands partly on the little cores (Note10+: 3.2 vs 12.5 tok/s).
// MFA_NO_PIN=1 disables it. Android only (no affinity API on iOS).
void pin_upper_cores() {
#ifdef __ANDROID__
    { char v[8] = {0}; __system_property_get("debug.voxsum.nopin", v); if (getenv("MFA_NO_PIN") || v[0] == '1') return; }
    long f[64]; int n = 0; long lo = 0;
    for (; n < 64; ++n) {
        char path[96]; snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", n);
        FILE* fp = fopen(path, "r"); if (!fp) break;
        if (fscanf(fp, "%ld", &f[n]) != 1) f[n] = 0;
        fclose(fp);
        if (n == 0 || f[n] < lo) lo = f[n];
    }
    cpu_set_t cs; CPU_ZERO(&cs); int k = 0;
    for (int c = 0; c < n; ++c) if (f[c] > lo) { CPU_SET(c, &cs); ++k; }
    if (k > 0) sched_setaffinity(0, sizeof cs, &cs);
#endif
}

double now_s() { timeval tv; gettimeofday(&tv, nullptr); return tv.tv_sec + tv.tv_usec * 1e-6; }

LiteRtOpaqueOptions cpu_options(int threads, const std::string& cache) {
    char toml[1024]; int off = 0;
    if (threads > 0) off += snprintf(toml + off, sizeof toml - off, "num_threads = %d\n", threads);
    if (!cache.empty()) off += snprintf(toml + off, sizeof toml - off, "weight_cache_file_path = \"%s\"\n", cache.c_str());
    if (off <= 0) return nullptr;
    char* payload = strdup(toml);
    LiteRtOpaqueOptions oo = nullptr;
    if (LiteRtCreateOpaqueOptions("xnnpack", payload, [](void* p) { free(p); }, &oo) != kLiteRtStatusOk) {
        free(payload);
        return nullptr;
    }
    return oo;
}

// Private writable mapping: the runtime rewrites the magic cache length inside a few constant
// buffers at load (a read-only mapping crashes it). Untouched pages stay file-backed.
struct Mapping {
    void* p = MAP_FAILED; size_t n = 0;
    explicit Mapping(const std::string& path) {
        int fd = open(path.c_str(), O_RDONLY);
        if (fd < 0) fail("cannot open " + path);
        struct stat st; fstat(fd, &st); n = st.st_size;
        p = mmap(nullptr, n, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
        close(fd);
        if (p == MAP_FAILED) fail("mmap " + path);
    }
    ~Mapping() { if (p != MAP_FAILED) munmap(p, n); }
};

// backend: 0 CPU (XNNPACK, the default and the only one the weight cache serves), 1 GPU, 2 NPU.
// NPU keeps the CPU as the fallback for ops it cannot take. GPU runs the GPU variant of the reader
// (no fused int8 attention op) wholly on ML Drift, with LiteRT-LM's options: the KV caches and the
// param tensor are external tensors kept in GPU storage buffers, fp32 activations (fp16 drifts to
// English on short prompts), and the constant tensors shared between prefill and decode (7.7 ->
// 1.7 GB peak on a Note10+).
const char* kGpuOptions =
    "precision = 2\n"
    "enable_infinite_float_capping = true\n"
    "external_tensors_mode = false\n"
    "external_tensor_patterns = [\"kv_cache_\", \"param_tensor\"]\n"
    "buffer_storage_tensor_patterns = [\"kv_cache_c_\", \"kv_cache_\", \"param_tensor\"]\n"
    "hint_fully_delegated_to_single_delegate = true\n"
    "enable_constant_tensors_sharing = true\n"
    "madvise_original_shared_tensors = true\n";

LiteRtOptions make_options(int threads, const std::string& cache, bool fused, int attn_threads, int backend = 0) {
    LiteRtOptions opts;
    ENSURE(LiteRtCreateOptions(&opts));
    int hw = kLiteRtHwAcceleratorCpu;
    if (backend == 1) hw = kLiteRtHwAcceleratorGpu;
    if (backend == 2) hw |= kLiteRtHwAcceleratorNpu;
    ENSURE(LiteRtSetOptionsHardwareAccelerators(opts, static_cast<LiteRtHwAccelerators>(hw)));
    if (backend == 1) {
        LiteRtOpaqueOptions go = nullptr;
        ENSURE(LiteRtCreateOpaqueOptions("gpu_options", strdup(kGpuOptions), [](void* p) { free(p); }, &go));
        ENSURE(LiteRtAddOpaqueOptions(opts, go));
    }
    if (LiteRtOpaqueOptions oo = cpu_options(threads, cache)) ENSURE(LiteRtAddOpaqueOptions(opts, oo));
    if (fused) {
        LiteRtCustomOpKernel k; void* ud = nullptr;
        i8_attn_kernel(attn_threads > 0 ? attn_threads : threads, &k, &ud);
        ENSURE(LiteRtAddCustomOpKernelOption(opts, "voxsum.i8_attention", 1, &k, ud));
    }
    return opts;
}

struct Sig {
    LiteRtParamIndex index = 0;
    std::vector<std::string> in_names, out_names;
    std::vector<LiteRtTensorBuffer> in, out;
    int in_idx(const std::string& n) const {
        for (size_t i = 0; i < in_names.size(); ++i) if (in_names[i] == n) return (int)i;
        return -1;
    }
    int out_idx(const std::string& n) const {
        for (size_t i = 0; i < out_names.size(); ++i) if (out_names[i] == n) return (int)i;
        return -1;
    }
};

struct Model {
    LiteRtEnvironment env;
    std::unique_ptr<Mapping> map;
    LiteRtModel model = nullptr;
    LiteRtOptions opts = nullptr;
    LiteRtCompiledModel cm = nullptr;
    std::map<std::string, Sig> sigs;
    std::map<std::string, LiteRtTensorBuffer>* shared;   // the KV caches, by name
    std::vector<LiteRtTensorBuffer> owned;
    bool gpu;

    Model(LiteRtEnvironment e, const std::string& path, int threads, const std::string& cache,
          bool fused, std::map<std::string, LiteRtTensorBuffer>* kv, const std::vector<std::string>& only,
          int backend = 0)
        : env(e), map(new Mapping(path)), shared(kv), gpu(backend == 1) {
        ENSURE(LiteRtCreateModelFromBuffer(env, map->p, map->n, &model));
        opts = make_options(threads, cache, fused, 0, backend);
        ENSURE(LiteRtCreateCompiledModel(env, model, opts, &cm));
        LiteRtParamIndex n = 0;
        ENSURE(LiteRtGetNumModelSignatures(model, &n));
        for (LiteRtParamIndex si = 0; si < n; ++si) {
            LiteRtSignature sig; ENSURE(LiteRtGetModelSignature(model, si, &sig));
            const char* key = nullptr; ENSURE(LiteRtGetSignatureKey(sig, &key));
            if (!only.empty() && std::find(only.begin(), only.end(), std::string(key)) == only.end()) continue;
            Sig s; s.index = si;
            LiteRtParamIndex nin = 0, nout = 0;
            ENSURE(LiteRtGetNumSignatureInputs(sig, &nin));
            ENSURE(LiteRtGetNumSignatureOutputs(sig, &nout));
            for (LiteRtParamIndex i = 0; i < nin; ++i) {
                const char* nm = nullptr; ENSURE(LiteRtGetSignatureInputName(sig, i, &nm));
                s.in_names.push_back(nm);
                s.in.push_back(buffer(sig, si, i, true, nm));
            }
            for (LiteRtParamIndex i = 0; i < nout; ++i) {
                const char* nm = nullptr; ENSURE(LiteRtGetSignatureOutputName(sig, i, &nm));
                s.out_names.push_back(nm);
                s.out.push_back(buffer(sig, si, i, false, nm));
            }
            sigs[key] = s;
        }
    }
    ~Model() {
        for (auto b : owned) LiteRtDestroyTensorBuffer(b);
        if (cm) LiteRtDestroyCompiledModel(cm);
        if (opts) LiteRtDestroyOptions(opts);
        if (model) LiteRtDestroyModel(model);
    }

    LiteRtTensorBuffer buffer(LiteRtSignature sig, LiteRtParamIndex si, LiteRtParamIndex ti, bool in, const char* name) {
        const bool is_kv = shared && !strncmp(name, "kv_cache_", 9);
        // GPU: one cache per layer, made from the output requirements (only they offer a GPU
        // buffer type) and left unbound as an input; a host-memory cache round trip corrupts it.
        if (is_kv && gpu && in) return nullptr;
        if (is_kv) {
            auto it = shared->find(name);
            if (it != shared->end()) return it->second;
        }
        LiteRtTensor t;
        ENSURE(in ? LiteRtGetSignatureInputTensorByIndex(sig, ti, &t) : LiteRtGetSignatureOutputTensorByIndex(sig, ti, &t));
        LiteRtRankedTensorType tt; ENSURE(LiteRtGetRankedTensorType(t, &tt));
        LiteRtTensorBufferRequirements req;
        ENSURE(in ? LiteRtGetCompiledModelInputBufferRequirements(cm, si, ti, &req)
                  : LiteRtGetCompiledModelOutputBufferRequirements(cm, si, ti, &req));
        size_t bytes = 0; ENSURE(LiteRtGetTensorBufferRequirementsBufferSize(req, &bytes));
        LiteRtTensorBufferType bt = kLiteRtTensorBufferTypeHostMemory;
        int nt = 0;
        if (gpu && LiteRtGetNumTensorBufferRequirementsSupportedBufferTypes(req, &nt) == kLiteRtStatusOk && nt > 0)
            ENSURE(LiteRtGetTensorBufferRequirementsSupportedTensorBufferType(req, 0, &bt));
        LiteRtTensorBuffer b;
        ENSURE(LiteRtCreateManagedTensorBuffer(env, bt, &tt, bytes, &b));
        void* p; ENSURE(LiteRtLockTensorBuffer(b, &p, kLiteRtTensorBufferLockModeWrite));
        memset(p, 0, bytes); LiteRtUnlockTensorBuffer(b);
        owned.push_back(b);
        if (is_kv) (*shared)[name] = b;
        return b;
    }
    Sig& sig(const std::string& k) {
        auto it = sigs.find(k); if (it == sigs.end()) fail("no signature " + k); return it->second;
    }
    void run(Sig& s) { ENSURE(LiteRtRunCompiledModel(cm, s.index, s.in.size(), s.in.data(), s.out.size(), s.out.data())); }
};

// First run: building the XNNPACK weight cache maps each finished step back while the original
// weights stay resident (cold E4B peaked at 4.5 GB on a Reno7). A compile-only pass builds it while
// a thread drops the cache file's pages from this process; the engine then loads warm.
void drop_mapped_pages(const std::string& path) {
    char want[4096];
    if (!realpath(path.c_str(), want)) return;
    FILE* f = fopen("/proc/self/maps", "r");
    if (!f) return;
    char line[4608];
    while (fgets(line, sizeof line, f)) {
        unsigned long a, b; char perms[8]; int off = 0;
        if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %n", &a, &b, perms, &off) < 3 || !off) continue;
        char* name = line + off; name[strcspn(name, "\n")] = 0;
        if (perms[3] == 's' && !strcmp(name, want)) madvise((void*)a, b - a, MADV_DONTNEED);
    }
    fclose(f);
}

// The embedder and per-layer-embedder tables are lookup tables: a token reads a few rows, but the
// pages read stay resident (0.84 GB of PLE table for E4B; more of it resident as the vocabulary seen
// grows). Their private read-only mappings are clean, so dropping them loses nothing: a later lookup
// reads the page back from the page cache. Upstream fork commit bd9d499 (E4B peak 2.97 -> 2.65 GB on
// a Reno7, same output and speed). Older VoxSum fix: the same idea, once, for shared mappings above.
struct Range { void* a; size_t n; };
std::vector<Range> clean_ranges(const std::string& path) {
    std::vector<Range> out;
    char want[4096];
    if (!realpath(path.c_str(), want)) return out;
    FILE* f = fopen("/proc/self/smaps", "r");
    if (!f) return out;
    char line[4608];
    Range cur{nullptr, 0}; bool match = false;
    while (fgets(line, sizeof line, f)) {
        unsigned long a, b; char perms[8]; int off = 0;
        if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %n", &a, &b, perms, &off) >= 3 && off) {
            char* name = line + off; name[strcspn(name, "\n")] = 0;
            match = perms[0] == 'r' && perms[3] == 'p' && !strcmp(name, want);
            cur = {(void*)a, (size_t)(b - a)};
        } else if (match && !strncmp(line, "Private_Dirty:", 14) && atol(line + 14) == 0) {
            out.push_back(cur);
        }
    }
    fclose(f);
    return out;
}

void build_weight_cache(LiteRtEnvironment env, const std::string& path, int threads, const std::string& cache) {
    std::atomic<bool> done{false};
    std::thread reclaim([&] { while (!done) { drop_mapped_pages(cache); usleep(200 * 1000); } });
    try {
        Mapping map(path);
        LiteRtModel model; ENSURE(LiteRtCreateModelFromBuffer(env, map.p, map.n, &model));
        LiteRtOptions opts = make_options(threads, cache, true, 0);
        LiteRtCompiledModel cm; ENSURE(LiteRtCreateCompiledModel(env, model, opts, &cm));
        LiteRtDestroyCompiledModel(cm);
        LiteRtDestroyOptions(opts);
        LiteRtDestroyModel(model);
    } catch (...) {
        done = true; reclaim.join(); unlink(cache.c_str());
        throw;
    }
    done = true; reclaim.join();
}

void* lockw(LiteRtTensorBuffer b) { void* p; ENSURE(LiteRtLockTensorBuffer(b, &p, kLiteRtTensorBufferLockModeWrite)); return p; }
const void* lockr(LiteRtTensorBuffer b) { void* p; ENSURE(LiteRtLockTensorBuffer(b, &p, kLiteRtTensorBufferLockModeRead)); return p; }
void unlock(LiteRtTensorBuffer b) { LiteRtUnlockTensorBuffer(b); }
size_t bytes_of(LiteRtTensorBuffer b) { size_t n = 0; LiteRtGetTensorBufferSize(b, &n); return n; }

constexpr int T = 128;                        // prefill_128 block
const std::vector<int> kStop = {106, 1, 50};  // <turn|>, <eos>, and the metadata's third stop id

}  // namespace

struct Engine::Impl {
    LiteRtEnvironment env = nullptr;
    std::vector<char> magic;
    std::map<std::string, LiteRtTensorBuffer> kv;
    std::unique_ptr<Model> emb, ple, lm;
    Sig *es = nullptr, *ps = nullptr, *pf = nullptr, *dc = nullptr;
    int iE, iP, iPos, iM, iPar, dE, dP, dPos, dM, dPar, dL;
    size_t hid = 0, ple_n = 0, C = 0, vocab = 0;
    std::vector<float> e, pl, logits;
    std::vector<int> fed;   // tokens whose keys and values are in the cache, by position
    std::vector<std::pair<float, int>> cand;
    std::vector<Range> tables;   // the embedder tables' clean pages, dropped every 8 lookups
    int n_embed = 0;

    ~Impl() {
        lm.reset(); ple.reset(); emb.reset();
        if (env) LiteRtDestroyEnvironment(env);
    }

    void embed(int tok) {
        if ((++n_embed & 7) == 0) for (auto& r : tables) madvise(r.a, r.n, MADV_DONTNEED);
        *(int32_t*)lockw(es->in[0]) = tok; unlock(es->in[0]); emb->run(*es);
        memcpy(e.data(), lockr(es->out[0]), hid * 4); unlock(es->out[0]);
        *(int32_t*)lockw(ps->in[0]) = tok; unlock(ps->in[0]); ple->run(*ps);
        memcpy(pl.data(), lockr(ps->out[0]), ple_n * 4); unlock(ps->out[0]);
    }

    // Stops between chunks when *stop is set (a long prefill on E4B takes seconds); `fed` always
    // matches what the cache holds, so the next request reuses the chunks already done.
    bool prefill(const std::vector<int>& ids, int from, int to, const std::atomic<bool>* stop = nullptr) {
        for (int start = from; start < to; start += T) {
            if (stop && stop->load()) return false;
            const int n = std::min(T, to - start);
            float* E = (float*)lockw(pf->in[iE]); float* P = (float*)lockw(pf->in[iP]);
            memset(E, 0, bytes_of(pf->in[iE])); memset(P, 0, bytes_of(pf->in[iP]));
            for (int t = 0; t < n; ++t) {
                embed(ids[start + t]);
                memcpy(E + (size_t)t * hid, e.data(), hid * 4); memcpy(P + (size_t)t * ple_n, pl.data(), ple_n * 4);
            }
            unlock(pf->in[iE]); unlock(pf->in[iP]);
            int32_t* pos = (int32_t*)lockw(pf->in[iPos]); memset(pos, 0, T * 4);
            for (int t = 0; t < n; ++t) pos[t] = start + t;
            unlock(pf->in[iPos]);
            uint8_t* M = (uint8_t*)lockw(pf->in[iM]); memset(M, 0, (size_t)T * C);
            for (int t = 0; t < n; ++t) memset(M + (size_t)t * C, 1, std::min<size_t>(start + t + 1, C));
            unlock(pf->in[iM]);
            int32_t* par = (int32_t*)lockw(pf->in[iPar]); memset(par, 0, bytes_of(pf->in[iPar]));
            par[0] = start; par[1] = start + n; par[2] = start + n; unlock(pf->in[iPar]);
            lm->run(*pf);
            fed.assign(ids.begin(), ids.begin() + start + n);
        }
        fed.assign(ids.begin(), ids.begin() + to);
        return true;
    }

    const float* step(int tok, int pos) {
        embed(tok);
        memcpy(lockw(dc->in[dE]), e.data(), hid * 4); unlock(dc->in[dE]);
        memcpy(lockw(dc->in[dP]), pl.data(), ple_n * 4); unlock(dc->in[dP]);
        *(int32_t*)lockw(dc->in[dPos]) = pos; unlock(dc->in[dPos]);
        uint8_t* M = (uint8_t*)lockw(dc->in[dM]); memset(M, 0, C); memset(M, 1, pos + 1); unlock(dc->in[dM]);
        int32_t* par = (int32_t*)lockw(dc->in[dPar]); memset(par, 0, bytes_of(dc->in[dPar]));
        par[0] = pos; par[1] = pos + 1; par[2] = pos + 1; unlock(dc->in[dPar]);
        lm->run(*dc);
        fed.resize(pos); fed.push_back(tok);
        const float* L = (const float*)lockr(dc->out[dL]);
        if (logits.empty()) { unlock(dc->out[dL]); return L; }   // host memory: valid until the next run
        memcpy(logits.data(), L, vocab * 4);   // GPU buffer: the mapping ends at unlock
        unlock(dc->out[dL]);
        return logits.data();
    }

    int sample(const float* L, float temp, int top_k, float top_p, std::mt19937& rng) {
        if (temp <= 0.f || top_k == 1) return (int)(std::max_element(L, L + vocab) - L);
        const int k = std::min<int>(top_k > 0 ? top_k : 64, (int)vocab);
        cand.resize(vocab);
        for (size_t i = 0; i < vocab; ++i) cand[i] = {L[i], (int)i};
        std::partial_sort(cand.begin(), cand.begin() + k, cand.end(), [](auto& a, auto& b) { return a.first > b.first; });
        double sum = 0; std::vector<double> p(k);
        for (int i = 0; i < k; ++i) sum += p[i] = exp((cand[i].first - cand[0].first) / temp);
        int keep = k; double acc = 0;
        for (int i = 0; i < k; ++i) { acc += p[i] / sum; if (acc >= top_p) { keep = i + 1; break; } }
        double tot = 0; for (int i = 0; i < keep; ++i) tot += p[i];
        double r = std::uniform_real_distribution<double>(0, tot)(rng);
        for (int i = 0; i < keep; ++i) { r -= p[i]; if (r <= 0) return cand[i].second; }
        return cand[keep - 1].second;
    }
};

Engine::Engine(const std::string& dir, const std::string& main, int ctx, int threads, const std::string& cache,
               int backend)
    : impl_(new Impl) {
    // OpenMP threads of the attention op must not spin between ops: XNNPACK runs its own pool
    // on the same cores (Reno7: prefill 80 -> 130 tok/s). Set before the OpenMP runtime starts.
    setenv("KMP_BLOCKTIME", "0", 0);
    setenv("OMP_WAIT_POLICY", "PASSIVE", 0);
    pin_upper_cores();
    Impl& m = *impl_;
    m.magic.resize(sizeof(LiteRtMagicNumberConfigs) + sizeof(LiteRtMagicNumberConfig));
    auto* cfg = reinterpret_cast<LiteRtMagicNumberConfigs*>(m.magic.data());
    cfg->num_configs = 1;
    cfg->configs[0].magic_number = 32003;
    cfg->configs[0].target_number = ctx;
    cfg->configs[0].signature_prefix = "";   // all signatures (nullptr crashes the 2.x runtime)
    LiteRtEnvOption eo; eo.tag = kLiteRtEnvOptionTagMagicNumberConfigs;
    eo.value.type = kLiteRtAnyTypeVoidPtr; eo.value.ptr_value = cfg;
    ENSURE(LiteRtCreateEnvironment(1, &eo, &m.env));

    m.emb.reset(new Model(m.env, dir + "/Section2_TFLiteModel_tf_lite_embedder.tflite", threads, "", false, nullptr, {}));
    m.ple.reset(new Model(m.env, dir + "/Section3_TFLiteModel_tf_lite_per_layer_embedder.tflite", threads, "", false, nullptr, {}));
    struct stat cst;
    if (backend == 0 && !cache.empty() && (stat(cache.c_str(), &cst) != 0 || cst.st_size == 0))
        build_weight_cache(m.env, main, threads, cache);
    m.lm.reset(new Model(m.env, main, threads, backend == 0 ? cache : std::string(), true, &m.kv,
                         {"prefill_128", "decode"}, backend));

    if (!getenv("MFA_KEEP_TABLES")) {
        m.tables = clean_ranges(dir + "/Section2_TFLiteModel_tf_lite_embedder.tflite");
        for (auto& r : clean_ranges(dir + "/Section3_TFLiteModel_tf_lite_per_layer_embedder.tflite")) m.tables.push_back(r);
    }
    m.es = &m.emb->sig("embedder"); m.ps = &m.ple->sig("per_layer_embedder");
    m.hid = bytes_of(m.es->out[0]) / 4; m.ple_n = bytes_of(m.ps->out[0]) / 4;
    m.pf = &m.lm->sig("prefill_128"); m.dc = &m.lm->sig("decode");
    for (Sig* s : {m.pf, m.dc})   // in place: the outputs of the caches are the inputs
        for (size_t i = 0; i < s->out_names.size(); ++i) {
            auto it = m.kv.find(s->out_names[i]);
            if (it != m.kv.end()) s->out[i] = it->second;
        }
    m.iE = m.pf->in_idx("embeddings"); m.iP = m.pf->in_idx("per_layer_embeddings");
    m.iPos = m.pf->in_idx("input_pos"); m.iM = m.pf->in_idx("mask"); m.iPar = m.pf->in_idx("param_tensor");
    if (m.iE < 0 || m.iP < 0 || m.iPos < 0 || m.iM < 0 || m.iPar < 0) fail("prefill signature inputs not found");
    m.C = bytes_of(m.pf->in[m.iM]) / T;
    m.dE = m.dc->in_idx("embeddings"); m.dP = m.dc->in_idx("per_layer_embeddings");
    m.dPos = m.dc->in_idx("input_pos"); m.dM = m.dc->in_idx("mask"); m.dPar = m.dc->in_idx("param_tensor");
    m.dL = m.dc->out_idx("logits");
    if (m.dE < 0 || m.dP < 0 || m.dPos < 0 || m.dM < 0 || m.dPar < 0 || m.dL < 0) fail("decode signature names not found");
    m.vocab = bytes_of(m.dc->out[m.dL]) / 4;
    m.e.resize(m.hid); m.pl.resize(m.ple_n);
    if (backend == 1) m.logits.resize(m.vocab);
}

Engine::~Engine() = default;

int Engine::context() const { return (int)impl_->C; }

int Engine::agree(const std::vector<int>& ids, const std::vector<int>& forced) {
    Impl& m = *impl_;
    const int n = (int)ids.size();
    if (n < 1 || n + forced.size() >= m.C) fail("agree: prompt too long");
    m.fed.clear();
    m.prefill(ids, 0, n - 1);
    int tok = ids.back(), pos = n - 1, hit = 0;
    for (int f : forced) {
        const float* L = m.step(tok, pos++);
        if ((int)(std::max_element(L, L + m.vocab) - L) == f) ++hit;
        tok = f;
    }
    return hit;
}

std::vector<int> Engine::generate(const std::vector<int>& ids, int max_new, float temp, int top_k, float top_p,
                                  unsigned seed, const std::function<bool(int)>& on_token, Stats* stats) {
    pin_upper_cores();
    Impl& m = *impl_;
    cancel_ = false;
    const int n = (int)ids.size();
    if (n < 1 || n >= (int)m.C) fail("prompt of " + std::to_string(n) + " tokens, cache " + std::to_string(m.C));
    int reuse = 0;
    while (reuse < (int)m.fed.size() && reuse < n - 1 && m.fed[reuse] == ids[reuse]) ++reuse;
    // A prefill-only request (max_new = 0) caches the whole prompt; otherwise the last token is
    // fed by the first decode step.
    const int upto = max_new > 0 ? n - 1 : n;
    const double t0 = now_s();
    bool prefilled = true;
    if (reuse < upto) prefilled = m.prefill(ids, reuse, upto, &cancel_);
    else m.fed.resize(upto);
    const double prefill_s = now_s() - t0, t1 = now_s();
    std::vector<int> out;
    const char* reason = "length";
    if (!prefilled) reason = "cancel";
    if (max_new > 0 && prefilled) {
        std::mt19937 rng(seed);
        int tok = ids.back(), pos = n - 1;
        for (int g = 0; g < max_new; ++g, ++pos) {
            if (pos >= (int)m.C) { reason = "ctx"; break; }
            if (cancel_) { reason = "cancel"; break; }
            tok = m.sample(m.step(tok, pos), temp, top_k, top_p, rng);
            out.push_back(tok);
            if (std::find(kStop.begin(), kStop.end(), tok) != kStop.end()) { reason = "stop"; break; }
            if (on_token && !on_token(tok)) { reason = "cancel"; break; }
        }
    }
    if (stats) {
        stats->prefilled = std::max(0, upto - reuse); stats->reused = reuse; stats->generated = (int)out.size();
        stats->prefill_s = prefill_s; stats->decode_s = now_s() - t1; stats->reason = reason;
    }
    return out;
}

}  // namespace mfa
