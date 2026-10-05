import Foundation

/// The meeting reader's protocol, ported from the Android `ReaderProtocol.kt`, itself a port of
/// vieenrose/meeting-summarizer (`eval/phone_live.py`). The model was fine-tuned on exactly this
/// text: every string, regex and threshold is a port, not a design choice. `ReaderParityTests`
/// replays the same goldens as Android's `ReaderParityTest` and must stay identical.
enum ReaderProtocol {
    static let windowTokens = 2000
    static let readMax = 400
    static let restartBudget = 2500
    static let maxNotes = 6
    static let segmentS = 20
    static let ctxBudget = 8192
    static let temp: Float = 0.2
    static let stop = "\nNEXT"
    static let dupLookback = 30
    static let dupJaccard = 0.6

    static let p0 = "<bos><|turn>system\n"
    static let p1 = "<turn|>\n<|turn>user\n"
    static let p2 = "<turn|>\n<|turn>model\n"
    static let p3 = "<turn|>\n<|turn>user\n"

    static let journalHeader = "## 筆記本（至今）\n"
    static let journalEmpty = "（尚無筆記）"
    static func windowHeader(_ k: Int) -> String { "## 逐字稿片段 \(k)\n" }
    static func omitted(_ n: Int) -> String { "\n（另有 \(n) 則較早的筆記未列出）" }

    static let act = rx(#"^\s*(NOTE|REVISE|LOOKBACK|NEXT)\b(.*)$"#)
    static let note = rx(#"^\s*\[?(\d+:\d{2}(?::\d{2})?)\]?\s*(?:\((\w[\w-]*)\)\s*)?(.+)$"#)

    static func formatTs(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func parseTs(_ ts: String) -> Int? {
        let parts = ts.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.contains(nil) else { return nil }
        let p = parts.map { $0! }
        switch p.count {
        case 2: return p[0] * 60 + p[1]
        case 3: return p[0] * 3600 + p[1] * 60 + p[2]
        default: return nil
        }
    }

    private static let lineRx = rx(#"^\[(\d+:\d{2}(?::\d{2})?)\]\s*(.*)$"#)
    private static let speakerRx = rx(#"^(?:S\d+|[^\s:]{1,20})$"#)

    /// ingest.parse_line: `[ts] speaker: text`, speaker optional; nil for a non-transcript line.
    static func parseLine(_ raw: String) -> Line? {
        guard let m = groups(lineRx, raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let start = parseTs(m[1]) else { return nil }
        let rest = m[2]
        if let r = rest.range(of: ": "), r.lowerBound > rest.startIndex {
            let who = String(rest[rest.startIndex..<r.lowerBound])
            if groups(speakerRx, who) != nil { return Line(startS: start, speaker: who, text: String(rest[r.upperBound...])) }
        }
        return Line(startS: start, speaker: nil, text: rest)
    }

    private static let nonSpeechTag = rx(#"\[[A-Za-z][A-Za-z _-]*\]"#)
    private static let filler = rx(#"(?:^|(?<=[，。！？、\s]))[嗯啊呃]+[，。、]?"#)
    private static let ws = rx(#"\s+"#)

    /// ingest.clean_text.
    static func cleanText(_ text: String) -> String {
        replace(ws, replace(filler, replace(nonSpeechTag, text, ""), ""), " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// realtime_agent.similar: character-bigram Jaccard (UTF-16 units, like the Kotlin).
    static func similar(_ a: String, _ b: String) -> Double {
        func bg(_ t: String) -> Set<UInt32> {
            let u = Array(t.utf16)
            return Set((0..<max(0, u.count - 1)).map { UInt32(u[$0]) << 16 | UInt32(u[$0 + 1]) })
        }
        let x = bg(a), y = bg(b)
        return Double(x.intersection(y).count) / Double(max(1, x.union(y).count))
    }

    private static func priority(_ n: Note) -> Int {
        switch n.tag?.uppercased() { case "DECISION": 0; case "OPEN-ISSUE": 1; case "ACTION": 2; default: 3 }
    }
    private static func order(_ notes: [Note]) -> [Int] {
        notes.indices.sorted { (priority(notes[$0]), -$0) < (priority(notes[$1]), -$1) }
    }

    /// conversion_prompts.compact_notes (title/prose input for a small context).
    static func compactNotes(_ notes: [Note], budgetChars: Int) -> [Note] {
        var chosen = Set<Int>(), used = 0
        for i in order(notes) {
            let t = notes[i].text.utf16.count + 24
            if used + t <= budgetChars { chosen.insert(i); used += t }
        }
        return chosen.sorted().map { notes[$0] }
    }

    /// realtime_agent.render.
    static func render(_ n: Note) -> String { "#\(n.id) [\(n.ts)] " + (n.tag.map { "(\($0)) " } ?? "") + n.text }

    /// phone_live.compact: the journal that fits `budget` tokens after a restart.
    static func compact(_ journal: [Note], count: (String) -> Int, budget: Int = restartBudget) -> String {
        var chosen = Set<Int>(), used = 0
        for i in order(journal) {
            let t = count(render(journal[i]))
            if used + t <= budget { chosen.insert(i); used += t }
        }
        let rest = journal.count - chosen.count
        let text = chosen.sorted().map { render(journal[$0]) }.joined(separator: "\n") + (rest > 0 ? omitted(rest) : "")
        return text.isEmpty ? journalEmpty : text
    }

    private static let sections = [
        ("決議事項", "DECISION"), ("待辦與負責人", "ACTION"), ("保留與未決", "OPEN-ISSUE"),
        ("討論要點", "PROPOSAL"), ("重要數字", "NUMBER"),
    ]
    private static let proposalCue = rx(#"^(建議|提議|可以|可考慮|考慮|希望|應該|應|或許|是否|討論|研議)|建議|提議|可考慮"#)
    private static let decided = rx(#"通過|決定|決議|同意|定案"#)

    /// realtime_agent.reclassify_proposals.
    static func reclassify(_ n: Note) -> Note {
        let tag = n.tag?.uppercased()
        guard tag == "DECISION" || tag == "ACTION", find(proposalCue, n.text), !find(decided, n.text) else { return n }
        var m = n; m.tag = "PROPOSAL"; return m
    }

    /// The checked notes grouped by type; every item keeps its `[ts]`.
    static func minutes(_ journal: [Note]) -> String {
        let notes = journal.map(reclassify)
        var out: [String] = []
        for (title, tag) in sections {
            let items = notes.filter { $0.tag?.uppercased() == tag }
            out.append("【\(title)】")
            out += items.isEmpty ? ["- 無"] : items.map { n in
                var t = n.text; while t.hasSuffix("。") { t.removeLast() }
                return "- \(t) [\(n.ts)]"
            }
        }
        return out.joined(separator: "\n")
    }
}

/// One transcript line as the model reads it. `speaker` is "S1", "S2", … or nil.
struct Line: Equatable {
    var startS: Int
    var speaker: String?
    var text: String
    func render() -> String { "[\(ReaderProtocol.formatTs(startS))] " + (speaker.map { "\($0): " } ?? "") + text }
}

/// A journal entry. `tag` is DECISION / ACTION / NUMBER / OPEN-ISSUE / "-" or nil.
struct Note: Equatable, Identifiable, Codable {
    var id: Int
    var window: Int
    var ts: String
    var tag: String?
    var text: String
}

struct ReaderBudget {
    var windowTokens: Int, ctxBudget: Int, restartBudget: Int
    static let standard = ReaderBudget(windowTokens: ReaderProtocol.windowTokens, ctxBudget: ReaderProtocol.ctxBudget, restartBudget: ReaderProtocol.restartBudget)
    static let mobile = ReaderBudget(windowTokens: 1500, ctxBudget: 4096, restartBudget: 1200)
}

// MARK: regex helpers (NSRegularExpression: ICU, close to java.util.regex)

func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

/// Capture groups of the first match (index 0 = whole match; unmatched groups = ""), or nil.
func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
}
func find(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }
func replace(_ re: NSRegularExpression, _ s: String, _ with: String) -> String {
    re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: with)
}
