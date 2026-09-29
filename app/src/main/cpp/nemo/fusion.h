// fusion.h - time-aligned speaker attribution: put the diarizer's turns onto the ASR's words.
//
// Written for this repo. The problem is specific to combining two streaming models whose output
// timelines do not line up:
//
//   * the ASR emits TEXT DELTAS at a wall-clock moment that lags the audio it decoded by roughly
//     one chunk (chunk_ms, plus whatever right context the encoder consumes);
//   * the diarizer emits TURN INTERVALS in audio time, refined as the stream advances.
//
// So a delta is not "at" a timestamp, it is a claim about an interval of audio. This file turns
// that claim into characters: the delta's codepoints are spread across the audio interval they
// describe, and each one is attributed to the turn overlapping it. Codepoints, not bytes - half of
// this model's output is Chinese, and byte-indexing would attribute a three-byte character to
// three different moments.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace nemo {

struct Turn {
    int64_t     start = 0, end = 0;   // samples, 16 kHz
    std::string speaker;
    float       confidence = 1.0f;
};

struct TaggedPiece {
    std::string speaker;              // "" = no turn covered this audio (silence/undetected)
    std::string text;
    double      start_s = 0, end_s = 0;
    float       min_confidence = 1.0f;
    bool        snapped = false;      // attributed by proximity, not by overlapping a turn. On the
                                      // bilingual gate set the diarizer MISSES ~41% of speech frames,
                                      // so a lot of fill is proximity; a score that ignores this flag
                                      // is measuring the fill rule, not the diarizer.
};

class Fusion {
public:
    // Per-codepoint audio interval, built by push_delta and consumed by attribute_all.
    struct CharSpan { int64_t start = 0, end = 0; };

    // asr_latency_s is the ASR's own lag: the delta returned after feeding audio up to T describes
    // audio up to T - asr_latency_s. Get this wrong in the optimistic direction and every speaker
    // tag shifts early into the previous speaker's turn.
    Fusion(int sample_rate, double asr_latency_s) : rate_(sample_rate), latency_s_(asr_latency_s) {}

    // A delta's characters are RIGHT-aligned inside its span and take char_dur_ms each. A delta only
    // arrives when the text changed, so its span also contains the silence that preceded the words;
    // spreading characters uniformly across that span puts the first characters of every turn in the
    // silence before it. Right-alignment says "these words just came out", which is what a delta is.
    void set_char_dur_ms(double ms) { char_dur_s_ = ms / 1000.0; }
    // Turns have real gaps at speaker changes (the pause while the next person starts). A character
    // estimated inside such a gap is not evidence of an anonymous third speaker: snap it to the
    // nearer turn when the gap is smaller than this, and only report "unattributed" beyond it.
    void set_gap_snap_ms(double ms) { gap_snap_s_ = ms / 1000.0; }
    // Which turn wins audio that no turn covers. NEAREST picks the closer boundary; PREVIOUS keeps the
    // speaker who was talking, which is the right guess when the hole is a MISSED region inside one
    // person's stretch - and on this material 41% of speech frames are missed, so that is the common case.
    enum class GapFill { NEAREST, PREVIOUS };
    void set_gap_fill(GapFill g) { gap_fill_ = g; }
    double char_dur_ms() const { return char_dur_s_ * 1000.0; }
    double gap_snap_ms() const { return gap_snap_s_ * 1000.0; }

    int rate() const { return rate_; }
    double latency_s() const { return latency_s_; }

    // Snapshot from the diarizer. Turns are matched by start sample and refined in place, because
    // a streaming diarizer re-states a turn with a later end sample as the speaker keeps talking.
    void update_turns(const std::vector<Turn>& snapshot);

    // Attribute `delta` to the audio interval [span_start, span_end). Returns the pieces in order;
    // a piece boundary means a speaker change (or entering/leaving uncovered audio).
    std::vector<TaggedPiece> on_delta(const std::string& delta, int64_t span_start, int64_t span_end);

    // The streaming path. Deltas are appended to an internal character timeline with their intervals,
    // and attribution runs over the WHOLE timeline, so a word that arrives split across two deltas is
    // still attributed as one word.
    void push_delta(const std::string& delta, int64_t span_start, int64_t span_end);

    // Exact-timing path: the model told us this token starts at `at` and the next token starts at `end`.
    // No inference, no char-duration guess, no right-alignment - this is the path that makes
    // --char-dur-ms and --asr-latency-ms irrelevant, which is how we verify they were the only guesses
    // in the attribution chain.
    void push_token(const std::string& text, int64_t at, int64_t end);

    // Keep the turn timeline, drop the text and its spans. Needed because token times are queried as a
    // whole-timeline snapshot, so each attribution pass rebuilds the character timeline from tokens.
    void clear_text() { text_.clear(); spans_.clear(); }
    std::vector<TaggedPiece> attribute_all() const;
    size_t chars() const { return spans_.size(); }
    const std::string& text() const { return text_; }
    const std::vector<CharSpan>& spans() const { return spans_; }

    const std::vector<Turn>& turns() const { return turns_; }

    // Speaker label covering [t, t+dur) by maximum overlap; else the nearest turn within the snap
    // tolerance; else nullptr. *snapped reports which of the two happened.
    const Turn* covering(int64_t t, int64_t dur, bool* snapped = nullptr) const;

private:
    void append_placed(const std::string& text, int64_t span_start, int64_t span_end, bool exact);

    int rate_;
    double latency_s_;
    std::string text_;
    std::vector<CharSpan> spans_;
    double char_dur_s_ = 0.09;     // ~11 chars/s, between Mandarin (~5/s) and English (~15/s) speech rates
    double gap_snap_s_ = 0.40;
    GapFill gap_fill_ = GapFill::NEAREST;     // turn gaps in the bilingual gate set run 0.05-0.30 s
    std::vector<Turn> turns_;
};

// UTF-8 codepoint spans (offset, length) - the attribution unit.
std::vector<std::pair<size_t, size_t>> codepoints(const std::string& s);

}  // namespace nemo
