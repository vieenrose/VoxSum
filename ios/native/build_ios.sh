#!/bin/bash
# Builds the ggml-based engines (CrispASR x-asr, audio.cpp diarization) for iOS.
#   build_ios.sh <iphonesimulator|iphoneos> <x86_64|arm64> [target...]
# Run on the Mac; sources are the repo's native/ submodules (android branch layout).
set -e
SDK=${1:-iphonesimulator}; ARCH=${2:-x86_64}; shift 2 || true
ROOT=$(cd "$(dirname "$0")/../.." && pwd); NATIVE=$ROOT/native
CMAKE=${CMAKE:-$HOME/tools/cmake-3.31.6-macos-universal/CMake.app/Contents/bin/cmake}
OUT=$ROOT/build-ios/$SDK-$ARCH; mkdir -p $OUT
COMMON=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$SDK -DCMAKE_OSX_ARCHITECTURES=$ARCH
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_ACCELERATE=OFF)
[ "$ARCH" = arm64 ] && COMMON+=(-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod)
if [ "$1" != audiocpp-only ]; then
$CMAKE -S $NATIVE/crispasr -B $OUT/crispasr "${COMMON[@]}" \
  -DCMAKE_PROJECT_crispasr_INCLUDE=$ROOT/ios/native/crispasr_ggml.cmake -DNEMO_GGML_SRC=$NATIVE/crispasr-ggml \
  -DCMAKE_CXX_FLAGS=-I$NATIVE/crispasr-ggml/src -DGGML_LLAMAFILE=ON \
  -DCRISPASR_NO_C2PA_NATIVE=ON -DCRISPASR_MEDIA_NDK=OFF \
  -DCRISPASR_BUILD_EXAMPLES=OFF -DCRISPASR_BUILD_TESTS=OFF -DCRISPASR_BUILD_SERVER=OFF
$CMAKE --build $OUT/crispasr -j4 --target xasr crispasr-core ggml ggml-base ggml-cpu
fi
# audio.cpp: iOS rusage has no ru_minflt (profiling-only counter) — patched idempotently, submodule stays pristine in git.
sed -i "" "s/push_back(ru.ru_minflt)/push_back(0)/" $NATIVE/audiocpp/src/models/nemotron_3_diar/session.cpp
# audio.cpp as a dylib with its ggml hidden (src/capi/audiocpp.symbols) — never share symbols with CrispASR's ggml.
$CMAKE -S $NATIVE/audiocpp -B $OUT/audiocpp "${COMMON[@]}" \
  -DCMAKE_PROJECT_INCLUDE=$ROOT/ios/native/ios_stub.cmake -DAUDIOCPP_BUILD_C_API=ON -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=nemotron_3_diar \
  -DENGINE_ENABLE_NATIVE_CPU=OFF -DENGINE_ENABLE_OPENMP=OFF
$CMAKE --build $OUT/audiocpp -j4 --target audiocpp
