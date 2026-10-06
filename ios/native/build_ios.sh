#!/bin/bash
# Builds the ggml-based engines (CrispASR x-asr, audio.cpp diarization) for iOS.
#   build_ios.sh <iphonesimulator|iphoneos> <x86_64|arm64> [target...]
# Run on the Mac; sources are the repo's native/ submodules (android branch layout).
set -e
SDK=${1:-iphonesimulator}; ARCH=${2:-x86_64}; shift 2 || true
ROOT=$(cd "$(dirname "$0")/../.." && pwd); NATIVE=$ROOT/native
CMAKE=${CMAKE:-$HOME/tools/cmake-3.31.6-macos-universal/CMake.app/Contents/bin/cmake}
# SDK=macosx: native Mac build (host proxy for Metal timings: M1 GPU is the same family as A14/A15)
case $SDK in macosx) MINV=-mmacosx-version-min=14.0; SYSN=Darwin; DT=14.0;; iphonesimulator) MINV=-mios-simulator-version-min=17.0; SYSN=iOS; DT=17.0;; *) MINV=-miphoneos-version-min=17.0; SYSN=iOS; DT=17.0;; esac
OBJC_SYS="-isysroot $(xcrun --sdk $SDK --show-sdk-path) -arch $ARCH $MINV"
TAG=${TAG:-}; METAL=${METAL:-OFF}; ACCEL=${ACCEL:-OFF}   # TAG=-metal / METAL=ON / ACCEL=ON: GPU / Accelerate variants side by side
OUT=$ROOT/build-ios/$SDK-$ARCH$TAG; mkdir -p $OUT
COMMON=(-DCMAKE_SYSTEM_NAME=$SYSN -DCMAKE_OSX_SYSROOT=$SDK -DCMAKE_OSX_ARCHITECTURES=$ARCH
  -DCMAKE_OSX_DEPLOYMENT_TARGET=$DT -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_METAL=$METAL -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=$ACCEL -DGGML_ACCELERATE=$ACCEL)
# CMake 3.31 leaves the OBJC rules unset for CMAKE_SYSTEM_NAME=iOS; ggml-metal has .m files
if [ $METAL = ON ]; then COMMON+=("-DCMAKE_OBJC_COMPILE_OBJECT=<CMAKE_OBJC_COMPILER> <DEFINES> <INCLUDES> <FLAGS> -o <OBJECT> -c <SOURCE>" "-DCMAKE_OBJCXX_COMPILE_OBJECT=<CMAKE_OBJCXX_COMPILER> <DEFINES> <INCLUDES> <FLAGS> -o <OBJECT> -c <SOURCE>"); fi
[ "$ARCH" = arm64 ] && COMMON+=(-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod)
if [ "$1" != audiocpp-only ]; then
$CMAKE -S $NATIVE/crispasr -B $OUT/crispasr "${COMMON[@]}" \
  -DCMAKE_PROJECT_crispasr_INCLUDE=$ROOT/ios/native/crispasr_ggml.cmake -DNEMO_GGML_SRC=$NATIVE/crispasr-ggml \
  "-DCMAKE_CXX_FLAGS=-I$NATIVE/crispasr-ggml/src -I$NATIVE/crispasr-ggml/include" -DGGML_LLAMAFILE=ON "-DCMAKE_OBJC_FLAGS=$OBJC_SYS -I$NATIVE/crispasr-ggml/include -I$NATIVE/crispasr-ggml/src" "-DCMAKE_OBJCXX_FLAGS=$OBJC_SYS -I$NATIVE/crispasr-ggml/include -I$NATIVE/crispasr-ggml/src" \
  -DCRISPASR_NO_C2PA_NATIVE=ON -DCRISPASR_MEDIA_NDK=OFF \
  -DCRISPASR_BUILD_EXAMPLES=OFF -DCRISPASR_BUILD_TESTS=OFF -DCRISPASR_BUILD_SERVER=OFF
$CMAKE --build $OUT/crispasr -j4 --target xasr crispasr-core ggml ggml-base ggml-cpu $([ $METAL = ON ] && echo ggml-metal) $([ $ACCEL = ON ] && echo ggml-blas)
fi
# audio.cpp: iOS rusage has no ru_minflt (profiling-only counter) — patched idempotently, submodule stays pristine in git.
sed -i "" "s/push_back(ru.ru_minflt)/push_back(0)/" $NATIVE/audiocpp/src/models/nemotron_3_diar/session.cpp
# audio.cpp as a dylib with its ggml hidden (src/capi/audiocpp.symbols) — never share symbols with CrispASR's ggml.
$CMAKE -S $NATIVE/audiocpp -B $OUT/audiocpp "${COMMON[@]}" \
  -DCMAKE_PROJECT_INCLUDE=$ROOT/ios/native/ios_stub.cmake -DAUDIOCPP_BUILD_C_API=ON -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=nemotron_3_diar \
  -DENGINE_ENABLE_NATIVE_CPU=OFF -DENGINE_ENABLE_OPENMP=OFF
$CMAKE --build $OUT/audiocpp -j4 --target audiocpp
