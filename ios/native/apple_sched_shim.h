// Force-included when building nemo/engine.cpp for Apple platforms: Linux CPU affinity does not exist there.
// apply_affinity() finds no /proc/self/task and returns -1 before ever calling these.
#pragma once
#include <sys/types.h>
typedef struct { unsigned long bits[16]; } cpu_set_t;
#define CPU_ZERO(s) ((void)0)
#define CPU_SET(i, s) ((void)0)
static inline int sched_setaffinity(pid_t, size_t, const cpu_set_t*) { return -1; }
