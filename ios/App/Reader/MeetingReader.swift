import Foundation
import Dispatch
typealias P = ReaderProtocol

/// The live meeting reader (port of `eval/phone_live.py`, via Android's `MeetingReader.kt`):
/// transcript lines are fed into ONE growing conversation as they are spoken — prefill only —
/// and every ~window tokens a reading turn writes up to `maxNotes` typed, cited notes into the
/// journal. Not thread-safe: call everything from one thread.
final class MeetingReader {
    private let llm: ReaderLlm
    private let systemPrompt: String
    private let count: (String) -> Int
    private let events: (AgentEvent) -> Void
    private let clock: () -> UInt64
    private let budget: ReaderBudget

    private(set) var journal: [Note] = []
    private var lines: [Line] = []
    private var k = 0
    var window: Int { k }
    private var windowLines = 0, windowTok = 0, segEnd = 0
    private var segLines: [String] = []
    private var closedSeg: String?
    private var restarts = 0
    private var started = false
    private var pieces: [String: [Int]] = [:]

    init(llm: ReaderLlm, systemPrompt: String, count: ((String) -> Int)? = nil,
         events: @escaping (AgentEvent) -> Void = { _ in },
         clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         budget: ReaderBudget = .standard) {
        self.llm = llm; self.systemPrompt = systemPrompt; self.events = events; self.clock = clock; self.budget = budget
        self.count = count ?? { [unowned llm] in llm.tokenize($0, special: false).count }
    }

    private func state(_ s: AgentState, window: Int = 0, ctx: Int = 0, notes: Int = 0) {
        events(.state(s, window: window, ctxTokens: ctx, notes: notes, windowMax: budget.windowTokens, ctxMax: budget.ctxBudget))
    }

    /// Prefill the fresh prefix (system + empty journal).
    func start() throws {
        for (key, text) in [("p0", P.p0), ("p1", P.p1), ("p2", P.p2), ("p3", P.p3)] { pieces[key] = llm.tokenize(text, special: true) }
        state(.starting)
        try prefillFresh(P.journalEmpty)
        started = true
        state(.listening, ctx: llm.seqLength)
    }

    /// Feed one stable transcript line (in order). May run a reading turn.
    func offer(_ line: Line) throws {
        guard started else { throw ReaderError(description: "start() first") }
        // A line longer than a whole window would overflow a small context: read it as several.
        if count(line.render()) > budget.windowTokens { for l in splitLong(line) { try offerLine(l) }; return }
        try offerLine(line)
    }

    private func splitLong(_ line: Line) -> [Line] {
        var out: [Line] = []
        var rest = Array(line.text.unicodeScalars)
        func str(_ s: ArraySlice<Unicode.Scalar>) -> String { var r = String.UnicodeScalarView(); r.append(contentsOf: s); return String(r) }
        func fits(_ n: Int) -> Bool { var l = line; l.text = str(rest[0..<n]); return count(l.render()) <= budget.windowTokens }
        while !rest.isEmpty {
            var lo = 1, hi = rest.count
            while lo < hi { let mid = (lo + hi + 1) / 2; if fits(mid) { lo = mid } else { hi = mid - 1 } }
            let enders = Set("。？！?!；;，,".unicodeScalars)
            var cut = lo
            if let i = rest[0..<lo].lastIndex(where: { enders.contains($0) }), i >= lo / 2 { cut = i + 1 }
            var l = line; l.text = str(rest[0..<cut]); out.append(l)
            rest = Array(rest[cut...])
        }
        return out
    }

    private func offerLine(_ line: Line) throws {
        let t = count(line.render())
        if windowLines > 0 && windowTok + t > budget.windowTokens { try closeWindow() }
        if windowLines == 0 { try openWindow(line) }
        // The previous segment was not the window's last: it takes its newline and is prefilled now.
        if let c = closedSeg { try append(c + "\n", special: false, what: "segment"); closedSeg = nil }
        lines.append(line)
        windowLines += 1
        windowTok += t
        segLines.append(line.render())
        if line.startS >= segEnd {
            closedSeg = segLines.joined(separator: "\n")
            segLines.removeAll()
            segEnd = line.startS + P.segmentS
        }
    }

    /// End of meeting: read the last partial window. Returns the minutes.
    func finish() throws -> String {
        if windowLines > 0 { try closeWindow() }
        state(.summarizing, window: 0, ctx: llm.seqLength, notes: journal.count)
        return P.minutes(journal)
    }

    private func openWindow(_ first: Line) throws {
        if llm.seqLength + 2 * budget.windowTokens + P.readMax + 600 > budget.ctxBudget { try restart() }
        k += 1
        windowTok = 0
        segEnd = first.startS + P.segmentS
        try append(P.windowHeader(k), special: false, what: "window header")
        state(.listening, window: k, ctx: llm.seqLength, notes: journal.count)
    }

    private func closeWindow() throws {
        let last = closedSeg ?? segLines.joined(separator: "\n")
        closedSeg = nil
        segLines.removeAll()
        if !last.isEmpty { try append(last, special: false, what: "segment") }
        state(.reading, window: k, ctx: llm.seqLength, notes: journal.count)
        let t0 = clock()
        _ = llm.append(pieces["p2"]!)
        let reply = llm.generateContinue(maxTokens: P.readMax, stop: P.stop, temp: P.temp) { [k, events] in events(.turnToken(window: k, piece: $0)) }
        let kept = parse(reply)
        _ = llm.append(pieces["p3"]!)
        events(.turnDone(window: k, reply: reply, kept: kept, ms: Int((clock() - t0) / 1_000_000)))
        windowLines = 0
        windowTok = 0
        state(.listening, window: k, ctx: llm.seqLength, notes: journal.count)
    }

    /// Reply parsing + the deployed guards. When a window yields more than `maxNotes` notes the
    /// cap keeps decisions and actions first (newest first), then numbers, open issues, the rest.
    private func parse(_ reply: String) -> Int {
        var cands: [(raw: String, note: Note)] = []
        for rawLine in reply.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(String.init) {
            guard let m = groups(P.act, rawLine), m[1] == "NOTE" else { continue }
            let raw = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let n = groups(P.note, m[2].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                events(.noteDropped(window: k, line: raw, reason: .parse)); continue
            }
            let ts = n[1], tag: String? = n[2].isEmpty ? nil : n[2], text = n[3]
            let seen = (journal.suffix(P.dupLookback).map(\.text) + cands.map(\.note.text)).suffix(P.dupLookback)
            let reason: DropReason? = resolve(ts) == nil ? .citation : (seen.contains { P.similar(text, $0) > P.dupJaccard } ? .duplicate : nil)
            if let r = reason { events(.noteDropped(window: k, line: raw, reason: r)); continue }
            cands.append((raw, Note(id: 0, window: k, ts: ts, tag: tag, text: text)))
        }
        func rank(_ t: String?) -> Int { switch t?.uppercased() { case "DECISION", "ACTION": 0; case "NUMBER": 1; case "OPEN-ISSUE": 2; default: 3 } }
        let keep = Set(cands.indices.sorted {
            let a = (rank(cands[$0].note.tag), rank(cands[$0].note.tag) == 0 ? -$0 : $0)
            let b = (rank(cands[$1].note.tag), rank(cands[$1].note.tag) == 0 ? -$1 : $1)
            return a < b
        }.prefix(P.maxNotes))
        var kept = 0
        for (i, c) in cands.enumerated() {
            if !keep.contains(i) { events(.noteDropped(window: k, line: c.raw, reason: .cap)); continue }
            var note = c.note; note.id = journal.count + 1
            journal.append(note); kept += 1
            events(.noteKept(note))
        }
        return kept
    }

    /// ingest.resolve_citation: the earliest fed line starting at `ts`, or nil (invented).
    private func resolve(_ ts: String) -> Int? {
        guard let target = P.parseTs(ts) else { return nil }
        return lines.firstIndex { $0.startS == target }
    }

    private func restart() throws {
        let before = llm.seqLength
        state(.restarting, window: k, ctx: before, notes: journal.count)
        llm.reset()
        try prefillFresh(P.compact(journal, count: count, budget: budget.restartBudget))
        restarts += 1
        events(.restart(count: restarts, ctxBefore: before, ctxAfter: llm.seqLength))
    }

    private func prefillFresh(_ journalText: String) throws {
        let toks = pieces["p0"]! + llm.tokenize(systemPrompt, special: false) + pieces["p1"]! +
            llm.tokenize(P.journalHeader + journalText, special: false) + pieces["p2"]! +
            llm.tokenize("NEXT", special: false) + pieces["p3"]!
        try timedAppend(toks, "prefix")
    }

    private func append(_ text: String, special: Bool, what: String) throws { try timedAppend(llm.tokenize(text, special: special), what) }

    private func timedAppend(_ toks: [Int], _ what: String) throws {
        let t0 = clock()
        guard llm.append(toks) >= 0 else { throw ReaderError(description: "reader: prefill failed (\(what))") }
        events(.fed(window: k, what: what, tokens: toks.count, ms: Int((clock() - t0) / 1_000_000), ctxTokens: llm.seqLength))
    }
}
