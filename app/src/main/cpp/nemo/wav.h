// wav.h - minimal PCM reader. Written for this repo; no third-party code.
#pragma once
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace nemo {

struct Wav {
    std::vector<float> pcm;   // mono, converted to [-1, 1]
    int rate_orig = 0;        // file rate before any resampling to 16 kHz (0 = unchanged)
    int rate = 0;

    // Reads a canonical (RIFF/WAVE, PCM16) file. Streaming ASR does not care about the
    // metadata cruft most WAV readers exist to handle, so this deliberately fails loudly on
    // anything else rather than guessing: a silently mis-read sample rate is the one bug that
    // produces plausible-but-wrong transcripts, which is the failure mode this whole project
    // keeps running into.
    static bool load(const std::string& path, Wav& out, std::string& err) {
        FILE* f = std::fopen(path.c_str(), "rb");
        if (!f) { err = "cannot open " + path; return false; }
        char riff[4];
        if (std::fread(riff, 1, 4, f) != 4) { std::fclose(f); err = "empty file: " + path; return false; }
        if (std::memcmp(riff, "RIFF", 4)) { std::fclose(f); err = "not RIFF: " + path; return false; }
        std::fseek(f, 12, SEEK_SET);        // RIFF | size | WAVE | <- chunks start here; reading at 8
                                            // re-reads "WAVE" as a chunk id and walks off the rails
        uint16_t format = 0, channels = 0, bits = 0;
        uint32_t rate = 0, byte_rate = 0, block_align = 0;
        bool have_fmt = false, have_data = false;
        size_t data_len = 0, data_off = 0;
        for (;;) {
            char id[4];
            uint32_t sz = 0;
            if (std::fread(id, 1, 4, f) != 4) break;
            if (std::fread(&sz, 4, 1, f) != 1) break;
            const long body = std::ftell(f);      // start of this chunk's payload - the ONLY correct
                                                   // basis for the next offset; measuring after parsing
                                                   // a 16-byte fmt skips one chunk and lands mid-LIST
            if (!std::memcmp(id, "fmt ", 4)) {
                // field order is format, channels, rate, byte_rate, block_align, bits - read the
                // block once and slice it, so a short chunk cannot half-fill the fields and lie
                unsigned char fb[16] = {0};
                const size_t got = std::fread(fb, 1, sizeof(fb), f);
                if (got < 16) { std::fclose(f); err = "short fmt chunk"; return false; }
                std::memcpy(&format, fb + 0, 2); std::memcpy(&channels, fb + 2, 2);
                std::memcpy(&rate, fb + 4, 4);   std::memcpy(&byte_rate, fb + 8, 4);
                std::memcpy(&block_align, fb + 12, 2); std::memcpy(&bits, fb + 14, 2);
                have_fmt = true;
            } else if (!std::memcmp(id, "data", 4)) {
                data_off = std::ftell(f);
                data_len = sz;
                have_data = true;
            }
#ifdef NEMO_PLANT_FAULT_WAV
            // Test-fault hook: the original bug - measuring the next offset after reading the payload
            // instead of before, which skips a chunk and lands mid-LIST.
            const long next = std::ftell(f) + (long)((sz + 1u) & ~1u);
#else
            const long next = body + (long)((sz + 1u) & ~1u);   // chunks are word-aligned
#endif
            if (sz == 0 || std::fseek(f, next, SEEK_SET) != 0) break;   // sz==0 would spin forever
            if (have_data && have_fmt) break;
        }
        if (!have_fmt || !have_data) { std::fclose(f); err = "no fmt/data chunk"; return false; }
        if (format != 1 || bits != 16) { std::fclose(f); err = "need PCM16, got format=" + std::to_string(format) + " bits=" + std::to_string(bits); return false; }
        if (!channels) { std::fclose(f); err = "channels=0"; return false; }
        std::fseek(f, data_off, SEEK_SET);
        size_t frames = data_len / (channels * 2);
        std::vector<int16_t> raw(frames * channels);
        if (std::fread(raw.data(), 2, raw.size(), f) != raw.size()) {
            std::fclose(f); err = "truncated data chunk (asked " + std::to_string(raw.size()) + " samples)";
            return false;
        }
        std::fclose(f);
        out.pcm.resize(frames);
        for (size_t i = 0; i < frames; i++) {
            int32_t acc = 0;
            for (uint16_t c = 0; c < channels; c++) acc += raw[i * channels + c];
            out.pcm[i] = (float)(acc / (double)channels) / 32768.0f;   // mixdown, no rescale
        }
        out.rate = (int)rate;
        (void)byte_rate; (void)block_align;
        return true;
    }

    // Resample to 16 kHz in place. The streaming baseline consumes 24 kHz natively (its VAE runs at 24 kHz),
    // so refusing anything but 16 kHz made this a non-drop-in on its own protocol clip - every measurement
    // here had to be taken on a pre-converted copy. Lanczos3 is good enough for ASR front-ends and is ~40
    // lines; what matters is that the resampling is INSIDE the process, so no external step is required to
    // feed it the same files the baseline is fed. The original rate is kept in rate_orig and reported.
    void to_16k() {
        if (rate == 16000) return;
        const int T = 3;                                  // 3 lobes each side
        const double ratio = 16000.0 / (double)rate;
        const double cut = ratio < 1.0 ? ratio : 1.0;     // lowpass before decimation
        std::vector<float> out((size_t)(pcm.size() * ratio) + 1);
        auto lanczos = [](double u) {
            if (std::fabs(u) < 1e-9) return 1.0;
            if (std::fabs(u) >= 3.0) return 0.0;
            const double pi_u = M_PI * u;
            return (std::sin(pi_u) / pi_u) * (std::sin(pi_u / 3.0) / (pi_u / 3.0));
        };
        for (size_t i = 0; i < out.size(); i++) {
            const double pos = ((double)i + 0.5) / ratio - 0.5;
            const int c = (int)std::floor(pos);
            double acc = 0.0, wsum = 0.0;
            for (int k = -T * 2; k <= T * 2; k++) {       // 6 taps per input sample band
                const double x = pos - (double)(c + k);
                const double w = lanczos(x * cut);
                const size_t idx = (size_t)std::min<long>(std::max<long>(0, (long)(c + k)), (long)pcm.size() - 1);
                acc += w * pcm[idx];
                wsum += w;
            }
            out[i] = wsum != 0.0 ? (float)(acc / wsum) : 0.0f;
        }
        rate_orig = rate;
        pcm.swap(out);
        rate = 16000;
    }
};

}  // namespace nemo
