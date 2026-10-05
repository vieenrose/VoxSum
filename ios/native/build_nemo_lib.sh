#!/bin/bash
# libvoxsum-nemo.a for iOS: engine + fusion + diarizer glue + the C bridge (nemo_c). Needs build_ios.sh first.
#   build_nemo_lib.sh <iphonesimulator|iphoneos> <x86_64|arm64>
set -e
SDK=${1:-iphonesimulator}; ARCH=${2:-x86_64}
ROOT=$(cd "$(dirname "$0")/../.." && pwd); N=$ROOT/native; E=$ROOT/app/src/main/cpp/nemo; I=$ROOT/ios/native
B=$ROOT/build-ios/$SDK-$ARCH; mkdir -p $B/nemo-obj
MIN=$([ $SDK = iphonesimulator ] && echo -mios-simulator-version-min=17.0 || echo -miphoneos-version-min=17.0)
for f in $E/engine.cpp $E/fusion.cpp $E/diar_crispasr.cpp $I/nemo_c.cpp; do
  xcrun --sdk $SDK clang++ -c -O2 -std=c++17 -w -DNEMO_HAVE_TOKEN_TIMES -include $I/apple_sched_shim.h -arch $ARCH \
    -isysroot $(xcrun --sdk $SDK --show-sdk-path) $MIN -I$E -I$I -I$N/crispasr/src -I$N/audiocpp/include \
    -I$N/crispasr-ggml/include -I$N/crispasr-ggml/src -I$N/crispasr-ggml/src/ggml-cpu $f -o $B/nemo-obj/$(basename $f .cpp).o
done
rm -f $B/libvoxsum-nemo.a; xcrun libtool -static -o $B/libvoxsum-nemo.a $B/nemo-obj/*.o
echo "built $B/libvoxsum-nemo.a"
