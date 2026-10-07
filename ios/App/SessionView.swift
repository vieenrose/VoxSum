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
    /// Android volume popup: mute toggle + level, applied to this player only.
    @Published var volume: Float = 1 { didSet { p?.volume = muted ? 0 : volume } }
    @Published var muted = false { didSet { p?.volume = muted ? 0 : volume } }
    func seek(_ t: Double) { p?.currentTime = max(0, min(t, duration)); time = p?.currentTime ?? 0 }
    func stop() { p?.stop(); timer?.invalidate(); playing = false }
}

/// One finished meeting: player, summary (timestamps seek), notes, searchable transcript, rename, export.
struct SessionView: View {
    @State var s: Session
    let save: (Session) -> Void
    let rerun: (Session, Bool) -> Void
    @StateObject private var player: Player
    @AppStorage("showActions") private var showActions = false
    @State private var query = ""
    @State private var follow = true
    @State private var renamingTitle = false
    @State private var draft = ""
    @State private var renamingSpeaker: Int?
    @State private var editingLine: UUID?
    @State private var transcriptDirty = false
    @State private var toast: String?
    @State private var editingSummary = false
    @State private var summaryStale = false
    @State private var undoable: Session?
    @State private var exporting = false
    @State private var exportFile: URL?
    @State private var showExport = Dev.env["VOX_EXPORT"] != nil

    init(session: Session, save: @escaping (Session) -> Void, rerun: @escaping (Session, Bool) -> Void = { _, _ in }) {
        _s = State(initialValue: session); self.save = save; self.rerun = rerun
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
                Menu {
                    Button { player.muted.toggle() } label: { Label(L(player.muted ? "cd_unmute" : "cd_mute"), systemImage: player.muted ? "speaker.wave.2" : "speaker.slash") }
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { v in Button("\(Int(v * 100)) %") { player.muted = false; player.volume = Float(v) } }
                } label: { Image(systemName: player.muted || player.volume == 0 ? "speaker.slash" : "speaker.wave.2").font(.body).foregroundStyle(.secondary) }
                    .accessibilityLabel(L("cd_mute"))
                Button { player.seek(player.time - 5) } label: { Image(systemName: "gobackward.5").font(.title2) }.accessibilityLabel(L("cd_back5"))
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 56, height: 56).background(Color.accentColor, in: Circle())
                }.accessibilityLabel(L(player.playing ? "pause" : "play"))
                Button { player.seek(player.time + 5) } label: { Image(systemName: "goforward.5").font(.title2) }.accessibilityLabel(L("cd_forward5"))
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
                    HStack { Text(L("card_summary")).font(.headline); Spacer()
                        Button { draft = s.summary; editingSummary = true } label: { Image(systemName: "pencil") }.accessibilityLabel(L("cd_edit"))
                        Button { UIPasteboard.general.string = s.summary; toast = L("summary_copied") } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel(L("cd_copy_summary")) }
                    Collapsible(lines: 12) { Text(Self.linked(s.summary)) }.environment(\.openURL, OpenURLAction { u in
                        if u.scheme == "vox", let t = Double(u.host ?? "") { player.seek(t); if !player.playing { player.toggle() }; return .handled }
                        return .systemAction })
                    Text(L("ai_disclaimer")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if showActions, let a = s.actionItems {
                card {
                    HStack {
                        Text(L("card_action_items")).font(.headline); Spacer()
                        Button { UIPasteboard.general.string = a; toast = L("action_items_copied") } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel(L("cd_copy_actions"))
                    }
                    Collapsible(lines: 8) { Text(Self.linked(a)) }.environment(\.openURL, OpenURLAction { u in
                        if u.scheme == "vox", let t = Double(u.host ?? "") { player.seek(t); if !player.playing { player.toggle() }; return .handled }
                        return .systemAction })
                    Text(L("actions_verify_hint")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !s.lines.isEmpty { SpeakerStats(s: s, palette: Self.palette).id("stats") }
            if s.summary.isEmpty { Text(L(s.lines.isEmpty ? "status_no_speech" : "summary_missing_hint")).font(.subheadline).foregroundStyle(.secondary).padding(.top, 12) }
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
                        Text(hits.isEmpty ? L("search_no_matches") : L("search_match_count", match + 1, hits.count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { stepMatch(-1) } label: { Image(systemName: "chevron.up") }.accessibilityLabel(L("search_prev"))
                        Button { stepMatch(1) } label: { Image(systemName: "chevron.down") }.accessibilityLabel(L("search_next"))
                    }
                    Button { searching = false; query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel(L("search_close"))
                }.padding(10).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            if !s.lines.isEmpty { Text(L("pipeline_transcript_via", "X-ASR", L("pipeline_diar_nemotron"))).font(.caption2).foregroundStyle(.secondary) }
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
                .contextMenu { lineMenu(l) }
                .accessibilityAction(named: L("cd_line_actions")) { editingLine = l.id; draft = l.text }
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
            .onAppear { if Dev.env["VOX_SCROLL"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo("stats", anchor: .top) } } }
            .safeAreaInset(edge: .bottom) { if player.available { playerBar } }
            .onChange(of: current) { _, id in if follow, player.playing, tab == 1, let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
        }
        .navigationTitle(s.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { tab = 1; searching = true; searchFocus = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel(L("search_transcript"))
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L("rename")) { draft = s.title; renamingTitle = true }
                    Button(L("export_menu_entry")) { showExport = true }
                    if !s.lines.isEmpty { ShareLink(item: Export.text(s, .txt), subject: Text(s.title)) { Text(L("export_share_transcript")) } }
                    if s.audio != nil {
                        Button(L("re_transcribe")) { rerun(s, true) }
                        Button(L("re_summarize")) { rerun(s, false) }
                    }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(L("cd_more_options")) }
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(s: s) { f in showExport = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if let u = Export.file(s, f) { exportFile = u } else { toast = L("export_share_failed") } } } onSession: { showExport = false; exporting = true; Task { let u = await SessionFile.export(s); exporting = false; try? await Task.sleep(nanoseconds: 400_000_000); if let u { exportFile = u } else { toast = L("session_share_failed") } } }
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
        .alert(L("cd_edit"), isPresented: Binding(get: { editingLine != nil }, set: { if !$0 { editingLine = nil } })) {
            TextField("", text: $draft, axis: .vertical)
            Button(L("done")) {
                let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = editingLine, !t.isEmpty, let i = s.lines.firstIndex(where: { $0.id == id }), s.lines[i].text != t { s.lines[i].text = t; edited() }
            }
            Button(L("cancel"), role: .cancel) {}
        }
        .alert(L("transcript_changed_resummarize"), isPresented: $transcriptDirty) {
            if s.audio != nil { Button(L("re_summarize")) { rerun(s, false) } }
            Button(L("cancel"), role: .cancel) {}
        }
        .overlay(alignment: .bottom) {
            if let toast { Text(toast).font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10).background(.thinMaterial, in: Capsule()).padding(.bottom, 110)
                .transition(.opacity).task { try? await Task.sleep(nanoseconds: 1_800_000_000); withAnimation { self.toast = nil } } }
        }
        .sheet(isPresented: $editingSummary) {
            NavigationStack {
                TextEditor(text: $draft).padding(.horizontal, 12)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { editingSummary = false } }
                        ToolbarItem(placement: .confirmationAction) { Button(L("done")) {
                            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines); editingSummary = false
                            if t != s.summary { s.summary = t; save(s) } } }
                    }.navigationTitle(L("tab_summary")).navigationBarTitleDisplayMode(.inline)
            }
        }
        .alert(L("summary_settings_changed"), isPresented: $summaryStale) {
            Button(L("re_summarize")) { rerun(s, false) }
            Button(L("cancel"), role: .cancel) {}
        }
        .task { if Dev.env["VOX_RESUM"] != nil { rerun(s, false) } }
        .task { if let r = s.reader, r != Prefs.readerId, !s.summary.isEmpty, s.audio != nil { summaryStale = true } }
        .onReceive(NotificationCenter.default.publisher(for: .voxSessionSaved)) { n in
            guard let new = n.object as? Session, new.id == s.id else { return }
            s = new
            if let old = n.userInfo?["undo"] as? Session, !old.summary.isEmpty { withAnimation { undoable = old } }
            if Dev.env["VOX_RESUM"] != nil { try? "undo=\(n.userInfo?["undo"] != nil) names=\(new.speakerNames ?? [:]) reader=\(new.reader ?? "-") summary=\(new.summary.prefix(80))".write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("resum.txt"), atomically: true, encoding: .utf8) }
        }
        .overlay {
            if exporting {
                VStack(spacing: 8) { ProgressView(); Text(L("exporting")).font(.headline); Text(L("exporting_hint")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(40)
            }
        }
        .overlay(alignment: .bottom) {
            if let old = undoable {
                HStack {
                    Text(L("resummary_done")).font(.subheadline); Spacer()
                    Button(L("undo")) { s.summary = old.summary; s.title = old.title; s.notes = old.notes; s.reader = old.reader; save(s); withAnimation { undoable = nil } }.bold()
                }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16).padding(.bottom, 110)
                    .task { try? await Task.sleep(nanoseconds: 8_000_000_000); withAnimation { undoable = nil } }
            }
        }
        .onDisappear { player.stop() }
    }

    /// Android LineMenu: edit the text, move this line to another speaker, or merge this speaker into another.
    @ViewBuilder private func lineMenu(_ l: Utterance) -> some View {
        Button { editingLine = l.id; draft = l.text } label: { Label(L("cd_edit"), systemImage: "pencil") }
        let others = Array(Set(s.lines.map(\.speaker))).sorted().filter { $0 != l.speaker }
        if !others.isEmpty {
            Section(L("speaker_move_line")) { ForEach(others, id: \.self) { k in Button(s.name(k)) { reassign(l.id, k) } } }
            Section(L("speaker_merge_into")) { ForEach(others, id: \.self) { k in Button(s.name(k)) { merge(l.speaker, k) } } }
        }
    }
    /// Android SpeakerEdits: plain relabels, ids kept (labels and colours stay put); a speaker left without lines loses its name.
    private func reassign(_ id: UUID, _ to: Int) {
        guard let i = s.lines.firstIndex(where: { $0.id == id }) else { return }
        let old = s.lines[i].speaker; s.lines[i].speaker = to
        if !s.lines.contains(where: { $0.speaker == old }) { dropName(old) }
        edited()
    }
    private func merge(_ from: Int, _ into: Int) {
        for i in s.lines.indices where s.lines[i].speaker == from { s.lines[i].speaker = into }
        dropName(from); edited()
    }
    private func dropName(_ k: Int) { s.speakerNames?[String(k)] = nil; if s.speakerNames?.isEmpty == true { s.speakerNames = nil } }
    private func edited() { save(s); if !s.summary.isEmpty { transcriptDirty = true } }

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
        guard let re = try? NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?::(\d{2}))?\]"#) else { return AttributedString(text) }
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text), let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text),
                  var mm = Double(text[a]), var ss = Double(text[b]) else { continue }
            if let c = Range(m.range(at: 3), in: text), let x = Double(text[c]) { mm = mm * 60 + ss; ss = x }   // [h:mm:ss] as Android ANCHOR_RE
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
    var onSession: () -> Void = {}
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
            if s.audio != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("export_group_session")).font(.headline)
                    Text(L("export_group_session_desc")).font(.footnote).foregroundStyle(.secondary)
                    Button(L("export_action_save")) { onSession() }.buttonStyle(.bordered)
                }
            }
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


/// Android SpeakerStatsPanel: speaker count beside one stacked talk-time bar in the speakers' colours; tap for the per-speaker legend.
struct SpeakerStats: View {
    let s: Session
    let palette: [Color]
    @State private var legend = false
    private var shares: [(spk: Int, pct: Double)] {
        var d = [Int: Double]()
        for l in s.lines { d[max(0, l.speaker), default: 0] += max(0, l.end - l.start) }
        let total = d.values.reduce(0, +)
        return total > 0 ? d.map { ($0.key, $0.value / total * 100) }.sorted { $0.1 > $1.1 } : []
    }
    var body: some View {
        let sh = shares
        if !sh.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(L("speaker_count", sh.count)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    GeometryReader { g in
                        HStack(spacing: 0) { ForEach(sh, id: \.spk) { x in palette[x.spk % palette.count].frame(width: g.size.width * x.pct / 100) } }
                            .clipShape(Capsule())
                    }.frame(height: 8)
                    Image(systemName: legend ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                if legend {
                    HStack(spacing: 14) {
                        ForEach(sh, id: \.spk) { x in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(palette[x.spk % palette.count]).frame(width: 8, height: 8)
                                Text("\(s.name(x.spk)) · \(Int(x.pct.rounded()))%").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 4).contentShape(Rectangle()).onTapGesture { withAnimation { legend.toggle() } }
        }
    }
}

/// Android CollapsibleMarkdown: folded past `lines` behind Show more / Show less; a new text starts collapsed.
struct Collapsible<C: View>: View {
    let lines: Int
    @ViewBuilder let content: () -> C
    @State private var expanded = false
    @State private var full: CGFloat = 0
    @State private var folded: CGFloat = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content().lineLimit(expanded ? nil : lines)
                .background(GeometryReader { g in Color.clear.onAppear { folded = g.size.height }.onChange(of: g.size.height) { _, h in if !expanded { folded = h } } })
                .background(content().fixedSize(horizontal: false, vertical: true).hidden()
                    .background(GeometryReader { g in Color.clear.onAppear { full = g.size.height }.onChange(of: g.size.height) { _, h in full = h } }))
            if expanded || full > folded + 1 {
                Button(L(expanded ? "show_less" : "show_more")) { withAnimation { expanded.toggle() } }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }
}
