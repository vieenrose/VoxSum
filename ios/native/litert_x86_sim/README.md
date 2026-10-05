# libLiteRt.so for the Intel iOS simulator

Google ships LiteRT only as arm64 for iOS, so the Intel simulator cannot load the real reader. This builds
`libLiteRt.so` (target `//litert/c:litert_runtime_c_api_so`, the same one as Android's AAR) for `ios_x86_64`:

    git clone --depth 1 --branch v2.1.6 https://github.com/google-ai-edge/LiteRT.git ~/work/litert-build/LiteRT
    cd ~/work/litert-build/LiteRT && git apply <this dir>/litert-v2.1.6-ios-x86_64-sim.patch
    ~/work/litert-build/run.sh        # needs ~/tools/bazelisk; ~25 min, ~4.5 GB; result: ~/work/litert-build/out-lib/libLiteRt.so

The patch only fixes the iOS link (install_name instead of -soname, Metal/Foundation frameworks, a no-op
signpost profiler). `build_app.sh` links it automatically when present and defines `VOX_REAL_READER`.
