// fusion.cpp - see fusion.h. Written for this repo.
#include "fusion.h"

#include <algorithm>
#include <cmath>
#include <map>

namespace nemo {

std::vector<std::pair<size_t, size_t>> codepoints(const std::string& s) {
    std::vector<std::pair<size_t, size_t>> out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size();) {
        const unsigned char c = (unsigned char)s[i];
        size_t len = 1;
        if (c >= 0xF0) len = 4;
        else if (c >= 0xE0) len = 3;
        else if (c >= 0xC0) len = 2;
        if (i + len > s.size()) len = 1;      // truncated tail: treat as one unit, never drop bytes
        out.emplace_back(i, len);
        i += len;
    }
    return out;
}

namespace {

// Does this codepoint sit inside a word? Latin and digits only: Chinese has no word boundaries to keep,
// and treating a CJK character as its own unit is what a human annotator does too.
bool word_char(const std::string& s, size_t off, size_t len) {
    if (len != 1) return false;
    const char c = s[off];
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '\'';
}

// Turn the per-character verdicts into pieces. Where words exist, the WORD is the unit of attribution:
// a boundary that would fall inside a word moves to the word's majority speaker instead.
//
// This is not cosmetic. Attribute at character granularity and a boundary that lands mid-word prints as
// "...subsequently dro" / "f" - the scorer then reads two tokens where the reference has one, and a pure
// placement error shows up as WER: the same audio scored 0.1765 with clean cuts and 0.3176 with cuts
// through words, with an identical transcript either way. Attribution accuracy barely moved between those
// two runs, which is how we know the damage was in the cut, not in the speaker choice.
std::vector<TaggedPiece> tag_sequence(const std::string& text, const std::vector<const Turn*>& mark,
                                      const std::vector<char>& snapped) {
    const auto cps = codepoints(text);
    std::vector<TaggedPiece> pieces;
    if (cps.empty()) return pieces;

    for (size_t i = 0; i < cps.size();) {
        size_t j = i + 1;
        if (word_char(text, cps[i].first, cps[i].second)) {
            while (j < cps.size() && word_char(text, cps[j].first, cps[j].second)) j++;
        }
        // majority over the word's characters; a tie keeps the first character's verdict
        std::map<std::pair<std::string, bool>, int> votes;
        for (size_t k = i; k < j; k++) {
            const std::string spk = mark[k] ? mark[k]->speaker : std::string();
            votes[{spk, snapped[k] && mark[k] != nullptr}]++;
        }
        auto best = votes.begin();
        for (auto it = votes.begin(); it != votes.end(); ++it) {
            if (it->second > best->second) best = it;
        }
        const std::string spk = best->first.first;
        const bool snap = best->first.second;

        if (!pieces.empty() && pieces.back().speaker == spk && pieces.back().snapped == snap) {
            TaggedPiece& p = pieces.back();
            for (size_t k = i; k < j; k++) p.text.append(text, cps[k].first, cps[k].second);
            for (size_t k = i; k < j; k++) {
                if (mark[k]) p.min_confidence = std::min(p.min_confidence, mark[k]->confidence);
            }
        } else {
            TaggedPiece p;
            p.speaker = spk;
            p.snapped = snap;
            p.min_confidence = 1.0f;
            for (size_t k = i; k < j; k++) {
                p.text.append(text, cps[k].first, cps[k].second);
                if (mark[k]) p.min_confidence = std::min(p.min_confidence, mark[k]->confidence);
            }
            pieces.push_back(std::move(p));
        }
        i = j;
    }
    return pieces;
}

}  // namespace

void Fusion::update_turns(const std::vector<Turn>& snapshot) {
    // Match tolerance: two diar frames. A streaming turn is re-stated with the same start and a
    // later end; anything else (a new turn, a re-segmentation) is a new interval.
    const int64_t tol = rate_ / 100;
    for (const Turn& t : snapshot) {
        auto it = std::find_if(turns_.begin(), turns_.end(),
                               [&](const Turn& e) { return std::abs(e.start - t.start) <= tol; });
        if (it == turns_.end()) {
            turns_.push_back(t);
        } else {
            it->end = std::max(it->end, t.end);
            it->confidence = t.confidence;
            if (!t.speaker.empty()) it->speaker = t.speaker;
        }
    }
    std::sort(turns_.begin(), turns_.end(), [](const Turn& a, const Turn& b) { return a.start < b.start; });
}

const Turn* Fusion::covering(int64_t t, int64_t dur, bool* snapped) const {
    if (snapped) *snapped = false;
#ifdef NEMO_PLANT_FAULT
    // Test-fault hook: proves tests/selftest.sh can tell a working attributor from one that always
    // answers with the first turn. Compiled only with -DNEMO_PLANT_FAULT; the self-test asserts that
    // this build FAILS, so an assertion that never fires cannot pass as coverage.
    return turns_.empty() ? nullptr : &turns_.front();
#endif
    const Turn* best = nullptr;
    int64_t best_ov = 0;
    for (const Turn& e : turns_) {
        const int64_t lo = std::max<int64_t>(e.start, t);
        const int64_t hi = std::min<int64_t>(e.end, t + dur);
        const int64_t ov = hi - lo;
        if (ov > best_ov) { best_ov = ov; best = &e; }
    }
    if (best) return best;

    // No overlap: inside a between-turns gap. Snap to the nearer end of the closest turn rather than
    // inventing an unattributed island, but only for gaps short enough that a word really could not
    // have been spoken there.
    if (gap_fill_ == GapFill::PREVIOUS) {
        // The last turn that had ended by now; if the audio precedes every turn, the first one after it.
        const Turn* prev = nullptr;
        for (const Turn& e : turns_) {
            if (e.end <= t + dur && (!prev || e.end > prev->end)) prev = &e;
        }
        if (prev) { if (snapped) *snapped = true; return prev; }
        for (const Turn& e : turns_) if (!prev || e.start < prev->start) prev = &e;
        if (prev) { if (snapped) *snapped = true; return prev; }
        return nullptr;
    }
    const bool infinite = gap_snap_s_ <= 0.0;      // 0 = always nearest, never leave text untagged
    const int64_t snap = infinite ? (int64_t)1e18 : (int64_t)(gap_snap_s_ * rate_);
    int64_t best_d = snap + 1;
    for (const Turn& e : turns_) {
        const int64_t d = std::min(std::abs(t - e.end), std::abs(e.start - (t + dur)));
        if (d < best_d) { best_d = d; best = &e; }
    }
    if (best_d <= snap && best) { if (snapped) *snapped = true; return best; }
    return nullptr;
}

// Right-align a delta's characters inside the audio it describes, and append them to the timeline.
// A delta arrives when words CAME OUT, so its span also contains the silence that preceded them;
// spreading characters across the whole span would put the first characters of every turn in that
// silence, which is the single easiest way to mis-tag a speaker change.
void Fusion::push_delta(const std::string& delta, int64_t span_start, int64_t span_end) {
    append_placed(delta, span_start, span_end, false);
}

void Fusion::push_token(const std::string& text, int64_t at, int64_t end) {
    append_placed(text, at, end, true);
}

void Fusion::append_placed(const std::string& text, int64_t span_start, int64_t span_end, bool exact) {
    const auto cps = codepoints(text);
    if (cps.empty()) return;
    if (span_end <= span_start) span_end = span_start + 1;
    // exact: the token fills its interval. inferred: right-align `n * char_dur` inside the interval.
    const int64_t est = exact ? (span_end - span_start)
                              : std::min<int64_t>(span_end - span_start,
                                                  (int64_t)(cps.size() * char_dur_s_ * rate_));
    const int64_t base = span_end - est;
    const double step = double(est) / double(cps.size());
    for (size_t i = 0; i < cps.size(); i++) {
        const int64_t at = base + (int64_t)std::llround(i * step);
        const int64_t dur = std::max<int64_t>(1, (int64_t)std::llround(step));
        text_.append(text, cps[i].first, cps[i].second);
        spans_.push_back(CharSpan{at, at + dur});
    }
}

std::vector<TaggedPiece> Fusion::attribute_all() const {
    const auto cps = codepoints(text_);
    std::vector<const Turn*> mark(cps.size(), nullptr);
    std::vector<char> snap(cps.size(), 0);      // vector<bool> has no addressable elements
    for (size_t i = 0; i < cps.size() && i < spans_.size(); i++) {
        bool sn = false;
        mark[i] = covering(spans_[i].start, spans_[i].end - spans_[i].start, &sn);
        snap[i] = sn ? 1 : 0;
    }
    auto pieces = tag_sequence(text_, mark, snap);
    // Recover the time range each piece covers from the character spans (tag_sequence groups by word,
    // so times cannot travel with the text there).
    size_t pos = 0;
    for (auto& p : pieces) {
        const size_t n = codepoints(p.text).size();
        if (pos < spans_.size()) p.start_s = double(spans_[pos].start) / rate_;
        for (size_t k = pos; k < pos + n && k < spans_.size(); k++) {
            p.end_s = std::max(p.end_s, double(spans_[k].end) / rate_);
        }
        pos += n;
    }
    return pieces;
}

std::vector<TaggedPiece> Fusion::on_delta(const std::string& delta, int64_t span_start, int64_t span_end) {
    Fusion tmp(*this);
    tmp.push_delta(delta, span_start, span_end);
    return tmp.attribute_all();
}

}  // namespace nemo
