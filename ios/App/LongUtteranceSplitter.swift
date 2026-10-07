import Foundation

/// One speaker talking without a pause comes out of the engine as a single utterance, minutes long: an unreadable
/// wall of text whose every summary link seeks to the same second. Cuts such an utterance at sentence ends; cut times
/// are estimated from character counts (speech rate is near constant over a sentence), accurate to a second or two.
/// Port of the Android LongUtteranceSplitter.
enum LongUtteranceSplitter {
    private static let minSec = 20.0, minChars = 100, chunkChars = 90   // a piece closes at the first sentence end past chunkChars
    private static let sentenceEnd: Set<Character> = ["。", "？", "！", "?", "!", ".", "；", ";"]

    static func split(_ list: [Utterance]) -> [Utterance] {
        func long(_ u: Utterance) -> Bool { u.end - u.start > minSec && u.text.count > minChars }
        guard list.contains(where: long) else { return list }
        var out: [Utterance] = []
        for u in list {
            let parts = long(u) ? pieces(u.text) : [u.text]
            if parts.count <= 1 { out.append(u); continue }
            let total = Double(parts.reduce(0) { $0 + $1.count })
            var at = u.start, used = 0
            for (i, p) in parts.enumerated() {
                used += p.count
                let end = i == parts.count - 1 ? u.end : u.start + (u.end - u.start) * Double(used) / total
                out.append(Utterance(speaker: u.speaker, start: at, end: end, text: p.trimmingCharacters(in: .whitespaces)))
                at = end
            }
        }
        return out
    }

    private static func pieces(_ text: String) -> [String] {
        let cs = Array(text)
        var res: [String] = [], cur = ""
        for (i, c) in cs.enumerated() {
            cur.append(c)
            // ASCII '.' only ends a sentence when followed by a space (not 3.14)
            let ends = sentenceEnd.contains(c) && (c != "." || i + 1 >= cs.count || cs[i + 1] == " ")
            if ends && cur.count >= chunkChars { res.append(cur); cur = "" }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty {
            if !res.isEmpty && cur.count < chunkChars / 3 { res[res.count - 1] += cur } else { res.append(cur) }
        }
        return res.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
