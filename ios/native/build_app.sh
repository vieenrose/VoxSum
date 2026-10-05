#!/bin/bash
# VoxSum.app for the iOS simulator without an Xcode project (swiftc + hand-made bundle).
#   build_app.sh [iphonesimulator x86_64]   after build_ios.sh + build_nemo_lib.sh
set -e
SDK=${1:-iphonesimulator}; ARCH=${2:-x86_64}
ROOT=$(cd "$(dirname "$0")/../.." && pwd); B=$ROOT/build-ios/$SDK-$ARCH; C=$B/crispasr; A=$ROOT/ios/App
APP=$B/VoxSum.app; rm -rf $APP; mkdir -p $APP/Frameworks
T=$ARCH-apple-ios17.0$(if [ $SDK = iphonesimulator ]; then echo -simulator; fi)
MFA=; FW=$HOME/work/cl/CLiteRTLM.xcframework/ios-arm64
if [ $SDK = iphoneos ]; then MFA="$B/libvoxsum-mfa.a $(find $B -name 'libsentencepiece*.a' | head -1) -F$FW -framework CLiteRTLM"; fi
xcrun --sdk $SDK swiftc -parse-as-library -O -target $T -import-objc-header $A/Bridging.h -Xcc -I$ROOT/ios/native -Xcc -I$ROOT/ios/native/mfa \
  $A/App.swift $A/Engine.swift $A/Library.swift $A/Recorder.swift $A/ModelStore.swift $A/Reader/*.swift -o $APP/VoxSum \
  $B/libvoxsum-nemo.a $MFA $C/src/libxasr.a $C/src/libcrispasr-core.a $C/ggml/src/libggml.a $C/ggml/src/libggml-cpu.a $C/ggml/src/libggml-base.a \
  -L$B/audiocpp/bin -laudiocpp -lc++ -Xlinker -rpath -Xlinker @executable_path/Frameworks
cp -L $B/audiocpp/bin/libaudiocpp.0.dylib $APP/Frameworks/libaudiocpp.0.dylib
if [ $SDK = iphoneos ]; then cp -R $FW/CLiteRTLM.framework $APP/Frameworks/; fi
cp $A/Info.plist $APP/
/usr/libexec/PlistBuddy -c "Add :UIDeviceFamily array" -c "Add :UIDeviceFamily:0 integer 1" $APP/Info.plist
codesign -f -s - $APP/Frameworks/*.dylib $APP/Frameworks/*.framework $APP 2>/dev/null || codesign -f -s - $APP/Frameworks/*.dylib $APP   # the simulator refuses unsigned bundles
echo "built $APP"
