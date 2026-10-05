import Foundation

/// Simulator stand-in for the mobile reader (the LiteRT framework is arm64-only, the Intel
/// simulator cannot load it): tokens are unicode scalars, every reading turn replies with one
/// canned note citing the last `[m:ss]` it was fed, so the whole UI flow runs.
final class StubLlm: ReaderLlm {
    private var seq: [Int] = []
    private static let ts = rx(#"\[(\d+:\d{2}(?::\d{2})?)\]"#)

    func tokenize(_ text: String, special: Bool) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func append(_ tokens: [Int]) -> Int { seq += tokens; return seq.count }
    func generateContinue(maxTokens: Int, stop: String, temp: Float, onToken: (String) -> Void) -> String {
        let text = String(String.UnicodeScalarView(seq.suffix(6000).compactMap(Unicode.Scalar.init(_:))))
        let reply: String
        if let m = Self.ts.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).last {
            reply = "NOTE [\((text as NSString).substring(with: m.range(at: 1)))] (PROPOSAL) （模擬）討論進行中。\nNEXT"
        } else { reply = "NEXT" }
        let kept = reply.components(separatedBy: stop)[0] + (reply.contains(stop) ? stop : "")
        onToken(kept); seq += tokenize(kept, special: false)
        return kept
    }
    var seqLength: Int { seq.count }
    func reset() { seq.removeAll() }
}
