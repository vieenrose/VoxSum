import UIKit

/// Session export (Android ExportSheet subset): MD, TXT, SRT, VTT, PDF. Files are written to the temp dir for the share sheet.
enum Export {
    enum Format: String, CaseIterable, Identifiable { case md, txt, srt, vtt, lrc, pdf; var id: String { rawValue } }

    static func clock(_ t: Double, comma: Bool = false) -> String {
        let ms = Int((t * 1000).rounded()); let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, comma ? "," : ".", ms % 1000)
    }
    static func mmss(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    static func text(_ s: Session, _ f: Format) -> String {
        switch f {
        case .srt:
            return s.lines.enumerated().map { i, l in "\(i + 1)\n\(clock(l.start, comma: true)) --> \(clock(l.end, comma: true))\n\(s.name(l.speaker)): \(l.text)\n" }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + s.lines.map { "\(clock($0.start)) --> \(clock($0.end))\n<v \(s.name($0.speaker))>\($0.text)\n" }.joined(separator: "\n")
        case .lrc:
            return s.lines.map { l in let m = Int(l.start) / 60, sec = l.start - Double(m * 60); return String(format: "[%02d:%05.2f]", m, sec) + "\(s.name(l.speaker)): \(l.text)" }.joined(separator: "\n")
        case .txt, .pdf:
            var o = s.title + "\n\n"
            if !s.summary.isEmpty { o += s.summary + "\n\n" }
            if Prefs.showActions, let a = s.actionItems { o += L("export_heading_actions") + "\n" + a + "\n\n" }
            if !s.notes.isEmpty { o += s.notes.map { ReaderProtocol.render($0) }.joined(separator: "\n") + "\n\n" }
            return o + s.lines.map { "[\(mmss($0.start))] \(s.name($0.speaker)): \($0.text)" }.joined(separator: "\n")
        case .md:
            var o = "# \(s.title)\n\n"
            if !s.summary.isEmpty { o += s.summary + "\n\n" }
            if Prefs.showActions, let a = s.actionItems { o += "## " + L("export_heading_actions") + "\n\n" + a + "\n\n" }
            if !s.notes.isEmpty { o += "## " + L("agent") + "\n\n" + s.notes.map { "- " + ReaderProtocol.render($0) }.joined(separator: "\n") + "\n\n" }
            return o + "## " + L("transcript") + "\n\n" + s.lines.map { "**\(s.name($0.speaker))** [\(mmss($0.start))] \($0.text)\n" }.joined(separator: "\n")
        }
    }

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
