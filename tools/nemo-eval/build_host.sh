#!/usr/bin/env bash
# Build nemo_eval on the host from the same submodules and the same vendored engine the app ships.
#   tools/nemo-eval/build_host.sh            -> tools/nemo-eval/build/nemo_eval
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
N=$ROOT/native; E=$ROOT/app/src/main/cpp/nemo; B=$ROOT/tools/nemo-eval/build
J=${JOBS:-$(nproc)}
mkdir -p "$B"
cmake -S "$N/audiocpp" -B "$B/audiocpp" -DCMAKE_BUILD_TYPE=Release -DAUDIOCPP_BUILD_C_API=ON \
  -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=nemotron_3_diar >/dev/null
cmake --build "$B/audiocpp" --target audiocpp -j"$J" >/dev/null
cmake -S "$N/crispasr" -B "$B/crispasr" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_PROJECT_crispasr_INCLUDE="$E/crispasr_ggml.cmake" -DNEMO_GGML_SRC="$N/crispasr-ggml" \
  -DCMAKE_CXX_FLAGS="-I$N/crispasr-ggml/src" -DGGML_LLAMAFILE=ON -DCRISPASR_NO_C2PA_NATIVE=ON \
  -DCRISPASR_BUILD_EXAMPLES=OFF -DCRISPASR_BUILD_TESTS=OFF -DCRISPASR_BUILD_SERVER=OFF >/dev/null
cmake --build "$B/crispasr" --target xasr crispasr-core ggml ggml-base ggml-cpu -j"$J" >/dev/null
C=$B/crispasr
g++ -O2 -std=c++17 -w -DNEMO_HAVE_TOKEN_TIMES -I"$E" -I"$N/crispasr/src" -I"$N/audiocpp/include" \
  -I"$N/crispasr-ggml/include" -I"$N/crispasr-ggml/src" -I"$N/crispasr-ggml/src/ggml-cpu" \
  "$E"/engine.cpp "$E"/fusion.cpp "$E"/diar_crispasr.cpp "$ROOT/tools/nemo-eval/nemo_eval.cpp" \
  -o "$B/nemo_eval" -L"$B/audiocpp/bin" -l:libaudiocpp.so \
  "$C/src/libxasr.a" "$C/src/libcrispasr-core.a" "$C/ggml/src/libggml.a" "$C/ggml/src/libggml-cpu.a" \
  "$C/ggml/src/libggml-base.a" -fopenmp -lpthread -ldl -lm -Wl,-rpath,"$B/audiocpp/bin"
echo "built $B/nemo_eval"
