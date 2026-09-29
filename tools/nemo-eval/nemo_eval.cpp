// nemo_eval - host driver for the streaming engine exactly as the app uses it: a 16 kHz WAV pushed in
// 2048-sample blocks (the recorder's block size) through Engine::push, then finish(). Writes the final
// segments as JSON [{spk,start,end,text}] (the ~/voxsum-public-eval score.py hypothesis format),
// and the diarizer's own turns beside it as <out>.turns.json.
//
//   nemo_eval <xasr.gguf> <diar.gguf> <in.wav> <out.json> [threads]
#include <cstdio>
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
    cfg.threads = argc > 5 ? std::atoi(argv[5]) : 2;
    nemo::Wav wav;
    std::string err;
    if (!nemo::Wav::load(argv[3], wav, err)) { std::fprintf(stderr, "%s\n", err.c_str()); return 1; }
    if (wav.rate != 16000) wav.to_16k();
    nemo::Engine eng(cfg);
    if (!eng.init(err)) { std::fprintf(stderr, "init: %s\n", err.c_str()); return 1; }
    eng.begin();
    for (size_t off = 0; off < wav.pcm.size(); off += 2048)
        if (!eng.push(wav.pcm.data() + off, std::min<size_t>(2048, wav.pcm.size() - off), err)) {
            std::fprintf(stderr, "push: %s\n", err.c_str()); return 1; }
    FILE* f = std::fopen(argv[4], "w");
    std::fprintf(f, "[");
    bool first = true;
    if (!eng.finish([&](const nemo::Segment& s) {
            std::fprintf(f, "%s\n{\"spk\":%d,\"start\":%.3f,\"end\":%.3f,\"text\":\"%s\"}", first ? "" : ",",
                         s.speaker, s.start_s, s.end_s, esc(s.text).c_str());
            first = false;
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
    const auto& st = eng.stats();
    std::fprintf(stderr, "[stats] audio %.1fs wall %.1fs rtf %.3f speakers %zu turns %zu rss %.0fMB first_turn %.1fs\n",
                 st.audio_s, st.wall_s, st.wall_s / st.audio_s, st.speakers, st.turns, st.peak_rss_mb,
                 st.first_turn_audio_s);
    return 0;
}
