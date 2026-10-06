import Foundation

enum ChineseScript: String, CaseIterable { case traditional = "zh-Hant", simplified = "zh-Hans" }

/// Port of Android `OpenCcConverter`: longest-match OpenCC dictionaries (bundled in `opencc/`), staged.
/// Generated text (title, summary, notes) gets the full Taiwan localisation (s2twp / tw2sp); transcripts only
/// the character-level conversion (what was said keeps its words).
final class OpenCC: @unchecked Sendable {
    private let stages: [[String: String]], maxKey: Int
    private init(_ s: [[String: String]]) { stages = s; maxKey = s.flatMap(\.keys).map { $0.unicodeScalars.count }.max() ?? 1 }

    func convert(_ text: String) -> String {
        let sc = Array(text.unicodeScalars)
        if sc.contains(where: { (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value) }) { return text }
        var cur = sc
        for d in stages where !d.isEmpty { cur = Self.apply(cur, d, maxKey) }
        var v = String.UnicodeScalarView(); v.append(contentsOf: cur); return String(v)
    }

    private static func apply(_ t: [Unicode.Scalar], _ d: [String: String], _ maxKey: Int) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []; out.reserveCapacity(t.count)
        var i = 0
        while i < t.count {
            var hit = false
            var len = min(maxKey, t.count - i)
            while len >= 1 {
                var k = String.UnicodeScalarView(); k.append(contentsOf: t[i..<i + len])
                if let r = d[String(k)] { out.append(contentsOf: r.unicodeScalars); i += len; hit = true; break }
                len -= 1
            }
            if !hit { out.append(t[i]); i += 1 }
        }
        return out
    }

    // MARK: dictionaries
    private static func load(_ name: String, reverse: Bool = false, into m: inout [String: String]) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "opencc"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in s.split(separator: "\n") where !line.hasPrefix("#") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let src = String(line[..<tab]), vals = line[line.index(after: tab)...].split(separator: " ").map(String.init)
            if reverse { for v in vals where v != src && m[v] == nil { m[v] = src } }
            else if let f = vals.first, f != src { m[src] = f }
        }
    }
    private static var s2tCache: [String: String]?
    private static func s2t() -> [String: String] {
        if let c = s2tCache { return c }
        var m: [String: String] = [:]; load("STPhrases", into: &m); load("STCharacters", into: &m); s2tCache = m; return m
    }
    private static var cache: [String: OpenCC] = [:]; private static let lock = NSLock()
    private static func memo(_ k: String, _ b: () -> OpenCC) -> OpenCC { lock.lock(); defer { lock.unlock() }; if let c = cache[k] { return c }; let c = b(); cache[k] = c; return c }

    /// Generated text (summary, title, notes, speaker names).
    static func generated(_ s: ChineseScript) -> OpenCC {
        memo("gen-" + s.rawValue) {
            switch s {
            case .traditional:
                var tw: [String: String] = [:]; load("TWVariants", into: &tw); load("TWVariantsPhrases", into: &tw); load("TWPhrases", into: &tw)
                return OpenCC([s2t(), tw])
            case .simplified:
                var rev: [String: String] = [:]
                load("TWPhrases", reverse: true, into: &rev); load("TWVariantsPhrases", reverse: true, into: &rev); load("TWVariants", reverse: true, into: &rev)
                for k in ["地點選", "重點選", "景點選", "觀點選", "優點選", "缺點選", "起點選", "終點選", "站點選", "據點選", "時點選", "焦點選", "執行"] { rev[k] = k }
                var t2s: [String: String] = [:]; load("TSPhrases", into: &t2s); load("TSCharacters", into: &t2s)
                return OpenCC([rev, t2s])
            }
        }
    }
    /// Transcripts: character-level only.
    static func transcript(_ s: ChineseScript) -> OpenCC {
        memo("tr-" + s.rawValue) {
            switch s {
            case .traditional: var tw: [String: String] = [:]; load("TWVariants", into: &tw); return OpenCC([s2t(), tw])
            case .simplified: var t2s: [String: String] = [:]; load("TSPhrases", into: &t2s); load("TSCharacters", into: &t2s); return OpenCC([t2s])
            }
        }
    }
}

/// Per-run converter for the chosen script: transcript utterances (cached by text, so only the live tail costs)
/// and generated text (title, summary, notes).
final class TextConv: @unchecked Sendable {
    private let tr: OpenCC, gen: OpenCC; private var cache: [String: String] = [:]; private let lock = NSLock()
    init(_ s: ChineseScript = AppLanguage.current.script) { tr = .transcript(s); gen = .generated(s) }
    func utterances(_ us: [Utterance]) -> [Utterance] {
        lock.lock(); defer { lock.unlock() }
        return us.map { var u = $0; if let c = cache[u.text] { u.text = c } else { let c = tr.convert(u.text); cache[u.text] = c; u.text = c }; return u }
    }
    func notes(_ ns: [Note]) -> [Note] { ns.map { var n = $0; n.text = gen.convert(n.text); return n } }
    func text(_ s: String) -> String { gen.convert(s) }
}
