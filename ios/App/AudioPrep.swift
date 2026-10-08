import Foundation

/// Streaming automatic input gain for imported audio (port of the Android GainNormalizer).
/// Far-field recordings can sit 20+ dB under normal speech, where the VAD barely fires. This estimates the speech
/// level (95th-percentile RMS of 100 ms frames above the silence floor) from the lead of the stream and applies ONE
/// constant gain: 1 unless the level is below -27 dBFS, then up to -20 dBFS capped so the 99.9th-percentile
/// amplitude stays under -2 dBFS. The decision fires after ~10 s of audible frames (or 180 s / end of stream);
/// samples are buffered until then so the whole stream carries one consistent gain.
final class GainNormalizer {
    static let frame = 1600, minVoiced = 100, maxLead = 180 * 16000
    static let target: Float = 0.1, gate: Float = 0.045, silence: Float = 0.001, ceiling: Float = 0.79
    private(set) var gain: Float = 1
    private var decided = false
    private var lead: [Float] = []
    private var frameRms: [Float] = []
    private var voiced = 0, inFrame = 0
    private var sumSq = 0.0

    func add(_ chunk: [Float]) -> [Float] {
        if decided { return scaled(chunk) }
        var out: [Float] = []
        for v in chunk {
            if decided { out.append(clamp(v * gain)); continue }
            if lead.count >= Self.maxLead { out += decideAndFlush(); out.append(clamp(v * gain)); continue }
            lead.append(v); sumSq += Double(v) * Double(v); inFrame += 1
            if inFrame == Self.frame { pushFrame(); if voiced >= Self.minVoiced { out += decideAndFlush() } }
        }
        return out
    }

    func finish() -> [Float] {
        guard !decided else { return [] }
        if inFrame >= Self.frame / 4 { pushFrame() }
        return decideAndFlush()
    }

    private func clamp(_ v: Float) -> Float { min(1, max(-1, v)) }
    private func scaled(_ c: [Float]) -> [Float] { gain == 1 ? c : c.map { clamp($0 * gain) } }
    private func pushFrame() {
        let r = Float((sumSq / Double(inFrame)).squareRoot())
        frameRms.append(r); if r > Self.silence { voiced += 1 }
        sumSq = 0; inFrame = 0
    }
    private func decideAndFlush() -> [Float] {
        decided = true
        gain = decide()
        let buf = lead; lead = []
        return scaled(buf)
    }
    private func decide() -> Float {
        guard !lead.isEmpty else { return 1 }
        var v = frameRms.filter { $0 > Self.silence }
        if v.isEmpty { v = frameRms.filter { $0 > Self.silence / 5 }; if v.isEmpty { return 1 } }   // ultra-quiet rigs
        v.sort()
        let level = v[min(max((v.count * 95 + 99) / 100 - 1, 0), v.count - 1)]
        if level >= Self.gate { return 1 }
        let abs = lead.map { Swift.abs($0) }.sorted()
        let peak = abs[(abs.count - 1) * 999 / 1000]
        if peak <= 0 { return 1 }
        return max(1, min(Self.target / level, Self.ceiling / peak))
    }
}

/// Shortens long silences before a file reaches the engine (port of the Android SilenceSkipper): each pause keeps its
/// first 8 s (the engine needs them to close a turn), the rest is not fed. `toOriginal` maps a time in the fed
/// stream back to the original audio so timestamps stay tap-to-play. Only quiet chunks (peak < 0.01) are skipped.
final class SilenceSkipper: @unchecked Sendable {
    private let rate = 16000, keep = 8 * 16000, threshold: Float = 0.01
    private var cuts: [(at: Double, total: Double)] = []
    private var fed = 0, silentRun = 0, skipped = 0, cutOpen = false
    private let lock = NSLock()

    /// nil when the chunk is skipped.
    func apply(_ c: [Float]) -> [Float]? {
        var peak: Float = 0
        for v in c { peak = max(peak, Swift.abs(v)) }
        if peak < threshold {
            silentRun += c.count
            if silentRun > keep {
                skipped += c.count
                let at = Double(fed) / Double(rate), tot = Double(skipped) / Double(rate)
                lock.lock(); if cutOpen { cuts[cuts.count - 1] = (at, tot) } else { cuts.append((at, tot)); cutOpen = true }; lock.unlock()
                return nil
            }
        } else { silentRun = 0; cutOpen = false }
        fed += c.count
        return c
    }

    func toOriginal(_ fedSec: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        var add = 0.0
        for c in cuts { if c.at <= fedSec + 1e-6 { add = c.total } else { break } }
        return fedSec + add
    }

    var skippedSeconds: Double { Double(skipped) / Double(rate) }

    /// Rewrites utterance times, note timestamps and `[m:ss]` citations from the shortened stream to the original audio.
    func restore(_ us: [Utterance]) -> [Utterance] { us.map { var u = $0; u.start = toOriginal(u.start); u.end = toOriginal(u.end); return u } }
    func restore(_ ns: [Note]) -> [Note] { ns.map { var n = $0; n.ts = remap(n.ts); return n } }
    func restore(text: String) -> String {
        guard skippedSeconds > 0 else { return text }
        let rx = try! NSRegularExpression(pattern: #"\[(\d+:\d{2}(?::\d{2})?)\]"#)
        var out = text
        for m in rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let r = Range(m.range(at: 1), in: out) else { continue }
            out.replaceSubrange(r, with: remap(String(out[r])))
        }
        return out
    }
    private func remap(_ ts: String) -> String {
        guard skippedSeconds > 0, let s = ReaderProtocol.parseTs(ts) else { return ts }
        return ReaderProtocol.formatTs(Int(toOriginal(Double(s)).rounded(.down)))
    }
}

/// File decode → gain → silence skipping, in ~1 s chunks.
enum AudioPrep {
    static func stream(_ url: URL, skipper: SilenceSkipper, from: Double = 0, onChunk: ([Float]) -> Bool) throws {
        let gain = GainNormalizer()
        var pending: [Float] = []
        var stopped = false
        func emit(_ s: [Float], flush: Bool = false) {
            pending += s
            while !stopped, pending.count >= 16000 || (flush && !pending.isEmpty) {
                let n = min(16000, pending.count); let c = Array(pending.prefix(n)); pending.removeFirst(n)
                if let o = skipper.apply(c), !onChunk(o) { stopped = true }
            }
        }
        try AudioDecode.stream(url, from: from) { c in emit(gain.add(c)); return !stopped }
        if !stopped { emit(gain.finish(), flush: true) }
    }
}
