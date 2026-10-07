import SwiftUI
import AVFoundation

/// Plays a session's recording and publishes the position (Android MediaPlayer + seek bar).
@MainActor final class Player: ObservableObject {
    @Published var time = 0.0
    @Published var playing = false
    private(set) var duration = 0.0
    private var p: AVAudioPlayer?
    private var timer: Timer?
    var available: Bool { p != nil }

    init(file: String?) {
        guard let file, let pl = try? AVAudioPlayer(contentsOf: JobQueue.audioDir.appendingPathComponent(file)) else { return }
        pl.prepareToPlay(); p = pl; duration = pl.duration
    }
    func toggle() {
        guard let p else { return }
        if p.isPlaying { p.pause(); playing = false; timer?.invalidate(); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback); try? AVAudioSession.sharedInstance().setActive(true)
        p.play(); playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.p else { return }
                self.time = p.currentTime
                if !p.isPlaying { self.playing = false; self.timer?.invalidate() }
            }
        }
    }
    func seek(_ t: Double) { p?.currentTime = max(0, min(t, duration)); time = p?.currentTime ?? 0 }
    func stop() { p?.stop(); timer?.invalidate(); playing = false }
}

/// One finished meeting: player, summary (timestamps seek), notes, searchable transcript, rename, export.
struct SessionView: View {
    @State var s: Session
    let save: (Session) -> Void
    @StateObject private var player: Player
    @State private var query = ""
    @State private var follow = true
    @State private var renamingTitle = false
    @State private var draft = ""
    @State private var renamingSpeaker: Int?
    @State private var exportFile: URL?
    @State private var showExport = false

    init(session: Session, save: @escaping (Session) -> Void) {
        _s = State(initialValue: session); self.save = save
        _tab = State(initialValue: Int(Dev.env["VOX_TAB"] ?? "") ?? 0)
        if let q = Dev.env["VOX_QUERY"] { _query = State(initialValue: q); _searching = State(initialValue: true) }
        _player = StateObject(wrappedValue: Player(file: session.audio))
    }
    private var shown: [Utterance] { s.lines }
    private var current: UUID? {
        guard player.playing || player.time > 0 else { return nil }
        return s.lines.last(where: { (l: Utterance) -> Bool in l.start <= player.time })?.id
    }

    @State private var tab = 0
    @State private var searching = false
    @State private var match = 0
    @FocusState private var searchFocus: Bool
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo]
    private func tint(_ spk: Int) -> Color { Self.palette[max(0, spk) % Self.palette.count] }
    private var hits: [Utterance] { query.isEmpty ? [] : s.lines.filter { $0.text.localizedCaseInsensitiveContains(query) } }
    @State private var showProcess = Dev.env["VOX_PROCESS"] != nil

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { c() }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
    private var playerBar: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(1, player.duration))
            HStack {
                Text(Export.mmss(player.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button { player.seek(player.time - 5) } label: { Image(systemName: "gobackward.5").font(.title2) }
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 56, height: 56).background(Color.accentColor, in: Circle())
                }.accessibilityLabel(L(player.playing ? "pause" : "play"))
                Button { player.seek(player.time + 5) } label: { Image(systemName: "goforward.5").font(.title2) }
                Spacer()
                Text(Export.mmss(player.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 20).padding(.vertical, 8).background(.bar)
    }
    private var summaryTab: some View {
        VStack(spacing: 12) {
            card {
                HStack {
                    Circle().fill(Color.green).frame(width: 9, height: 9)
                    VStack(alignment: .leading) {
                        Text(L("ai_notes")).font(.headline)
                        Text(L("notes_n", s.notes.count)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(L("done_pill")).font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
                }
                if !s.notes.isEmpty {
                    Button(L(showProcess ? "hide_process" : "show_process")) { withAnimation { showProcess.toggle() } }.font(.subheadline)
                    if showProcess {
                        Text(L("agent_notes_caution")).font(.caption2).foregroundStyle(.secondary)
                        ForEach(s.notes) { n in NoteRow(n: n) { sec in if player.available { player.seek(Double(sec)); if !player.playing { player.toggle() } } } }
                    }
                }
            }
            if !s.summary.isEmpty {
                card {
                    HStack { Spacer(); Button { UIPasteboard.general.string = s.summary } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel(L("copy")) }
                    Text(Self.linked(s.summary)).environment(\.openURL, OpenURLAction { u in
                        if u.scheme == "vox", let t = Double(u.host ?? "") { player.seek(t); if !player.playing { player.toggle() }; return .handled }
                        return .systemAction })
                    Text(L("ai_disclaimer")).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 16)
    }
    private var transcriptTab: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            let speakers = Array(Set(s.lines.map(\.speaker))).sorted()
            if speakers.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(speakers, id: \.self) { k in
                        HStack(spacing: 5) { Circle().fill(tint(k)).frame(width: 8, height: 8); Text(s.name(k)).font(.caption.weight(.semibold)) }
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    } }
                }
            }
            if searching {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("search_transcript_hint"), text: $query).focused($searchFocus).submitLabel(.search)
                        .onChange(of: query) { _, _ in match = 0 }
                    if !query.isEmpty {
                        Text(hits.isEmpty ? L("search_no_matches") : "\(match + 1) / \(hits.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { stepMatch(-1) } label: { Image(systemName: "chevron.up") }.accessibilityLabel(L("search_prev"))
                        Button { stepMatch(1) } label: { Image(systemName: "chevron.down") }.accessibilityLabel(L("search_next"))
                    }
                    Button { searching = false; query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel(L("search_close"))
                }.padding(10).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(shown) { l in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Circle().fill(tint(l.speaker)).frame(width: 8, height: 8)
                        Button { renamingSpeaker = l.speaker; draft = s.speakerNames?[String(l.speaker)] ?? "" } label: { Text(s.name(l.speaker)).font(.caption.bold()) }.buttonStyle(.borderless)
                        Text(Export.mmss(l.start)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(Self.marked(l.text, query))
                }
                .id(l.id).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(l.id == current ? Color.accentColor.opacity(0.18) : (hits.indices.contains(match) && hits[match].id == l.id ? Color.yellow.opacity(0.22) : Color(.secondarySystemGroupedBackground)), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .onTapGesture { if player.available { player.seek(l.start) } }
            }
        }.padding(.horizontal, 16)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    Picker("", selection: $tab) { Text(L("tab_summary")).tag(0); Text(L("tab_transcript")).tag(1) }
                        .pickerStyle(.segmented).padding(.horizontal, 16)
                    if tab == 0 { summaryTab } else { transcriptTab }
                }.padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { if player.available { playerBar } }
            .onChange(of: current) { _, id in if follow, player.playing, tab == 1, let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
        }
        .navigationTitle(s.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { tab = 1; searching = true; searchFocus = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel(L("search_transcript_hint"))
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L("rename")) { draft = s.title; renamingTitle = true }
                    Button(L("export_menu_entry")) { showExport = true }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(L("more")) }
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(s: s) { f in showExport = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exportFile = Export.file(s, f) } }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } })) { if let exportFile { ShareSheet(url: exportFile) } }
        .alert(L("rename"), isPresented: $renamingTitle) {
            TextField(L("title"), text: $draft)
            Button(L("done")) { let t = draft.trimmingCharacters(in: .whitespaces); if !t.isEmpty { s.title = t; save(s) } }
            Button(L("cancel"), role: .cancel) {}
        }
        .alert(L("speaker_rename"), isPresented: Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })) {
            TextField(L("speaker_name"), text: $draft)
            Button(L("done")) {
                if let k = renamingSpeaker {
                    var n = s.speakerNames ?? [:]; let t = draft.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { n[String(k)] = nil } else { n[String(k)] = t }
                    s.speakerNames = n.isEmpty ? nil : n; save(s)
                }
            }
            Button(L("cancel"), role: .cancel) {}
        }
        .onDisappear { player.stop() }
    }

    private func stepMatch(_ d: Int) {
        guard !hits.isEmpty else { return }
        match = (match + d + hits.count) % hits.count
        if player.available { player.seek(hits[match].start) }
    }
    static func marked(_ text: String, _ q: String) -> AttributedString {
        var a = AttributedString(text)
        guard !q.isEmpty else { return a }
        var from = a.startIndex
        while let r = a[from...].range(of: q, options: .caseInsensitive) { a[r].backgroundColor = .yellow.opacity(0.5); from = r.upperBound }
        return a
    }
    private func highlight(_ id: UUID) -> Color? { id == current ? Color.accentColor.opacity(0.18) : nil }

    /// "[1:06]" markers in the summary become links that seek the recording.
    static func linked(_ text: String) -> AttributedString {
        var out = AttributedString(), last = text.startIndex
        guard let re = try? NSRegularExpression(pattern: #"\[(\d+):(\d{2})\]"#) else { return AttributedString(text) }
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text), let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text),
                  let mm = Double(text[a]), let ss = Double(text[b]) else { continue }
            out += AttributedString(text[last..<r.lowerBound])
            var link = AttributedString(text[r]); link.link = URL(string: "vox://\(Int(mm * 60 + ss))"); out += link
            last = r.upperBound
        }
        return out + AttributedString(text[last...])
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}


/// Android ExportSheet: grouped formats (document / subtitles) plus copy transcript; sharing goes through the system sheet (which also offers Save to Files).
struct ExportSheet: View {
    let s: Session
    let onPick: (Export.Format) -> Void
    @State private var copied = false

    private func group(_ title: String, _ desc: String, _ fs: [Export.Format]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(desc).font(.footnote).foregroundStyle(.secondary)
            HStack { ForEach(fs) { f in Button(f.rawValue.uppercased()) { onPick(f) }.buttonStyle(.bordered) } }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("export_sheet_title")).font(.title2.bold())
            group(L("export_group_document"), L("export_group_document_desc"), [.pdf, .md, .txt])
            group(L("export_group_subtitles"), L("export_group_subtitles_desc"), [.srt, .vtt, .lrc])
            Button { UIPasteboard.general.string = Export.text(s, .txt); copied = true } label: { Label(L("export_copy_transcript"), systemImage: copied ? "checkmark" : "doc.on.doc") }
            Spacer()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// Android AgentPanel NoteCard: timestamp pill (seeks), coloured tag chip, text, and a "verify" link on the error-prone tags.
struct NoteRow: View {
    let n: Note
    let seek: (Int) -> Void
    private var full: String {
        let t = (n.tag ?? "").uppercased()
        return ["DECISION", "ACTION", "OPEN-ISSUE", "NUMBER", "PROPOSAL"].first { $0.hasPrefix(t) && !t.isEmpty } ?? t
    }
    private var color: Color {
        switch full { case "DECISION": return .green; case "ACTION": return .blue; case "OPEN-ISSUE": return .orange
        case "NUMBER": return Color(red: 0.55, green: 0.42, blue: 0.94); case "PROPOSAL": return Color(red: 0.05, green: 0.6, blue: 0.65); default: return .gray }
    }
    private var label: String {
        switch full { case "DECISION": return L("agent_tag_decision"); case "ACTION": return L("agent_tag_action"); case "OPEN-ISSUE": return L("agent_tag_open")
        case "NUMBER": return L("agent_tag_number"); case "PROPOSAL": return L("agent_tag_proposal"); default: return n.tag ?? "" }
    }
    var body: some View {
        let sec = ReaderProtocol.parseTs(n.ts)
        HStack(alignment: .top, spacing: 6) {
            Button { if let sec { seek(sec) } } label: {
                Text(n.ts).font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.blue)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
            if let tag = n.tag, tag != "-" {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(color.opacity(0.14), in: Capsule())
            }
            Text(n.text).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if ["DECISION", "ACTION", "NUMBER"].contains(full), let sec {
                Button { seek(sec) } label: {
                    Text(L("agent_verify")).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 1).overlay(Capsule().stroke(Color.orange.opacity(0.5)))
                }.buttonStyle(.plain)
            }
        }.padding(.vertical, 3)
    }
}
