#!/bin/bash
# libvoxsum-mfa.a (reader engine + SentencePiece C bridge) for a device or simulator slice.
# The LiteRT symbols come from CLiteRTLM.xcframework at link time (see build_app.sh); needs build_ios.sh first
# (it builds sentencepiece as part of audio.cpp).   build_mfa_lib.sh <iphoneos|iphonesimulator> <arm64|x86_64>
set -e
SDK=${1:-iphoneos}; ARCH=${2:-arm64}
ROOT=$(cd "$(dirname "$0")/../.." && pwd); M=$ROOT/ios/native/mfa; B=$ROOT/build-ios/$SDK-$ARCH; mkdir -p $B/mfa-obj
MIN=$([ $SDK = iphonesimulator ] && echo -mios-simulator-version-min=17.0 || echo -miphoneos-version-min=17.0)
for f in $M/mfa_c.cpp $M/mfa_engine.cc $M/i8_attn.cc; do
  xcrun --sdk $SDK clang++ -c -O3 -std=c++17 -fexceptions -fblocks -Wno-unknown-pragmas -arch $ARCH \
    -isysroot $(xcrun --sdk $SDK --show-sdk-path) $MIN -I$M -I$M/third_party -I$ROOT/native/sentencepiece/src $f -o $B/mfa-obj/$(basename $f | sed 's/\.[a-z]*$//').o
done
rm -f $B/libvoxsum-mfa.a; xcrun libtool -static -o $B/libvoxsum-mfa.a $B/mfa-obj/*.o
echo "built $B/libvoxsum-mfa.a"
