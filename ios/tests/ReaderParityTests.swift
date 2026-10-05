// macOS host test: replays Android's reader goldens through the Swift MeetingReader.
//   build+run: ios/tests/run.sh
import Foundation

final class FakeLlm: ReaderLlm {
    var seq = String.UnicodeScalarView()
    var prompts: [String] = []
    let replies: [(String, Bool)]
    init(_ r: [(String, Bool)]) { replies = r }
    func tokenize(_ text: String, special: Bool) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func append(_ tokens: [Int]) -> Int { seq.append(contentsOf: tokens.map { Unicode.Scalar(UInt32($0))! }); return seqLength }
    func generateContinue(maxTokens: Int, stop: String, temp: Float, onToken: (String) -> Void) -> String {
        prompts.append(String(seq))
        let (content, stopped) = replies[prompts.count - 1]
        let reply = content + (stopped ? stop : "")
        seq.append(contentsOf: reply.unicodeScalars); onToken(reply); return reply
    }
    var seqLength: Int { seq.count }
    func reset() { seq.removeAll() }
}

var failures = 0
func check<T: Equatable>(_ a: T, _ b: T, _ what: String) { if a != b { failures += 1; print("FAIL \(what)\n  want: \(b)\n  got:  \(a)") } }

func replay(_ path: String, _ budget: ReaderBudget) throws -> (g: [String: Any], reader: MeetingReader) {
    let g = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    let turns = g["turns"] as! [[String: Any]]
    let llm = FakeLlm(turns.map { ($0["content"] as! String, $0["stopped"] as! Bool) })
    var restarts = 0
    let reader = MeetingReader(llm: llm, systemPrompt: g["system_prompt"] as! String,
                               count: { $0.unicodeScalars.count },
                               events: { if case .restart = $0 { restarts += 1 } }, budget: budget)
    try reader.start()
    for l in g["lines"] as! [[String: Any]] {
        try reader.offer(Line(startS: l["start"] as! Int, speaker: l["speaker"] as? String, text: l["text"] as! String))
    }
    let minutes = try reader.finish()
    check(llm.prompts.count, turns.count, "turn count")
    for i in 0..<min(turns.count, llm.prompts.count) { check(llm.prompts[i], turns[i]["prompt"] as! String, "conversation at turn \(i + 1)") }
    let notes = g["notes"] as! [[String: Any]]
    check(reader.journal.count, notes.count, "note count")
    for (n, k) in zip(notes, reader.journal) {
        check(k.id, n["id"] as! Int, "id"); check(k.window, n["window"] as! Int, "window"); check(k.ts, n["ts"] as! String, "ts")
        check(k.tag, n["tag"] as? String, "tag"); check(k.text, n["text"] as! String, "text")
    }
    check(minutes, g["minutes_v5"] as! String, "minutes_v5")
    check(restarts, g["restarts"] as! Int, "restarts")
    return (g, reader)
}

@main struct Tests {
    static func main() throws {
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "golden"
        _ = try replay("\(dir)/reader_parity.json", .standard)
        let (g, reader) = try replay("\(dir)/reader_parity_mobile.json", .mobile)
        check(g["window_tokens"] as! Int, ReaderBudget.mobile.windowTokens, "mobile window")
        for (b, want) in g["compact_notes"] as! [String: [Int]] {
            check(P.compactNotes(reader.journal, budgetChars: Int(b)!).map(\.id), want, "compact_notes at \(b)")
        }
        // helpers
        check(P.formatTs(3725), "1:02:05", "formatTs"); check(P.parseTs("1:02:05"), 3725, "parseTs")
        check(P.cleanText("嗯，我們啊 [Music] 開會。"), "我們啊 開會。", "cleanText")
        print(failures == 0 ? "PASS: reader parity (standard + mobile)" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
