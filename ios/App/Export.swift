import UIKit

/// Session export (Android ExportSheet subset): MD, TXT, SRT, VTT, PDF. Files are written to the temp dir for the share sheet.
enum Export {
    enum Format: String, CaseIterable, Identifiable { case md, txt, srt, vtt, lrc, pdf; var id: String { rawValue } }

    static func clock(_ t: Double, comma: Bool = false) -> String {
        let ms = Int((t * 1000).rounded()); let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, comma ? "," : ".", ms % 1000)
    }
    /// Android TranscriptExport.clock: [h:]mm:ss.
    static func hms(_ t: Double) -> String {
        let x = max(0, Int(t)), h = x / 3600, m = x % 3600 / 60, s = x % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
    static func mmss(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    static func text(_ s: Session, _ f: Format) -> String {
        switch f {
        case .srt:
            return cues(s.lines).enumerated().map { i, l in "\(i + 1)\n\(clock(l.start, comma: true)) --> \(clock(endOf(l), comma: true))\n\(oneCue(s.name(l.speaker))): \(l.text)\n" }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + cues(s.lines).map { "\(clock($0.start)) --> \(clock(endOf($0)))\n\(vtt(oneCue(s.name($0.speaker)))): \(vtt($0.text))\n" }.joined(separator: "\n")
        case .lrc:
            let head = s.title.isEmpty ? "" : "[ti:\(s.title)]\n"
            return head + s.lines.compactMap { l in
                let x = l.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces); guard !x.isEmpty else { return nil }
                let cs = Int(max(0, l.start) * 100)
                return String(format: "[%02d:%02d.%02d]", cs / 6000, cs / 100 % 60, cs % 100) + "\(s.name(l.speaker)): \(x)" }.joined(separator: "\n") + "\n"
        case .txt, .pdf:
            var o = s.title + "\n\n"
            if !s.summary.isEmpty { o += s.summary + "\n\n" }
            if Prefs.showActions, let a = s.actionItems { o += L("export_heading_actions") + "\n" + a + "\n\n" }
            if !s.notes.isEmpty { o += s.notes.map { ReaderProtocol.render($0) }.joined(separator: "\n") + "\n\n" }
            return o + s.lines.compactMap { l in let x = l.text.trimmingCharacters(in: .whitespacesAndNewlines); return x.isEmpty ? nil : "[\(hms(l.start))] \(s.name(l.speaker)): \(x)" }.joined(separator: "\n")
        case .md:
            var o = "# \(s.title.isEmpty ? L("export_heading_transcript") : s.title)\n\n"
            if !s.summary.isEmpty { o += "## " + L("export_heading_summary") + "\n\n" + s.summary + "\n\n" }
            if Prefs.showActions, let a = s.actionItems { o += "## " + L("export_heading_actions") + "\n\n" + a + "\n\n" }
            if !s.notes.isEmpty { o += "## " + L("agent") + "\n\n" + s.notes.map { "- " + ReaderProtocol.render($0) }.joined(separator: "\n") + "\n\n" }
            return o + "## " + L("export_heading_transcript") + "\n\n" + s.lines.compactMap { l in let x = l.text.trimmingCharacters(in: .whitespacesAndNewlines); return x.isEmpty ? nil : "- `\(hms(l.start))` **\(s.name(l.speaker))** \(x)" }.joined(separator: "\n") + "\n"
        }
    }

    /// Android TranscriptExport.cues: a long turn is cut at punctuation into ≤32-char subtitles, timed by length.
    static func cues(_ ls: [Utterance]) -> [Utterance] {
        ls.flatMap { u -> [Utterance] in
            let text = oneCue(u.text)
            if text.isEmpty { return [] }
            var u0 = u; u0.text = text
            if text.count <= 32 { return [u0] }
            var pieces: [String] = [], sb = ""
            for c in text {
                sb.append(c)
                let soft = "，、,；;：:".contains(c) && sb.count >= 16, hard = "。？！?!.".contains(c) || sb.count >= 32
                if hard || soft { pieces.append(sb.trimmingCharacters(in: .whitespaces)); sb = "" }
            }
            if !sb.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(sb.trimmingCharacters(in: .whitespaces)) }
            pieces = pieces.filter { !$0.isEmpty }
            let total = Double(max(1, pieces.reduce(0) { $0 + $1.count })), dur = endOf(u) - u.start
            var at = u.start, used = 0
            return pieces.map { p in used += p.count; let e = u.start + dur * Double(used) / total
                var c = u; c.id = UUID(); c.text = p; c.start = at; c.end = e; at = e; return c }
        }
    }
    static func endOf(_ u: Utterance) -> Double { u.end > u.start ? u.end : u.start + 1 }
    /// A blank line inside a cue ends it early and desyncs every later cue.
    static func oneCue(_ s: String) -> String { s.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
    static func vtt(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }

    /// Writes the export and returns its URL (nil when the write fails).
    static func file(_ s: Session, _ f: Format) -> URL? {
        let safe = String(s.title.map { "/\\:*?\"<>|".contains($0) ? "_" : $0 }.prefix(60))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((safe.isEmpty ? "VoxSum" : safe) + "." + f.rawValue)
        do {
            if f == .pdf { try pdf(text(s, .txt), title: s.title).write(to: url, options: .atomic) }
            else { try text(s, f).write(to: url, atomically: true, encoding: .utf8) }
            return url
        } catch { return nil }
    }

    static func pdf(_ body: String, title: String) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842), inset = page.insetBy(dx: 40, dy: 48)
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3
        let text = NSMutableAttributedString(string: body, attributes: [.font: UIFont.systemFont(ofSize: 11), .paragraphStyle: para])
        text.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 18), range: NSRange(location: 0, length: (title as NSString).length))
        let setter = CTFramesetterCreateWithAttributedString(text)
        var at = 0
        return UIGraphicsPDFRenderer(bounds: page).pdfData { ctx in
            repeat {
                ctx.beginPage()
                let c = ctx.cgContext
                c.translateBy(x: 0, y: page.height); c.scaleBy(x: 1, y: -1)   // CoreText draws bottom-up
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: at, length: 0), CGPath(rect: CGRect(x: inset.minX, y: page.height - inset.maxY, width: inset.width, height: inset.height), transform: nil), nil)
                CTFrameDraw(frame, c)
                let n = CTFrameGetVisibleStringRange(frame).length
                if n == 0 { break }
                at += n
            } while at < text.length
        }
    }
}
