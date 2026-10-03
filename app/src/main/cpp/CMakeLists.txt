cmake_minimum_required(VERSION 3.22.1)
project(voxsum)

# ---------------------------------------------------------------------------
# Native layer for VoxSumDroid.
#
#   ASR + diarization -> nemo-x-asr-diarizer (CrispASR x-asr + audio.cpp
#                        Nemotron-3 diarization, ggml), built from the
#                        native/audiocpp, native/crispasr, native/crispasr-ggml
#                        submodules.
#   summarization     -> llama.cpp (GGUF), built FROM SOURCE out of the
#                        native/llama.cpp submodule (MIT), so F-Droid can
#                        reproduce it on its own server.
#
# ---------------------------------------------------------------------------

set(NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../native")

# ---------------------------------------------------------------------------
# ASR + diarization — nemo-x-asr-diarizer (nemo/, vendored from
# github.com/vieenrose/nemo-x-asr-diarizer.cpp): streaming X-ASR (CrispASR) +
# streaming Nemotron-3 diarization (audio.cpp), one audio timeline.
#
# THREE ggml copies live in this process (llama.cpp's, CrispASR's, audio.cpp's)
# and they must never bind to each other:
#   * audio.cpp builds as libaudiocpp.so with its ggml hidden behind a version
#     script (checked: no exported ggml_/gguf_ symbols);
#   * CrispASR + its ggml link STATICALLY into libvoxsum-nemo.so, which exports
#     only its JNI entry points (nemo/nemo_jni.map).
# Both are ExternalProjects because their ggml targets would collide with
# llama.cpp's in one CMake tree. Same ARMv8.2-A+dotprod floor as llama.cpp below.
# ---------------------------------------------------------------------------
include(ExternalProject)
# The CPU floor for every ggml copy in the app: ARMv8.2-A with the int8 dot-product extension.
# Only on arm64: ggml turns GGML_CPU_ARM_ARCH into -march, which breaks the x86_64 emulator build.
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(VOXSUM_ARM_ARCH armv8.2-a+dotprod)
else()
    set(VOXSUM_ARM_ARCH "")
endif()
set(NEMO_ARCH ${VOXSUM_ARM_ARCH})
set(NEMO_COMMON_ARGS
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
    -DANDROID_ABI=${ANDROID_ABI}
    -DANDROID_PLATFORM=${ANDROID_PLATFORM}
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}
    -DBUILD_SHARED_LIBS=OFF
    -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF
    -DGGML_CPU_ARM_ARCH=${NEMO_ARCH})

set(AUDIOCPP_BIN ${CMAKE_CURRENT_BINARY_DIR}/audiocpp-build)
ExternalProject_Add(audiocpp_ext
    SOURCE_DIR ${NATIVE_DIR}/audiocpp
    BINARY_DIR ${AUDIOCPP_BIN}
    CMAKE_ARGS ${NEMO_COMMON_ARGS}
        -DAUDIOCPP_BUILD_C_API=ON
        -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=nemotron_3_diar
        -DENGINE_ENABLE_NATIVE_CPU=OFF -DENGINE_ENABLE_OPENMP=OFF
        -DCMAKE_SHARED_LINKER_FLAGS=-llog
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target audiocpp
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS ${AUDIOCPP_BIN}/bin/libaudiocpp.so)
add_library(audiocpp SHARED IMPORTED)
set_target_properties(audiocpp PROPERTIES IMPORTED_LOCATION ${AUDIOCPP_BIN}/bin/libaudiocpp.so)
add_dependencies(audiocpp audiocpp_ext)

set(CRISP_BIN ${CMAKE_CURRENT_BINARY_DIR}/crispasr-build)
set(CRISP_LIBS
    ${CRISP_BIN}/src/libxasr.a
    ${CRISP_BIN}/src/libcrispasr-core.a
    ${CRISP_BIN}/ggml/src/libggml.a
    ${CRISP_BIN}/ggml/src/libggml-cpu.a
    ${CRISP_BIN}/ggml/src/libggml-base.a)
ExternalProject_Add(crispasr_ext
    SOURCE_DIR ${NATIVE_DIR}/crispasr
    BINARY_DIR ${CRISP_BIN}
    CMAKE_ARGS ${NEMO_COMMON_ARGS}
        -DCMAKE_PROJECT_crispasr_INCLUDE=${CMAKE_CURRENT_SOURCE_DIR}/nemo/crispasr_ggml.cmake
        -DNEMO_GGML_SRC=${NATIVE_DIR}/crispasr-ggml
        # CrispASR includes ggml internals via its own ../ggml/src; point that at the pinned fork.
        -DCMAKE_CXX_FLAGS=-I${NATIVE_DIR}/crispasr-ggml/src
        # The fork declares a diagnostic counter only under GGML_USE_LLAMAFILE (and every published
        # measurement ran with it on), so it must stay on.
        -DGGML_LLAMAFILE=ON
        -DCRISPASR_NO_C2PA_NATIVE=ON -DCRISPASR_MEDIA_NDK=OFF
        -DCRISPASR_BUILD_EXAMPLES=OFF -DCRISPASR_BUILD_TESTS=OFF -DCRISPASR_BUILD_SERVER=OFF
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR>
        --target xasr crispasr-core ggml ggml-base ggml-cpu
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS ${CRISP_LIBS})

add_library(voxsum-nemo SHARED
    nemo/nemo_jni.cpp
    nemo/engine.cpp
    nemo/fusion.cpp
    nemo/diar_crispasr.cpp)
add_dependencies(voxsum-nemo crispasr_ext audiocpp_ext)
target_compile_features(voxsum-nemo PRIVATE cxx_std_17)
target_compile_definitions(voxsum-nemo PRIVATE NEMO_HAVE_TOKEN_TIMES)
target_compile_options(voxsum-nemo PRIVATE -O2 -w)
target_include_directories(voxsum-nemo PRIVATE
    nemo
    ${NATIVE_DIR}/crispasr/src
    ${NATIVE_DIR}/audiocpp/include
    ${NATIVE_DIR}/crispasr-ggml/include
    ${NATIVE_DIR}/crispasr-ggml/src
    ${NATIVE_DIR}/crispasr-ggml/src/ggml-cpu)
target_link_options(voxsum-nemo PRIVATE
    -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/nemo/nemo_jni.map
    -fopenmp -static-openmp)   # CrispASR's x-asr kernels use OpenMP; link the NDK's libomp statically
target_link_libraries(voxsum-nemo ${CRISP_LIBS} audiocpp android log dl m)


# ---------------------------------------------------------------------------
# llama.cpp — the GGUF runtime of the meeting reader (Gemma-4-E2B Q4_0; see LlmRegistry).
#
# ARMv8.2-A + DOTPROD FLOOR (VOXSUM_ARM_ARCH, shared with the nemo engine above). Support for
# ARMv8.0 devices (the Boox Tab Mini C's Cortex-A73) was dropped 2026-09: the int8 dot-product
# kernels are what make the q8_0/Q4_0 models run in real time. ggml only uses them when
# GGML_CPU_ARM_ARCH asks for them (GGML_NATIVE probes the BUILD host, meaningless when
# cross-compiling), so the arch is pinned explicitly. No i8mm: the Dimensity 900/1300 reference
# phones lack it and would SIGILL. A device without dotprod is refused at startup
# (CpuSupport.kt) instead of crashing on the first model load.
# ---------------------------------------------------------------------------
set(GGML_NATIVE            OFF      CACHE BOOL   "" FORCE)  # never probe the BUILD host's CPU
set(GGML_CPU_ALL_VARIANTS  OFF      CACHE BOOL   "" FORCE)
set(GGML_CPU_ARM_ARCH      ${VOXSUM_ARM_ARCH} CACHE STRING "" FORCE)
set(GGML_OPENMP            OFF      CACHE BOOL   "" FORCE)  # the Android NDK has no libgomp
set(GGML_LLAMAFILE         OFF      CACHE BOOL   "" FORCE)
set(LLAMA_BUILD_TESTS      OFF      CACHE BOOL   "" FORCE)
set(LLAMA_BUILD_EXAMPLES   OFF      CACHE BOOL   "" FORCE)
set(LLAMA_BUILD_TOOLS      OFF      CACHE BOOL   "" FORCE)
set(LLAMA_BUILD_SERVER     OFF      CACHE BOOL   "" FORCE)
set(LLAMA_BUILD_COMMON     OFF      CACHE BOOL   "" FORCE)
set(LLAMA_CURL             OFF      CACHE BOOL   "" FORCE)
add_subdirectory("${NATIVE_DIR}/llama.cpp" llama-build EXCLUDE_FROM_ALL)

add_library(voxsum-llm SHARED llm_jni.cpp)
target_link_libraries(voxsum-llm llama android log)


# ---------------------------------------------------------------------------
# Mobile meeting reader — the forked LiteRT-LM CPU engine (mfa/, vendored from
# github.com/vieenrose/LiteRT-LM branch mobile-fused-attention, see mfa/PROVENANCE.md) running
# Google's Gemma-4 mobile graphs (E2B, E4B) with the int8 attention fused into one custom op.
# It links the stock libLiteRt.so of the com.google.ai.edge.litert:litert AAR, extracted by the
# Gradle task extractLiteRt into LITERT_SO_DIR (the C headers are vendored in mfa/third_party).
# The tokenizer is SentencePiece (native/sentencepiece submodule, static).
# ---------------------------------------------------------------------------
if(DEFINED LITERT_SO_DIR AND EXISTS "${LITERT_SO_DIR}/${ANDROID_ABI}/libLiteRt.so")
    set(SPM_ENABLE_SHARED OFF CACHE BOOL "" FORCE)
    set(SPM_ENABLE_TCMALLOC OFF CACHE BOOL "" FORCE)
    set(SPM_BUILD_TEST OFF CACHE BOOL "" FORCE)
    # Its CLI tools are built too (the Android Gradle plugin builds every target); its logging
    # calls __android_log_write, so every target from here on links liblog.
    link_libraries(log)
    add_subdirectory("${NATIVE_DIR}/sentencepiece" sentencepiece-build EXCLUDE_FROM_ALL)

    add_library(litert SHARED IMPORTED)
    set_target_properties(litert PROPERTIES IMPORTED_LOCATION "${LITERT_SO_DIR}/${ANDROID_ABI}/libLiteRt.so")

    add_library(voxsum-mfa SHARED mfa/mfa_jni.cpp mfa/mfa_engine.cc mfa/i8_attn.cc)
    target_compile_features(voxsum-mfa PRIVATE cxx_std_17)
    target_compile_options(voxsum-mfa PRIVATE -O3 -fexceptions -fopenmp)
    if(ANDROID_ABI STREQUAL "arm64-v8a")
        target_compile_options(voxsum-mfa PRIVATE -march=${VOXSUM_ARM_ARCH})
    endif()
    target_include_directories(voxsum-mfa PRIVATE mfa mfa/third_party "${NATIVE_DIR}/sentencepiece/src")
    target_link_options(voxsum-mfa PRIVATE -fopenmp -static-openmp)
    target_link_libraries(voxsum-mfa litert sentencepiece-static android log)
else()
    message(WARNING "libLiteRt.so not found under LITERT_SO_DIR — the mobile reader is not built")
endif()
