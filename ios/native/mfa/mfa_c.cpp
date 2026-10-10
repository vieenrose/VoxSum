#include "mfa_c.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "mfa_engine.h"
#include "sentencepiece_processor.h"

namespace {
void set_err(char* err, int len, const std::string& m) {
    if (err && len > 0) { std::snprintf(err, (size_t)len, "%s", m.c_str()); }
}
}  // namespace

struct mfa_engine { mfa::Engine* e; };
struct mfa_tok { sentencepiece::SentencePieceProcessor sp; };

extern "C" {

mfa_engine* mfa_load(const char* dir, const char* main_graph, int ctx, int threads, const char* cache, int backend,
                     char* err, int err_len) {
    try {
        return new mfa_engine{new mfa::Engine(dir, main_graph, ctx, threads, cache, backend)};
    } catch (const std::exception& ex) {
        set_err(err, err_len, ex.what());
        return nullptr;
    }
}

int mfa_context(mfa_engine* h) { return h ? h->e->context() : 0; }
void mfa_cancel(mfa_engine* h) { if (h) h->e->cancel(); }
void mfa_free(mfa_engine* h) { if (h) { delete h->e; delete h; } }

int mfa_generate(mfa_engine* h, const int* ids, int n, int max_new, float temp, int top_k, float top_p, unsigned seed,
                 int (*on_token)(int, void*), void* user, int** out, double stats[5], char* err, int err_len) {
    if (!h) { set_err(err, err_len, "engine not loaded"); return -1; }
    mfa::Stats st;
    try {
        std::vector<int> r = h->e->generate(std::vector<int>(ids, ids + n), max_new, temp, top_k, top_p, seed,
                                            [&](int t) -> bool { return !on_token || on_token(t, user) != 0; }, &st);
        if (stats) { stats[0] = st.prefilled; stats[1] = st.reused; stats[2] = st.generated; stats[3] = st.prefill_s; stats[4] = st.decode_s; }
        *out = static_cast<int*>(std::malloc(sizeof(int) * (r.size() + 1)));
        std::memcpy(*out, r.data(), sizeof(int) * r.size());
        return static_cast<int>(r.size());
    } catch (const std::exception& ex) {
        set_err(err, err_len, ex.what());
        return -1;
    }
}

void mfa_ids_free(int* ids) { std::free(ids); }

int mfa_agree(mfa_engine* h, const int* ids, int n, const int* forced, int nf, char* err, int err_len) {
    if (!h) { set_err(err, err_len, "engine not loaded"); return -1; }
    try {
        return h->e->agree(std::vector<int>(ids, ids + n), std::vector<int>(forced, forced + nf));
    } catch (const std::exception& ex) {
        set_err(err, err_len, ex.what());
        return -1;
    }
}

mfa_tok* mfa_tok_load(const char* path, char* err, int err_len) {
    auto* t = new mfa_tok;
    const auto st = t->sp.Load(path);
    if (!st.ok()) { set_err(err, err_len, "tokenizer: " + st.ToString()); delete t; return nullptr; }
    return t;
}

int mfa_tok_encode(mfa_tok* t, const char* text, int** out) {
    std::vector<int> ids;
    t->sp.Encode(text, &ids);
    *out = static_cast<int*>(std::malloc(sizeof(int) * (ids.size() + 1)));
    std::memcpy(*out, ids.data(), sizeof(int) * ids.size());
    return static_cast<int>(ids.size());
}

char* mfa_tok_decode(mfa_tok* t, const int* ids, int n, int* nbytes) {
    std::string s;
    t->sp.Decode(std::vector<int>(ids, ids + n), &s);
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    std::memcpy(p, s.c_str(), s.size() + 1);
    *nbytes = static_cast<int>(s.size());
    return p;
}

void mfa_tok_free(mfa_tok* t) { delete t; }

}  // extern "C"
