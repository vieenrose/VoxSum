#!/bin/bash
# nemo_eval for iOS: the exact engine the app ships, driven from the command line.
#   build_nemo_eval.sh <iphonesimulator|iphoneos> <x86_64|arm64>   (after build_ios.sh for the same pair)
# Run a simulator build with:  xcrun simctl spawn booted <build>/nemo_eval <xasr.gguf> <diar.gguf> in.wav out.json 4
set -e
SDK=${1:-iphonesimulator}; ARCH=${2:-x86_64}
ROOT=$(cd "$(dirname "$0")/../.." && pwd); N=$ROOT/native; E=$ROOT/app/src/main/cpp/nemo
B=$ROOT/build-ios/$SDK-$ARCH; C=$B/crispasr
xcrun --sdk $SDK clang++ -O2 -std=c++17 -w -include $ROOT/ios/native/apple_sched_shim.h -DNEMO_HAVE_TOKEN_TIMES -arch $ARCH \
  -isysroot $(xcrun --sdk $SDK --show-sdk-path) $([ $SDK = iphonesimulator ] && echo -mios-simulator-version-min=17.0 || echo -miphoneos-version-min=17.0) \
  -I$E -I$N/crispasr/src -I$N/audiocpp/include -I$N/crispasr-ggml/include -I$N/crispasr-ggml/src -I$N/crispasr-ggml/src/ggml-cpu \
  $E/engine.cpp $E/fusion.cpp $E/diar_crispasr.cpp $ROOT/tools/nemo-eval/nemo_eval.cpp -o $B/nemo_eval \
  -L$B/audiocpp/bin -laudiocpp $C/src/libxasr.a $C/src/libcrispasr-core.a $C/ggml/src/libggml.a $C/ggml/src/libggml-cpu.a \
  $C/ggml/src/libggml-base.a -lpthread -lm -Wl,-rpath,$B/audiocpp/bin
echo "built $B/nemo_eval"
