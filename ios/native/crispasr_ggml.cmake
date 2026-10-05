# Injected via CMAKE_PROJECT_crispasr_INCLUDE: builds CrispASR's x-asr against the PINNED ggml fork
# (native/crispasr-ggml) instead of CrispASR's nested submodule. Defining the `ggml` target here makes
# CrispASR's `if (NOT TARGET ggml)` skip its own copy, which keeps every native dependency a top-level,
# non-recursive submodule (audio.cpp's nested submodule is an SSH URL a CI checkout cannot fetch).
add_compile_definitions(GGML_MAX_NAME=128)   # what CrispASR sets before its own add_subdirectory(ggml)
add_subdirectory(${NEMO_GGML_SRC} ${CMAKE_BINARY_DIR}/ggml)
