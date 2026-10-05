// C bridge for the nemo-x-asr-diarizer streaming engine — the iOS twin of nemo_jni.cpp (same string encoding).
// Segments cross the boundary as one UTF-8 string: records separated by RS (0x1e), fields by US (0x1f):
//   speaker US start_s US end_s US text.   nemo_live() joins frozen and tail with GS (0x1d).
#ifndef NEMO_C_H
#define NEMO_C_H
#ifdef __cplusplus
extern "C" {
#endif

typedef struct nemo_handle nemo_handle;

// NULL on failure (the reason goes to stderr).
nemo_handle* nemo_create(const char* xasr_path, const char* diar_path, int threads, double settle_s);
int nemo_push(nemo_handle* h, const float* pcm, int n);                 // 1 = ok
// Heap string, free with nemo_string_free.
char* nemo_live(nemo_handle* h);
char* nemo_finish(nemo_handle* h);                                       // NULL on failure
double nemo_fed_seconds(nemo_handle* h);
void nemo_string_free(char* s);
void nemo_free(nemo_handle* h);

#ifdef __cplusplus
}
#endif
#endif
