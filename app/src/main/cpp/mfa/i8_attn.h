// voxsum.i8_attention custom op (see i8_attn.cc).
#ifndef I8_ATTN_H
#define I8_ATTN_H

#include "litert/c/litert_custom_op_kernel.h"

#ifdef __cplusplus
extern "C" {
#endif

// Fill the kernel and user_data to register with LiteRtAddCustomOpKernelOption
// ("voxsum.i8_attention", version 1). threads <= 0: OpenMP default.
void i8_attn_kernel(int threads, LiteRtCustomOpKernel* kernel, void** user_data);

#ifdef __cplusplus
}
#endif
#endif
