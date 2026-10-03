// voxsum.i8_attention: fused attention over the int8 KV cache of Google's Gemma-4 mobile graph.
//
// Replaces runtime_bmm(q,K) -> SELECT_V2(mask) -> SOFTMAX -> runtime_bmm(P,V) (see
// tools/litert_fused/rewrite_mobile_attention.py). Only the live columns are touched: mask true
// and column < param[2]; nothing of the size of the cache is allocated, so the XNNPACK
// workspaces that grow with ctx^2 are gone.
//
// Inputs : 0 q      (1,KV,R,d) f32      row r belongs to token r % T
//          1 K      (1,KV,C,d) int8     per-tensor scale/zero in meta_f
//          2 V      (1,KV,d,C) int8     transposed: column j of row x is V[x*C + j]
//          3 mask   (1,1,T,C)  bool
//          4 param  (1,1,1,7)  int32    [start, end, end, ...]
//          5 meta_f [beta, k_scale, k_zero, v_scale, v_zero]
//          6 meta_i [KV, R, d, T]
// Output : 0 ctx    (1,KV,R,d) f32
//
// Masked columns are excluded from the softmax (the graph selects a large negative value,
// whose exp underflows to 0). Sums and the output are accumulated in double: the next layers
// quantize their input on static int8 ranges, and a reimplemented attention must stay close
// to the reference for the argmax to agree (lesson of vieenrose/LiteRT turboquant-tq3). The
// dot products run in float (vectorized) over chunks summed in double; the softmax normalizer is
// kept in double.
#include "i8_attn.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#include <algorithm>
#include <vector>

#ifdef _OPENMP
#include <omp.h>
#endif

#include "litert/c/litert_tensor_buffer.h"

namespace {

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

// C[u][v] = sum_k A[u][k] * B[v][k] for a tile of mu <= 4 rows of A and nv <= 4 rows of B
// (both row-major along k). Used for q.K^T and P.V^T, whose reduction dims are contiguous.
// Partial sums run in float over chunks of KC elements and are added in double: a plain float
// accumulation over a 4k-column P.V^T flips near-tied argmaxes of the next layers (measured on
// E4B: greedy output differs from the unfused graph at token 44; chunked: identical).
static constexpr int KC = 64;
static inline void dot_tile(const float* A, size_t lda, int mu, const float* B, size_t ldb, int nv,
                            int k, float out[4][4]) {
  double acc[4][4] = {};
#if defined(__aarch64__)
  if (mu == 4 && nv == 4 && (k & 3) == 0) {
    for (int x0 = 0; x0 < k; x0 += KC) {
      const int x1 = std::min(k, x0 + KC);
      float32x4_t c[4][4];
      for (int u = 0; u < 4; ++u) for (int v = 0; v < 4; ++v) c[u][v] = vdupq_n_f32(0.f);
      for (int x = x0; x < x1; x += 4) {
        float32x4_t a[4], b[4];
        for (int u = 0; u < 4; ++u) a[u] = vld1q_f32(A + u * lda + x);
        for (int v = 0; v < 4; ++v) b[v] = vld1q_f32(B + v * ldb + x);
        for (int u = 0; u < 4; ++u)
          for (int v = 0; v < 4; ++v) c[u][v] = vfmaq_f32(c[u][v], a[u], b[v]);
      }
      for (int u = 0; u < 4; ++u) for (int v = 0; v < 4; ++v) acc[u][v] += vaddvq_f32(c[u][v]);
    }
    for (int u = 0; u < 4; ++u) for (int v = 0; v < 4; ++v) out[u][v] = (float)acc[u][v];
    return;
  }
#endif
  for (int u = 0; u < mu; ++u)
    for (int v = 0; v < nv; ++v) {
      const float* a = A + u * lda;
      const float* b = B + v * ldb;
      for (int x0 = 0; x0 < k; x0 += KC) {
        const int x1 = std::min(k, x0 + KC);
        float part = 0.f;
#pragma omp simd reduction(+ : part)
        for (int x = x0; x < x1; ++x) part += a[x] * b[x];
        acc[u][v] += part;
      }
      out[u][v] = (float)acc[u][v];
    }
}

struct Op {
  int threads = 0;
};

LiteRtStatus Init(void*, const void*, size_t) { return kLiteRtStatusOk; }

LiteRtStatus OutLayouts(void*, size_t num_inputs, const LiteRtLayout* in, size_t num_outputs,
                        LiteRtLayout* out) {
  if (num_inputs < 1 || num_outputs != 1) return kLiteRtStatusErrorInvalidArgument;
  out[0] = in[0];                       // ctx has the shape of q
  return kLiteRtStatusOk;
}

LiteRtStatus Destroy(void*) { return kLiteRtStatusOk; }

LiteRtStatus Run(void* user_data, size_t num_inputs, const LiteRtTensorBuffer* inputs,
                 size_t num_outputs, LiteRtTensorBuffer* outputs) {
  if (num_inputs != 7 || num_outputs != 1) {
    fprintf(stderr, "i8_attention: %zu inputs, %zu outputs\n", num_inputs, num_outputs);
    return kLiteRtStatusErrorInvalidArgument;
  }
  const Op* op = static_cast<const Op*>(user_data);
  size_t nb[7], ob;
  void* p[7];
  void* po;
  for (int i = 0; i < 7; ++i) {
    if (LiteRtGetTensorBufferSize(inputs[i], &nb[i]) != kLiteRtStatusOk ||
        LiteRtLockTensorBuffer(inputs[i], &p[i], kLiteRtTensorBufferLockModeRead) != kLiteRtStatusOk) {
      fprintf(stderr, "i8_attention: cannot lock input %d\n", i);
      return kLiteRtStatusErrorRuntimeFailure;
    }
  }
  if (LiteRtGetTensorBufferSize(outputs[0], &ob) != kLiteRtStatusOk ||
      LiteRtLockTensorBuffer(outputs[0], &po, kLiteRtTensorBufferLockModeWrite) != kLiteRtStatusOk)
    return kLiteRtStatusErrorRuntimeFailure;

  const float* q = (const float*)p[0];
  const int8_t* K = (const int8_t*)p[1];
  const int8_t* V = (const int8_t*)p[2];
  const uint8_t* mask = (const uint8_t*)p[3];
  const int32_t* param = (const int32_t*)p[4];
  const float* mf = (const float*)p[5];
  const int32_t* mi = (const int32_t*)p[6];
  float* out = (float*)po;
  const int KV = mi[0], R = mi[1], d = mi[2], T = mi[3];
  const int C = (int)(nb[3] / (size_t)T);
  LiteRtStatus st = kLiteRtStatusOk;
  if ((size_t)KV * C * d > nb[1] || (size_t)KV * d * C > nb[2] || (size_t)KV * R * d * 4 > nb[0] ||
      ob < (size_t)KV * R * d * 4) {
    st = kLiteRtStatusErrorInvalidArgument;
    fprintf(stderr, "i8_attention: sizes q %zu K %zu V %zu mask %zu param %zu mf %zu mi %zu out %zu; KV %d R %d d %d T %d C %d\n",
            nb[0], nb[1], nb[2], nb[3], nb[4], nb[5], nb[6], ob, KV, R, d, T, C);
  } else {
    const int end = param[2] > 0 ? std::min(param[2], C) : C;
    const float beta = mf[0], ks = mf[1], kz = mf[2], vs = mf[3], vz = mf[4];
    const int rows = KV * R;
    // visible column range of each token row (causal or sliding window: contiguous)
    std::vector<int> lo(T), hi(T);
    for (int t = 0; t < T; ++t) {
      const uint8_t* m = mask + (size_t)t * C;
      int a = 0, b = end;
      while (a < b && !m[a]) ++a;
      while (b > a && !m[b - 1]) --b;
      lo[t] = a; hi[t] = b;
    }
    // Blocks of RB rows of one KV head share every K/V row they read. Within a block the column
    // range is the union of the rows' ranges; masked columns are dropped at the softmax.
    const int RB = 4, JB = 256, XB = 32;
    const int nrb = (R + RB - 1) / RB;
    std::vector<int> blo(KV * nrb), bhi(KV * nrb);
    for (int h = 0; h < KV; ++h)
      for (int rb = 0; rb < nrb; ++rb) {
        int a = C, b = 0;
        for (int r = rb * RB; r < std::min(R, rb * RB + RB); ++r) {
          a = std::min(a, lo[r % T]); b = std::max(b, hi[r % T]);
        }
        blo[h * nrb + rb] = a; bhi[h * nrb + rb] = std::max(a, b);
      }
    static std::vector<float> scratch;   // scores, then probabilities: rows x C (Run is not reentrant)
    scratch.resize((size_t)rows * C);
    float* const S = scratch.data();
    std::vector<double> sums(rows, 0.0);
    // Few rows (decode: one token) gain nothing from many threads, and every extra OpenMP thread
    // competes with XNNPACK's own pool between ops; prefill rows use them all.
    const int all = op->threads > 0 ? op->threads : omp_get_max_threads();
    const int nth = rows <= 32 ? std::min(2, all) : all;
    // the live columns of the cache, converted to float once per call (int8 -> f32, zero point
    // removed): Kf (KV, C, d) on rows [jlo, jhi), Vf (KV, d, C) on columns [jlo, jhi)
    int jlo = C, jhi = 0;
    for (int t = 0; t < T; ++t) if (lo[t] < hi[t]) { jlo = std::min(jlo, lo[t]); jhi = std::max(jhi, hi[t]); }
    if (jhi < jlo) jhi = jlo;
    static std::vector<float> kbuf, vbuf;
    kbuf.resize((size_t)KV * C * d);
    vbuf.resize((size_t)KV * d * C);
    float* const Kf = kbuf.data();
    float* const Vf = vbuf.data();
#pragma omp parallel for schedule(static) num_threads(nth)
    for (int hj = 0; hj < KV * (jhi - jlo); ++hj) {
      const int h = hj / (jhi - jlo), j = jlo + hj % (jhi - jlo);
      const int8_t* kr = K + ((size_t)h * C + j) * d;
      float* kf = Kf + ((size_t)h * C + j) * d;
      for (int x = 0; x < d; ++x) kf[x] = (float)kr[x] - kz;
    }
#pragma omp parallel for schedule(static) num_threads(nth)
    for (int hx = 0; hx < KV * d; ++hx) {
      const int8_t* vr = V + (size_t)hx * C;
      float* vf = Vf + (size_t)hx * C;
      for (int j = jlo; j < jhi; ++j) vf[j] = (float)vr[j] - vz;
    }
    const int njb = (C + JB - 1) / JB;
    // phase 1: scores, tasks = (head, block of RB rows, block of JB columns), 4x4 tiles
#pragma omp parallel for schedule(dynamic) num_threads(nth)
    for (int task = 0; task < KV * nrb * njb; ++task) {
      const int hb = task / njb, jb = task % njb, h = hb / nrb, rb = hb % nrb;
      const int j0 = std::max(blo[hb], jb * JB), j1 = std::min(bhi[hb], jb * JB + JB);
      if (j0 >= j1) continue;
      const int r0 = rb * RB, nr = std::min(R, r0 + RB) - r0;
      const float* qb = q + ((size_t)h * R + r0) * d;
      for (int j = j0; j < j1; j += 4) {
        const int nj = std::min(4, j1 - j);
        float tile[4][4];
        dot_tile(qb, d, nr, Kf + ((size_t)h * C + j) * d, d, nj, d, tile);
        for (int u = 0; u < nr; ++u) {
          float* Sr = S + ((size_t)h * R + r0 + u) * C + j;
          for (int v = 0; v < nj; ++v) Sr[v] = beta * ks * tile[u][v];
        }
      }
    }
    // phase 2: softmax per row over its visible columns; the normalizer in double
#pragma omp parallel for schedule(static) num_threads(nth)
    for (int i = 0; i < rows; ++i) {
      const int h = i / R, r = i % R, t = r % T, rb = r / RB;
      const int a = blo[h * nrb + rb], b = bhi[h * nrb + rb];
      float* Sr = S + (size_t)i * C;
      const uint8_t* m = mask + (size_t)t * C;
      float mx = -INFINITY;
      for (int j = lo[t]; j < hi[t]; ++j) if (m[j]) mx = std::max(mx, Sr[j]);
      double sum = 0.0;
      // phase 3 reads 4-aligned ranges: zero the margins around [a, b)
      for (int j = a & ~3; j < a; ++j) Sr[j] = 0.f;
      for (int j = b; j < std::min(C, (b + 3) & ~3); ++j) Sr[j] = 0.f;
      for (int j = a; j < b; ++j) {
        const float pj = (j >= lo[t] && j < hi[t] && m[j]) ? expf(Sr[j] - mx) : 0.f;
        Sr[j] = pj;
        sum += pj;
      }
      sums[i] = sum;
    }
    // phase 3: P.Vf^T (Vf already centred), tasks = (head, block of RB rows, block of XB dims)
    const int nxb = (d + XB - 1) / XB;
#pragma omp parallel for schedule(dynamic) num_threads(nth)
    for (int task = 0; task < KV * nrb * nxb; ++task) {
      const int hb = task / nxb, xb = task % nxb, h = hb / nrb, rb = hb % nrb;
      const int a = blo[hb], b = bhi[hb];
      const int r0 = rb * RB, nr = std::min(R, r0 + RB) - r0;
      const int k0 = a & ~3;                     // aligned start; P is 0 outside [a, b)
      const int k1 = std::min(C, (b + 3) & ~3);
      for (int x = xb * XB; x < std::min(d, xb * XB + XB); x += 4) {
        const int nx = std::min(4, std::min(d, xb * XB + XB) - x);
        float tile[4][4];
        dot_tile(S + ((size_t)h * R + r0) * C + k0, C, nr, Vf + ((size_t)h * d + x) * C + k0, C, nx,
                 k1 - k0, tile);
        for (int u = 0; u < nr; ++u) {
          const int i = h * R + r0 + u;
          for (int v = 0; v < nx; ++v)
            out[(size_t)i * d + x + v] = sums[i] > 0.0 ? (float)((double)tile[u][v] * (double)vs / sums[i]) : 0.f;
        }
      }
    }
  }
  for (int i = 0; i < 7; ++i) LiteRtUnlockTensorBuffer(inputs[i]);
  LiteRtUnlockTensorBuffer(outputs[0]);
  return st;
}

Op g_op;

}  // namespace

extern "C" void i8_attn_kernel(int threads, LiteRtCustomOpKernel* kernel, void** user_data) {
  g_op.threads = threads;
  kernel->Init = Init;
  kernel->GetOutputLayouts = OutLayouts;
  kernel->Run = Run;
  kernel->Destroy = Destroy;
  *user_data = &g_op;
}
