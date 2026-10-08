import SwiftUI

/// Live state of the meeting-reading agent, folded from `AgentEvent`s (port of Android's AgentUiState).
@MainActor final class AgentUi: ObservableObject {
    struct Step: Identifiable {
        let id = UUID()
        var window: Int
        var restart = false
        var tokens = 0
        var reading = false
        var done = false
        var ms = 0
        var kept = 0
        var dropped = 0
        var ctxBefore = 0
        var ctxAfter = 0
    }
    struct LogLine: Identifiable { let id = UUID(); let prefix: String; let text: String; let dropped: Bool }

    @Published var state: AgentState?
    @Published var notesSoFar = 0
    @Published var reply = ""
    @Published var ctxTokens = 0
    @Published var windowMax = ReaderBudget.mobile.windowTokens
    @Published var ctxMax = ReaderBudget.mobile.ctxBudget
    @Published var notes: [Note] = []
    @Published var steps: [Step] = []
    @Published var log: [LogLine] = []
    var wholeTranscript = true

    var working: Bool { state != nil && state != .done }
    var windowsRead: Int { steps.filter { !$0.restart && $0.done }.count }

    func reset() { state = nil; reply = ""; ctxTokens = 0; notesSoFar = 0; notes = []; steps = []; log = [] }

    func apply(_ e: AgentEvent) {
        switch e {
        case let .state(s, window, ctx, n, wMax, cMax):
            if s == .starting { reset() }
            if ctx > 0 { ctxTokens = ctx }
            if wMax > 0 { windowMax = wMax }
            if cMax > 0 { ctxMax = cMax }
            if window > 0 && !steps.contains(where: { !$0.restart && $0.window == window }) { steps.append(Step(window: window)) }
            if s == .reading { reply = ""; edit { $0.reading = true } }
            notesSoFar = n; state = s
        case let .fed(window, what, tokens, ms, ctx):
            if window > 0 && !steps.contains(where: { !$0.restart && $0.window == window }) { steps.append(Step(window: window)) }
            ctxTokens = ctx
            if what == "segment" { edit { $0.tokens += tokens } }
            add("▸", "\(what) · \(tokens) tok · \(String(format: "%.1f", Double(ms) / 1000)) s · ctx \(ctx)")
        case let .turnToken(_, piece): reply += piece
        case let .turnDone(window, _, kept, ms):
            edit { $0.reading = false; $0.done = true; $0.ms = ms }
            add("✎", "window \(window) · \(String(format: "%.1f", Double(ms) / 1000)) s · +\(kept) notes")
        case let .noteKept(n):
            notes.append(n); edit { $0.kept += 1 }; add("+", ReaderProtocol.render(n))
        case let .noteDropped(_, line, reason):
            edit { $0.dropped += 1 }; add("×", "\("\(reason)") · \(line)", dropped: true)
        case let .restart(count, before, after):
            ctxTokens = after
            steps.append(Step(window: 0, restart: true, done: true, ctxBefore: before, ctxAfter: after))
            add("↺", "#\(count) · ctx \(before) → \(after)")
        }
    }
    private func edit(_ f: (inout Step) -> Void) { if let i = steps.lastIndex(where: { !$0.restart }) { f(&steps[i]) } }
    private func add(_ p: String, _ t: String, dropped: Bool = false) {
        log.append(LogLine(prefix: p, text: t, dropped: dropped)); if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

private func notesCount(_ n: Int) -> String { L(n == 1 ? "agent_notes_count_one" : "agent_notes_count", String(n)) }
private func fmt(_ n: Int) -> String { n.formatted() }

/// The Agent panel: header with state chip, simple view (one bar + notes) or detailed (gauges, per-window timeline, activity log).
struct AgentPanel: View {
    @ObservedObject var agent: AgentUi
    var seek: (Int) -> Void = { _ in }
    @State private var detailed = Dev.env["VOX_DETAIL"] != nil
    @State private var showLog = false
    @State private var opened: Set<Int> = []
    @State private var expandedOverride: Bool?

    fileprivate func color(_ s: AgentState) -> Color {
        switch s { case .starting: return .gray; case .listening: return .blue; case .reading, .summarizing: return .orange; case .restarting: return .secondary; case .done: return .green }
    }
    fileprivate func chip(_ s: AgentState) -> String {
        switch s { case .starting: return L("agent_state_starting"); case .listening: return L("agent_state_listening"); case .reading: return L("agent_state_reading")
        case .restarting: return L("agent_state_restarting"); case .summarizing: return L("agent_state_summarizing"); case .done: return L("agent_state_done") }
    }
    fileprivate func line(_ s: AgentState) -> String {
        switch s { case .starting: return L("agent_starting"); case .listening: return L("agent_listening", agent.notesSoFar); case .reading: return L("agent_reading", agent.steps.last { !$0.restart }?.window ?? 0)
        case .restarting: return L("agent_restarting"); case .summarizing: return L("agent_summarizing", agent.notesSoFar); case .done: return L("agent_done", notesCount(agent.notes.count)) }
    }

    var body: some View {
        if let st = agent.state {
            let done = st == .done
            let expanded = expandedOverride ?? !done
            let hasProcess = agent.windowsRead > 0 || !agent.log.isEmpty
            VStack(alignment: .leading, spacing: 12) {
                Button { expandedOverride = !expanded } label: {
                    HStack(spacing: 10) {
                        Dot(color: color(st), pulsing: agent.working)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L("agent_title")).font(.headline)
                            Text(L(agent.windowsRead == 1 ? "agent_outcome_one" : "agent_outcome", String(agent.windowsRead), notesCount(agent.notes.count))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(chip(st)).font(.caption.weight(.semibold)).foregroundStyle(color(st))
                            .padding(.horizontal, 10).padding(.vertical, 4).background(color(st).opacity(0.14), in: Capsule())
                    }
                }.buttonStyle(.plain)
                if !expanded {
                    Button(L("agent_show_process")) { expandedOverride = true }.font(.subheadline)
                } else {
                    if detailed && hasProcess { Detailed(agent: agent, st: st, seek: seek, opened: $opened, color: color, line: line) }
                    else { Simple(agent: agent, st: st, seek: seek, line: line) }
                    if !agent.notes.isEmpty { Text(L("agent_notes_caution")).font(.caption2).foregroundStyle(.secondary) }
                    HStack(spacing: 20) {
                        if done { Button(L("agent_hide_process")) { expandedOverride = false } }
                        if hasProcess { Button(L(detailed ? "agent_view_simple" : "agent_view_detailed")) { detailed.toggle(); if !detailed { showLog = false } }.foregroundStyle(.secondary) }
                        if detailed && !agent.log.isEmpty { Button(L(showLog ? "agent_hide_log" : "agent_show_log", agent.log.count)) { showLog.toggle() }.foregroundStyle(.secondary) }
                    }.font(.subheadline)
                    if detailed && showLog {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(agent.log.reversed().prefix(60)) { l in
                                Text("\(l.prefix) \(l.text)").font(.system(size: 10, design: .monospaced)).lineLimit(2)
                                    .foregroundStyle(l.dropped ? .secondary : .primary)
                            }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.animation(.default, value: expanded)
        }
    }
}

private struct Dot: View {
    let color: Color; let pulsing: Bool
    @State private var dim = false
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10).opacity(pulsing && dim ? 0.3 : 1)
            .onAppear { if pulsing { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true } } }
    }
}

private struct Bar: View {
    let value: Int, max: Int, active: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(active ? Color.blue : Color.secondary).frame(width: g.size.width * CGFloat(Swift.min(1, Double(value) / Double(Swift.max(1, max)))))
            }
        }.frame(height: 6)
    }
}

private struct Simple: View {
    @ObservedObject var agent: AgentUi
    let st: AgentState; let seek: (Int) -> Void; let line: (AgentState) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch st {
            case .listening:
                Text(L(agent.wholeTranscript ? "agent_simple_reading_all" : "agent_simple_listening")).font(.subheadline)
                Bar(value: agent.steps.last { !$0.restart }?.tokens ?? 0, max: agent.windowMax, active: true)
            case .done: EmptyView()
            default: Text(line(st)).font(.subheadline)
            }
            if agent.steps.last(where: { !$0.restart })?.reading == true, !agent.reply.isEmpty { ReplyPreview(reply: agent.reply) }
            ForEach(agent.notes.sorted { $0.window > $1.window }) { NoteRow(n: $0, seek: seek) }
        }
    }
}

private struct Detailed: View {
    @ObservedObject var agent: AgentUi
    let st: AgentState; let seek: (Int) -> Void
    @Binding var opened: Set<Int>
    let color: (AgentState) -> Color; let line: (AgentState) -> String

    private func gauge(_ label: String, _ v: Int, _ m: Int, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label).font(.caption).foregroundStyle(.secondary); Spacer(); Text("\(fmt(Swift.min(v, m))) / \(fmt(m))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
            Bar(value: v, max: m, active: active)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if st != .done {
                gauge(L("agent_gauge_window"), agent.steps.last { !$0.restart }?.tokens ?? 0, agent.windowMax, active: st == .listening)
                gauge(L("agent_gauge_context"), agent.ctxTokens, agent.ctxMax, active: false)
            }
            let steps = Array(agent.steps.reversed())
            let writing = agent.steps.last { !$0.restart }?.reading == true
            let latest: Int? = writing ? nil : agent.notes.map(\.window).max()
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 4) {
                        Circle().fill(s.restart ? Color.orange : s.done ? .green : s.reading ? .orange : .blue).frame(width: 10, height: 10).padding(.top, 5)
                        if i < steps.count - 1 { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2) }
                    }.frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        if s.restart { Text(L("agent_step_restart", fmt(s.ctxBefore), fmt(s.ctxAfter))).font(.subheadline) }
                        else {
                            Text(L(s.done ? "agent_step_done" : s.reading ? "agent_step_reading" : "agent_step_listening", s.window)).font(.subheadline.weight(.medium))
                            let wn = agent.notes.filter { $0.window == s.window }
                            let folded = !wn.isEmpty && s.window != latest
                            var parts = [L("agent_step_tokens", fmt(s.tokens))]
                            let _ = { if s.done { parts.append("\(Int((Double(s.ms) / 1000).rounded())) s"); if s.dropped > 0 { parts.append(L("agent_step_dropped", s.dropped)) } } }()
                            HStack(spacing: 0) {
                                Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                if s.done {
                                    Text(" · ").font(.caption).foregroundStyle(.secondary)
                                    Button(L("agent_step_kept", notesCount(s.kept))) { if opened.contains(s.window) { opened.remove(s.window) } else { opened.insert(s.window) } }
                                        .font(.caption).foregroundStyle(folded ? Color.blue : .secondary).disabled(!folded).buttonStyle(.plain)
                                }
                            }
                            if s.reading && i == 0 && !agent.reply.isEmpty { ReplyPreview(reply: agent.reply) }
                            if !wn.isEmpty && (s.window == latest || opened.contains(s.window)) { ForEach(wn.reversed()) { NoteRow(n: $0, seek: seek) } }
                        }
                    }.padding(.bottom, i < steps.count - 1 ? 10 : 0)
                }
            }
            if steps.isEmpty { Text(line(st)).font(.subheadline) }
        }
    }
}

/// The reply being written, as note rows (last 5, newest on top with a caret); display only, the protocol text is not rewritten.
private struct ReplyPreview: View {
    let reply: String
    private struct RL: Identifiable { let id: Int; let ts: String?; let tag: String?; let text: String; let note: Bool }
    private var rows: [RL] {
        let re = try! NSRegularExpression(pattern: #"^\s*NOTE\b\s*\[?(\d+(?::\d{0,2}){0,2})?\]?\s*(?:\(([A-Za-z-]*)\)?)?\s*(.*)$"#)
        let ls = reply.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !"NEXT".hasPrefix($0) && !"NOTE".hasPrefix($0) }
        return ls.suffix(5).enumerated().map { i, l in
            let ns = l as NSString
            if let m = re.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) {
                func g(_ k: Int) -> String? { m.range(at: k).location == NSNotFound ? nil : ns.substring(with: m.range(at: k)) }
                return RL(id: i, ts: g(1).flatMap { $0.isEmpty ? nil : $0 }, tag: g(2).flatMap { $0.isEmpty ? nil : $0 }, text: g(3) ?? "", note: true)
            }
            return RL(id: i, ts: nil, tag: nil, text: l, note: false)
        }.reversed()
    }
    var body: some View {
        let r = rows
        if !r.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(r.enumerated()), id: \.element.id) { i, l in
                    HStack(spacing: 6) {
                        if let ts = l.ts { Text(ts).font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.blue).padding(.horizontal, 5).background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6)) }
                        if let t = l.tag, t.count >= 3, t != "-" { Text(t.capitalized).font(.caption2.weight(.semibold)).padding(.horizontal, 6).background(Color.secondary.opacity(0.15), in: Capsule()) }
                        Text(l.text + (i == 0 ? " ▍" : "")).font(.footnote).lineLimit(2).foregroundStyle(l.note ? .primary : .secondary)
                    }
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Android AgentStrip: the reader's status pinned on the recording screen — state, notes so far, the window filling
/// up while it listens, then the line being written or the latest note.
struct AgentStrip: View {
    @ObservedObject var agent: AgentUi
    @Environment(\.speakerRefs) private var refs
    var body: some View {
        if let st = agent.state {
            let p = AgentPanel(agent: agent), cur = agent.steps.last { !$0.restart }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Dot(color: p.color(st), pulsing: agent.working)
                    Text(L("agent_title")).font(.subheadline.weight(.semibold))
                    Spacer()
                    if !agent.notes.isEmpty { Text(notesCount(agent.notes.count)).font(.caption).foregroundStyle(.secondary) }
                    Text(p.chip(st)).font(.caption2.weight(.semibold)).foregroundStyle(p.color(st))
                        .padding(.horizontal, 8).padding(.vertical, 3).background(p.color(st).opacity(0.14), in: Capsule())
                }
                if st == .listening, let cur { Bar(value: cur.tokens, max: agent.windowMax, active: true).frame(height: 3) }
                if st == .reading, let last = agent.reply.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    Text(String(last).replacingOccurrences(of: "NOTE ", with: "") + " ▍").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let n = agent.notes.last {
                    HStack(spacing: 8) {
                        Text(n.ts).font(.caption2.monospaced()).foregroundStyle(.blue)
                        Text(refs(n.text)).font(.caption).lineLimit(1)
                    }
                } else { Text(p.line(st)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
        }
    }
}
