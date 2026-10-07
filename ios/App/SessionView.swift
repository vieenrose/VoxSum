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

    init(session: Session, save: @escaping (Session) -> Void) {
        _s = State(initialValue: session); self.save = save
        _player = StateObject(wrappedValue: Player(file: session.audio))
    }
    private var shown: [Utterance] {
        if query.isEmpty { return s.lines }
        return s.lines.filter { (l: Utterance) -> Bool in
            l.text.localizedCaseInsensitiveContains(query) || s.name(l.speaker).localizedCaseInsensitiveContains(query)
        }
    }
    private var current: UUID? {
        guard player.playing || player.time > 0 else { return nil }
        return s.lines.last(where: { (l: Utterance) -> Bool in l.start <= player.time })?.id
    }

    @State private var tab = 0
    @State private var showProcess = false

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
                    if showProcess { ForEach(s.notes) { Text(ReaderProtocol.render($0)).font(.caption).padding(.top, 2) } }
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
            ForEach(shown) { l in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Button { renamingSpeaker = l.speaker; draft = s.speakerNames?[String(l.speaker)] ?? "" } label: { Text(s.name(l.speaker)).font(.caption.bold()) }.buttonStyle(.borderless)
                        Text(Export.mmss(l.start)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(l.text)
                }
                .id(l.id).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(l.id == current ? Color.accentColor.opacity(0.18) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
        .searchable(text: $query)
        .navigationTitle(s.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L("rename")) { draft = s.title; renamingTitle = true }
                    Menu(L("export")) { ForEach(Export.Format.allCases) { f in Button(f.rawValue.uppercased()) { exportFile = Export.file(s, f) } } }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(L("more")) }
            }
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
