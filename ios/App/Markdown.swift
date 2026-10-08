import SwiftUI

/// Android renderMarkdown: bold, italic, inline code, hash headings and dash/star/plus bullets for the reader's prose,
/// with each `[m:ss]` / `[h:mm:ss]` anchor drawn as a tappable superscript (no brackets, grey, small, glued to the
/// word before it) that opens `vox://<seconds>`, and speaker names in their transcript colour.
enum Markdown {
    private static let anchor = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?::(\d{2}))?\]"#)

    static func render(_ md: String, anchors: Color? = nil, speakers: [(String, Color)] = []) -> AttributedString {
        var out = AttributedString()
        let lines = md.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            if let h = raw.firstMatch(of: #/^\s{0,3}#{1,6}\s+(.*)$/#) {
                var a = withAnchors(String(h.1), anchors); for r in a.runs { a[r.range].inlinePresentationIntent = (r.inlinePresentationIntent ?? []).union(.stronglyEmphasized) }; out += a
            } else if let b = raw.firstMatch(of: #/^(\s*)[-*+]\s+(.*)$/#) {
                out += AttributedString("•  ") + withAnchors(String(b.2), anchors)
            } else { out += withAnchors(raw, anchors) }
            if i < lines.count - 1 { out += AttributedString("\n") }
        }
        for (name, color) in speakers where !name.isEmpty {
            var from = out.startIndex
            while let r = out[from...].range(of: name) { out[r].foregroundColor = color; out[r].inlinePresentationIntent = .stronglyEmphasized; from = r.upperBound }
        }
        return out
    }

    private static func withAnchors(_ text: String, _ color: Color?) -> AttributedString {
        guard let color else { return inline(text) }
        var out = AttributedString(), last = text.startIndex
        for m in anchor.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text), let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text),
                  let g1 = Int(text[a]), let g2 = Int(text[b]) else { continue }
            let c = Range(m.range(at: 3), in: text).flatMap { Int(text[$0]) }
            let secs = c.map { g1 * 3600 + g2 * 60 + $0 } ?? g1 * 60 + g2
            // Raised like a footnote mark, so the space the model puts before it would only open a gap.
            var before = String(text[last..<r.lowerBound]); while before.hasSuffix(" ") { before.removeLast() }
            out += inline(before) + AttributedString("\u{2060}")
            var mark = AttributedString(c.map { _ in "\(text[a]):\(text[b]):\(text[Range(m.range(at: 3), in: text)!])" } ?? "\(text[a]):\(text[b])")
            mark.link = URL(string: "vox://\(secs)"); mark.foregroundColor = color
            mark.font = .caption2.weight(.medium); mark.baselineOffset = 6
            out += mark; last = r.upperBound
        }
        return out + inline(String(text[last...]))
    }

    /// Inline `***x***` / `**x**` / `__x__` / `*x*` / `_x_` / `` `x` ``; an unclosed marker stays literal.
    private static func inline(_ t: String) -> AttributedString {
        var out = AttributedString(); var i = t.startIndex; var plain = ""
        func flush() { if !plain.isEmpty { out += AttributedString(plain); plain = "" } }
        func span(_ mark: String, _ intent: InlinePresentationIntent) -> Bool {
            guard t[i...].hasPrefix(mark), let end = t.range(of: mark, range: t.index(i, offsetBy: mark.count)..<t.endIndex) else { return false }
            flush(); var a = AttributedString(String(t[t.index(i, offsetBy: mark.count)..<end.lowerBound])); a.inlinePresentationIntent = intent
            out += a; i = end.upperBound; return true
        }
        while i < t.endIndex {
            if span("***", [.stronglyEmphasized, .emphasized]) || span("___", [.stronglyEmphasized, .emphasized]) { continue }
            if t[i...].hasPrefix("***") || t[i...].hasPrefix("___") { plain += t[i..<t.index(i, offsetBy: 3)]; i = t.index(i, offsetBy: 3); continue }
            if span("**", .stronglyEmphasized) || span("__", .stronglyEmphasized) { continue }
            if t[i...].hasPrefix("**") || t[i...].hasPrefix("__") { plain += t[i..<t.index(i, offsetBy: 2)]; i = t.index(i, offsetBy: 2); continue }
            if span("*", .emphasized) || span("_", .emphasized) || span("`", .code) { continue }
            plain.append(t[i]); i = t.index(after: i)
        }
        flush(); return out
    }
}

/// Android SpeakerRefs: the reader writes speakers as S1, S2 (speaker id n is "S{n+1}") and those stay in what is saved;
/// what is shown names them as the transcript does, so a later rename reaches the summary too.
enum SpeakerRefs {
    private static let ref = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])S(\d{1,2})(?![A-Za-z0-9_])"#)
    private static func han(_ c: Character) -> Bool { c.unicodeScalars.first.map { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) } ?? false }

    /// `known`: speaker ids in the transcript; an S-number with no such speaker (a model slip) is left as written.
    static func resolve(_ text: String, label: (Int) -> String, known: Set<Int>?, wrap: (String) -> String = { $0 }) -> String {
        var out = "", last = text.startIndex
        for m in ref.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text), let g = Range(m.range(at: 1), in: text), let n = Int(text[g]) else { continue }
            let id = n - 1
            out += text[last..<r.lowerBound]; last = r.upperBound
            if id < 0 || (known.map { !$0.contains(id) } ?? false) { out += text[r]; continue }
            let name = label(id)
            // Chinese takes no space before a Chinese name: "而 S1 則" → "而語者 1 則".
            if out.hasSuffix(" "), out.count >= 2, han(out[out.index(out.endIndex, offsetBy: -2)]), let f = name.first, han(f) { out.removeLast() }
            out += wrap(name)
            // A name ending in a digit or Latin letter runs into the Chinese after it: "語者 1將" → "語者 1 將".
            if let l = name.last, l.isLetter || l.isNumber, !han(l), r.upperBound < text.endIndex, han(text[r.upperBound]) { out += " " }
        }
        return out + text[last...]
    }
    /// A name as one unit on screen: it never wraps between "語者" and its number.
    static func unbreakable(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "\u{00A0}") }
}

/// Android LocalSpeakerRefs: how model text (notes, title) names speakers in the views below.
private struct SpeakerRefsKey: EnvironmentKey { static let defaultValue: @Sendable (String) -> String = { $0 } }
extension EnvironmentValues {
    var speakerRefs: @Sendable (String) -> String { get { self[SpeakerRefsKey.self] } set { self[SpeakerRefsKey.self] = newValue } }
}
