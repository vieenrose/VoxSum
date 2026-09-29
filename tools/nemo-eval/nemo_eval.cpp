// nemo_eval - host driver for the streaming engine exactly as the app uses it: a 16 kHz WAV pushed in
// 2048-sample blocks (the recorder's block size) through Engine::push, then finish(). Writes the final
// segments as JSON [{spk,start,end,text}] (the ~/voxsum-public-eval score.py hypothesis format),
// and the diarizer's own turns beside it as <out>.turns.json.
//
//   nemo_eval <xasr.gguf> <diar.gguf> <in.wav> <out.json> [threads] [--max-seg S] [--live]
//             [--settle S] [--timing 0|1|2]
//
// --max-seg S  split single-speaker runs after a sentence end at S seconds (the app uses 10).
// --live       also call Engine::live() every 0.5 s of audio, as the app does while recording, and
//              report its per-call cost, that frozen + tail always reproduces the transcript, and how
//              much of the frozen (live) speaker labelling the final pass agrees with.
// --settle S   live-view speaker delay (Config::live_settle_s; the app's setting, default 15).
// --timing N   final-pass character timeline: 0 auto (model token times), 2 inferred placement.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <vector>
#include <map>
#include <string>
#include "engine.h"
#include "wav.h"

static std::string esc(const std::string& s) {
    std::string o;
    for (char c : s) { if (c == '"' || c == '\\') o += '\\'; if (c == '\n') { o += "\\n"; continue; } o += c; }
    return o;
}

int main(int argc, char** argv) {
    if (argc < 5) { std::fprintf(stderr, "usage: nemo_eval xasr.gguf diar.gguf in.wav out.json [threads]\n"); return 2; }
    nemo::Config cfg;
    cfg.xasr_model = argv[1];
    cfg.diar_model = argv[2];
    cfg.threads = (argc > 5 && argv[5][0] != '-') ? std::atoi(argv[5]) : 2;
    bool live = false;
    for (int i = 5; i < argc; i++) {
        if (!std::strcmp(argv[i], "--live")) live = true;
        else if (!std::strcmp(argv[i], "--max-seg") && i + 1 < argc) cfg.max_segment_s = std::atof(argv[++i]);
        else if (!std::strcmp(argv[i], "--settle") && i + 1 < argc) cfg.live_settle_s = std::atof(argv[++i]);
        else if (!std::strcmp(argv[i], "--timing") && i + 1 < argc) cfg.timing = std::atoi(argv[++i]);
    }
    nemo::Wav wav;
    std::string err;
    if (!nemo::Wav::load(argv[3], wav, err)) { std::fprintf(stderr, "%s\n", err.c_str()); return 1; }
    if (wav.rate != 16000) wav.to_16k();
    nemo::Engine eng(cfg);
    if (!eng.init(err)) { std::fprintf(stderr, "init: %s\n", err.c_str()); return 1; }
    eng.begin();
    std::vector<nemo::Segment> frozen;          // everything the live view froze, in order
    std::vector<double> live_ms;
    size_t mismatches = 0;
    double next_live = 0.5;
    for (size_t off = 0; off < wav.pcm.size(); off += 2048) {
        if (!eng.push(wav.pcm.data() + off, std::min<size_t>(2048, wav.pcm.size() - off), err)) {
            std::fprintf(stderr, "push: %s\n", err.c_str()); return 1; }
        if (live && eng.fed_s() >= next_live) {
            next_live = eng.fed_s() + 0.5;
            std::vector<nemo::Segment> nf, tail;
            const auto t0 = std::chrono::steady_clock::now();
            eng.live(nf, tail);
            live_ms.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
            frozen.insert(frozen.end(), nf.begin(), nf.end());
            std::string all;
            for (const auto& s : frozen) all += s.text;
            for (const auto& s : tail) all += s.text;
            if (all != eng.transcript()) mismatches++;
        }
    }
    std::vector<nemo::Segment> finals;
    FILE* f = std::fopen(argv[4], "w");
    std::fprintf(f, "[");
    bool first = true;
    if (!eng.finish([&](const nemo::Segment& s) {
            std::fprintf(f, "%s\n{\"spk\":%d,\"start\":%.3f,\"end\":%.3f,\"text\":\"%s\"}", first ? "" : ",",
                         s.speaker, s.start_s, s.end_s, esc(s.text).c_str());
            first = false;
            finals.push_back(s);
        }, err)) { std::fprintf(stderr, "finish: %s\n", err.c_str()); return 1; }
    std::fprintf(f, "\n]\n");
    std::fclose(f);
    // The diarizer's own speech turns (<out>.turns.json): what DER should be scored on, since text
    // segments run across the pauses between words.
    std::map<std::string, int> ids;
    const std::string out = argv[4];
    FILE* g = std::fopen((out.substr(0, out.size() - 5) + ".turns.json").c_str(), "w");
    std::fprintf(g, "[");
    first = true;
    for (const auto& t : eng.turns()) {
        auto it = ids.emplace(t.speaker, (int)ids.size()).first;
        std::fprintf(g, "%s\n{\"spk\":%d,\"start\":%.3f,\"end\":%.3f}", first ? "" : ",", it->second,
                     t.start / 16000.0, t.end / 16000.0);
        first = false;
    }
    std::fprintf(g, "\n]\n");
    std::fclose(g);
    if (live && !live_ms.empty()) {
        std::vector<double> sorted = live_ms;
        std::sort(sorted.begin(), sorted.end());
        // Time-weighted share of the frozen live labelling the final pass agrees with (speaker ids are
        // shared between the two, so no mapping is needed).
        double agree = 0, total = 0;
        for (const auto& a : frozen) {
            if (a.speaker < 0) continue;
            for (const auto& b : finals) {
                const double ov = std::min(a.end_s, b.end_s) - std::max(a.start_s, b.start_s);
                if (ov <= 0) continue;
                total += ov;
                if (b.speaker == a.speaker) agree += ov;
            }
        }
        const size_t q = live_ms.size() / 4;
        double early = 0, late = 0;
        for (size_t i = 0; i < q; i++) { early += live_ms[i]; late += live_ms[live_ms.size() - 1 - i]; }
        std::fprintf(stderr, "[live] calls %zu p50 %.2fms p95 %.2fms max %.2fms first-quarter avg %.2fms "
                             "last-quarter avg %.2fms | frozen %zu segs, text mismatches %zu, "
                             "final agrees with live on %.1f%% of frozen time\n",
                     live_ms.size(), sorted[sorted.size() / 2], sorted[size_t(0.95 * (sorted.size() - 1))],
                     sorted.back(), q ? early / q : 0.0, q ? late / q : 0.0, frozen.size(), mismatches,
                     total > 0 ? 100.0 * agree / total : 0.0);
    }
    const auto& st = eng.stats();
    std::fprintf(stderr, "[stats] audio %.1fs wall %.1fs rtf %.3f speakers %zu turns %zu rss %.0fMB first_turn %.1fs\n",
                 st.audio_s, st.wall_s, st.wall_s / st.audio_s, st.speakers, st.turns, st.peak_rss_mb,
                 st.first_turn_audio_s);
    return 0;
}
