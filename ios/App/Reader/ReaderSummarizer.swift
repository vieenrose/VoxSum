import Foundation

/// Title and prose for a finished meeting (port of the post-reading half of Android `ReaderLane`):
/// each is one fresh conversation on the same model, not part of the upstream protocol, with its
/// output sanitised hard. Call from the reader's thread.
struct ReaderSummarizer {
    let llm: ReaderLlm
    var budget: ReaderBudget = .mobile
    /// Title and prose read the journal compacted to this many characters (0 = all of it).
    var notesChars = 3900
    static let proseMax = 600

    func title(_ journal: [Note]) -> String? {
        guard !journal.isEmpty else { return nil }
        llm.reset()
        let toks = fitting(journal, 48) { "以下是一場會議的筆記：\n\n" + $0 + "\n\n為這場會議寫一個標題，不超過 20 個字。只輸出標題。" }
        guard llm.append(toks) >= 0 else { return nil }
        let raw = llm.generateContinue(maxTokens: 48, stop: "<turn|>", temp: ReaderProtocol.temp) { _ in }
        let first = raw.components(separatedBy: "<turn|>")[0].split(whereSeparator: \.isNewline)
            .map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let junk = CharacterSet(charactersIn: "「」\"*# ")
        guard let t = first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: junk) else { return nil }
        let cut = String(t.prefix(40))
        return cut.isEmpty ? nil : cut
    }

    /// The summary as prose. Every `[ts]` it cites must be a journal time (anything else is stripped).
    /// Nil when the journal is empty or the reply is unusable; callers fall back to the grouped minutes.
    func prose(_ journal: [Note]) -> String? {
        guard !journal.isEmpty else { return nil }
        llm.reset()
        let toks = fitting(journal, Self.proseMax) { "以下是一場會議的筆記：\n\n" + $0 +
            "\n\n根據這些筆記，用連貫的段落寫一份會議摘要（不要條列、不要標題），" +
            "說明討論了什麼、決定了什麼、誰要做什麼、還有什麼沒解決。" +
            "只寫筆記裡有的內容；提到某件事時在句尾附上筆記的時間，例如 [1:23]。" }
        guard llm.append(toks) >= 0 else { return nil }
        let raw = llm.generateContinue(maxTokens: Self.proseMax, stop: "<turn|>", temp: ReaderProtocol.temp) { _ in }
        return Self.cleanProse(raw, known: Set(journal.map(\.ts)))
    }

    /// The one-shot prompt over the notes, compacted further while it would not leave `maxOut`
    /// tokens of room in the context.
    private func fitting(_ journal: [Note], _ maxOut: Int, _ prompt: (String) -> String) -> [Int] {
        var chars = notesChars
        while true {
            let notes = (chars > 0 ? ReaderProtocol.compactNotes(journal, budgetChars: chars) : journal)
                .map(ReaderProtocol.render).joined(separator: "\n")
            let toks = llm.tokenize("<bos><|turn>user\n", special: true) + llm.tokenize(prompt(notes), special: false) +
                llm.tokenize("<turn|>\n<|turn>model\n", special: true)
            if chars <= 0 || toks.count + maxOut + 8 <= budget.ctxBudget || chars <= 800 { return toks }
            chars -= 400
        }
    }

    private static let tsRx = rx(#"\[(\d+:\d{2}(?::\d{2})?)\]"#)
    private static let spaceBeforePunct = rx(#"[ \t]+([。，、；：！？.,;:!?])"#)
    private static let sentenceEnd = rx(#"[。！？!?](\s*\[\d+:\d{2}(?::\d{2})?\])?|[.](?=\s|$)"#)

    /// The prose reply made presentable: unknown `[ts]` stripped, no headings or bullets, and a
    /// reply cut off by `proseMax` (no end-of-turn) ends at its last whole sentence.
    static func cleanProse(_ raw: String, known: Set<String>) -> String? {
        let ended = raw.contains("<turn|>")
        var text = raw.components(separatedBy: "<turn|>")[0]
        let ns = text as NSString
        var stripped = ""; var last = 0
        for m in tsRx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            stripped += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let whole = ns.substring(with: m.range)
            if known.contains(ns.substring(with: m.range(at: 1))) { stripped += whole }
            last = m.range.location + m.range.length
        }
        stripped += ns.substring(from: last)
        text = replace(spaceBeforePunct, stripped, "$1")
        text = text.split(whereSeparator: \.isNewline).map { l -> String in
            var s = l.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }; return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasPrefix("*") }.joined(separator: "\n\n")
        if !ended {
            let t = text as NSString
            if let e = sentenceEnd.matches(in: text, range: NSRange(location: 0, length: t.length)).last {
                text = t.substring(to: e.range.location + e.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.count >= 20 ? text : nil
    }

    /// An utterance as the model reads it (ingest.segments_to_lines): cleaned text, `S{n}` labels, whole seconds.
    static func toLine(_ u: Utterance) -> Line? {
        let text = ReaderProtocol.cleanText(u.text)
        guard !text.isEmpty else { return nil }
        return Line(startS: Int(u.start.rounded(.down)), speaker: "S\(u.speaker + 1)", text: text)
    }
}
