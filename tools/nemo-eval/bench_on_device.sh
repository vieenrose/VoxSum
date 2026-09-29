#!/usr/bin/env bash
# Phone RTF of the ASR + diarization engine for each diarizer latency geometry (the points of the
# accuracy-vs-latency curve in README.md). Uses the app's own arm64 native build (ARMv8.0 floor), so
# the numbers are what the app gets.
#
#   ./gradlew :app:externalNativeBuildRelease          # once, builds the arm64 libraries
#   tools/nemo-eval/bench_on_device.sh <serial> <x-asr.gguf> <nemotron.gguf> <clip.wav> [threads]
#
# Prints one line per geometry: "geometry rtf <x>". Speaker delay (display) does not change compute,
# so one run per geometry covers every point on its curve.
set -euo pipefail
SERIAL=$1; XASR=$2; DIAR=$3; CLIP=$4; THREADS=${5:-4}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
NDK=${ANDROID_NDK:-$HOME/Android/Sdk/ndk/27.2.12479018}
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
ADB=${ADB:-adb}
B=$(ls -d "$ROOT"/app/.cxx/Release/*/arm64-v8a | head -1)
C=$B/crispasr-build; N=$ROOT/native; E=$ROOT/app/src/main/cpp/nemo
OUT=$ROOT/tools/nemo-eval/build-android; mkdir -p "$OUT"

"$TC/bin/clang++" --target=aarch64-linux-android26 -O2 -std=c++17 -w -DNEMO_HAVE_TOKEN_TIMES \
  -I"$E" -I"$N/crispasr/src" -I"$N/audiocpp/include" \
  -I"$N/crispasr-ggml/include" -I"$N/crispasr-ggml/src" -I"$N/crispasr-ggml/src/ggml-cpu" \
  "$E"/engine.cpp "$E"/fusion.cpp "$E"/diar_crispasr.cpp "$ROOT/tools/nemo-eval/nemo_eval.cpp" \
  -o "$OUT/nemo_eval" -L"$B/audiocpp-build/bin" -l:libaudiocpp.so \
  "$C/src/libxasr.a" "$C/src/libcrispasr-core.a" "$C/ggml/src/libggml.a" "$C/ggml/src/libggml-cpu.a" \
  "$C/ggml/src/libggml-base.a" -fopenmp -static-openmp -Wl,-rpath,'$ORIGIN' -llog -ldl -lm

D=/data/local/tmp/nemo-bench
"$ADB" -s "$SERIAL" shell mkdir -p $D
"$ADB" -s "$SERIAL" push "$OUT/nemo_eval" "$B/audiocpp-build/bin/libaudiocpp.so" \
  "$TC/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" $D/ >/dev/null
for f in "$XASR" "$DIAR" "$CLIP"; do
  "$ADB" -s "$SERIAL" shell "[ -f $D/$(basename "$f") ]" || "$ADB" -s "$SERIAL" push "$f" $D/ >/dev/null
done

geo() { case $1 in
  low)  echo "--diar-opt nemotron_3_diar.latency_profile=low";;
  c12)  echo "--diar-opt nemotron_3_diar.chunk_len=12 --diar-opt nemotron_3_diar.chunk_right_context=4";;
  c25)  echo "--diar-opt nemotron_3_diar.chunk_len=25 --diar-opt nemotron_3_diar.chunk_right_context=4";;
  c50)  echo "";;   # the app's shipped geometry
  c100) echo "--diar-opt nemotron_3_diar.chunk_len=100 --diar-opt nemotron_3_diar.chunk_right_context=12";;
  c200) echo "--diar-opt nemotron_3_diar.chunk_len=200 --diar-opt nemotron_3_diar.chunk_right_context=20";;
  c340) echo "--diar-opt nemotron_3_diar.chunk_len=340 --diar-opt nemotron_3_diar.chunk_right_context=40";;
esac; }
for g in low c12 c25 c50 c100 c200 c340; do
  line=$("$ADB" -s "$SERIAL" shell "cd $D && LD_LIBRARY_PATH=. ./nemo_eval $(basename "$XASR") $(basename "$DIAR") \
      $(basename "$CLIP") out.json $THREADS --max-seg 10 $(geo $g) 2>&1" | tr -d '\r' | grep '^\[stats\]' || true)
  echo "$g $(echo "$line" | grep -o 'rtf [0-9.]*' || echo 'rtf FAILED')"
done
