// C surface of the mobile reader engine and its SentencePiece tokenizer — the iOS twin of mfa_jni.cpp.
#ifndef MFA_C_H
#define MFA_C_H
#ifdef __cplusplus
extern "C" {
#endif

typedef struct mfa_engine mfa_engine;
typedef struct mfa_tok mfa_tok;

// NULL on failure; the reason is copied into err. backend: 0 CPU (XNNPACK, weight_cache), 1 GPU
// (ML Drift Metal; main_graph must be the GPU graph, weight_cache is ignored).
mfa_engine* mfa_load(const char* dir, const char* main_graph, int ctx, int threads, const char* weight_cache,
                     int backend, char* err, int err_len);
int mfa_context(mfa_engine* e);
void mfa_cancel(mfa_engine* e);                 // any thread
void mfa_free(mfa_engine* e);

// Prefill `ids` (starting with <bos>) and generate up to max_new tokens (0 = prefill only).
// on_token(id, user) returns 0 to stop. The generated ids go to *out (free with mfa_ids_free);
// returns their count, or -1 with the reason in err. stats = {prefilled, reused, generated, prefill_s, decode_s}.
int mfa_generate(mfa_engine* e, const int* ids, int n, int max_new, float temp, int top_k, float top_p,
                 unsigned seed, int (*on_token)(int, void*), void* user, int** out, double stats[5],
                 char* err, int err_len);
void mfa_ids_free(int* ids);

// Teacher-forced agreement: prefill ids, feed forced token by token and count the steps whose greedy
// choice is the next forced token (a backend that computes wrong scores near 0). -1 on failure.
int mfa_agree(mfa_engine* e, const int* ids, int n, const int* forced, int nf, char* err, int err_len);

mfa_tok* mfa_tok_load(const char* path, char* err, int err_len);
int mfa_tok_encode(mfa_tok* t, const char* text, int** out);          // count; free with mfa_ids_free
char* mfa_tok_decode(mfa_tok* t, const int* ids, int n, int* nbytes); // UTF-8 bytes (may end mid-character); free()
void mfa_tok_free(mfa_tok* t);

#ifdef __cplusplus
}
#endif
#endif
