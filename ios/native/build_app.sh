#!/bin/bash
# VoxSum.app for the iOS simulator without an Xcode project (swiftc + hand-made bundle).
# DEV=1 keeps the VOX_* test hooks and the Sample button (off in release builds).
#   build_app.sh [iphonesimulator x86_64]   after build_ios.sh + build_nemo_lib.sh
set -e
SDK=${1:-iphonesimulator}; ARCH=${2:-x86_64}
ROOT=$(cd "$(dirname "$0")/../.." && pwd); B=$ROOT/build-ios/$SDK-$ARCH; C=$B/crispasr; A=$ROOT/ios/App
APP=$B/VoxSum.app; rm -rf $APP; mkdir -p $APP/Frameworks
T=$ARCH-apple-ios17.0$(if [ $SDK = iphonesimulator ]; then echo -simulator; fi)
MFA=; FW=$HOME/work/cl/CLiteRTLM.xcframework/ios-arm64
LRT=$HOME/work/litert-build/out-lib/libLiteRt.so   # x86_64 simulator LiteRT, see native/litert_x86_sim/
if [ $SDK = iphonesimulator ] && [ -f $LRT ]; then MFA="$B/libvoxsum-mfa.a $(find $B -name 'libsentencepiece*.a' | head -1) $LRT"; fi
# arm64 (device or Apple-silicon simulator): CLiteRTLM.xcframework slice, stock LiteRT inside
if [ $ARCH = arm64 ]; then
  [ $SDK = iphonesimulator ] && FW=$HOME/work/cl/CLiteRTLM.xcframework/ios-arm64-simulator
  MFA="$B/libvoxsum-mfa.a $(find $B -name 'libsentencepiece*.a' | head -1) -F$FW -framework CLiteRTLM"
fi
xcrun --sdk $SDK swiftc -parse-as-library -O $([ -n "$MFA" ] && echo -DVOX_REAL_READER) $([ -n "$DEV" ] && echo -DVOX_DEV) -target $T -import-objc-header $A/Bridging.h -Xcc -I$ROOT/ios/native -Xcc -I$ROOT/ios/native/mfa \
  $A/App.swift $A/Engine.swift $A/Library.swift $A/AudioDecode.swift $A/AudioPrep.swift $A/LongUtteranceSplitter.swift $A/OpenCC.swift $A/Queue.swift $A/Podcast.swift $A/YouTube.swift $A/Export.swift $A/SessionView.swift $A/LibraryView.swift $A/CaptureView.swift $A/Settings.swift $A/Recorder.swift $A/ModelStore.swift $A/Reader/*.swift -o $APP/VoxSum \
  $B/libvoxsum-nemo.a $MFA $C/src/libxasr.a $C/src/libcrispasr-core.a $C/ggml/src/libggml.a $C/ggml/src/libggml-cpu.a $C/ggml/src/libggml-base.a \
  -L$B/audiocpp/bin -laudiocpp -lc++ -Xlinker -rpath -Xlinker @executable_path/Frameworks
cp -L $B/audiocpp/bin/libaudiocpp.0.dylib $APP/Frameworks/libaudiocpp.0.dylib
if [ $SDK = iphonesimulator ] && [ -f $LRT ]; then cp $LRT $APP/Frameworks/; fi
if [ $ARCH = arm64 ]; then cp -R $FW/CLiteRTLM.framework $APP/Frameworks/; fi
cp $A/Info.plist $A/Resources/sample.wav $APP/
cp -R $A/Resources/opencc $A/Resources/en.lproj $A/Resources/zh-Hant.lproj $A/Resources/zh-Hans.lproj $APP/
/usr/libexec/PlistBuddy -c "Add :UIDeviceFamily array" -c "Add :UIDeviceFamily:0 integer 1" $APP/Info.plist
codesign -f -s - $APP/Frameworks/*.dylib $APP/Frameworks/*.framework $APP 2>/dev/null || codesign -f -s - $APP/Frameworks/*.dylib $APP   # the simulator refuses unsigned bundles
echo "built $APP"
