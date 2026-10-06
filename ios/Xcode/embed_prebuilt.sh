#!/bin/bash
# Run-script phase of the VoxSum Xcode target: (re)builds the native bundle with build_app.sh
# (swiftc + prebuilt static libs, see ../native) and copies it into the Xcode product, which
# Xcode then signs with the team chosen in Signing & Capabilities.
set -euo pipefail
ROOT="$(cd "$SRCROOT/../.." && pwd)"
case "$PLATFORM_NAME" in
  iphoneos) SDK=iphoneos; ARCH=arm64 ;;
  *) SDK=iphonesimulator; ARCH=${NATIVE_ARCH_ACTUAL:-x86_64} ;;
esac
[ "${SKIP_NATIVE_BUILD:-0}" = 1 ] || bash "$ROOT/ios/native/build_app.sh" "$SDK" "$ARCH"
SRC="$HOME/work/vox/build-ios/$SDK-$ARCH/VoxSum.app"
[ -d "$SRC" ] || { echo "error: $SRC missing (run build_app.sh)"; exit 1; }
DST="$TARGET_BUILD_DIR/$WRAPPER_NAME"
cp -f "$SRC/VoxSum" "$DST/VoxSum"
for r in "$SRC"/*; do case "$(basename "$r")" in VoxSum|Frameworks|Info.plist|_CodeSignature) ;; *) rm -rf "$DST/$(basename "$r")"; cp -R "$r" "$DST/";; esac; done   # opencc, *.lproj, sample.wav
rm -rf "$DST/Frameworks"; mkdir -p "$DST/Frameworks"
[ -d "$SRC/Frameworks" ] && cp -R "$SRC/Frameworks/." "$DST/Frameworks/"
if [ "${CODE_SIGNING_ALLOWED:-YES}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  for f in "$DST"/Frameworks/*; do
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$f"
  done
fi
