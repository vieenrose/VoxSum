import SwiftUI

@main struct VoxSumApp: App { var body: some Scene { WindowGroup { ContentView() } } }

/// Mic chunks arrive on the audio thread, the engine loop drains them on another.
final class ChunkBuffer: @unchecked Sendable {
    private var data: [Float] = []; private let lock = NSLock()
    func add(_ c: [Float]) { lock.lock(); data += c; lock.unlock() }
    func take() -> [Float] { lock.lock(); defer { lock.unlock() }; let d = data; data = []; return d }
}

@MainActor final class Model: ObservableObject {
    @Published var lines: [Utterance] = []
    @Published var notes: [Note] = []
    @Published var title = ""
    @Published var summary = ""
    @Published var status = "Prêt"
    // Dev paths on the Mac (the simulator shares its filesystem).
    let base = ProcessInfo.processInfo.environment["VOX_BASE"] ?? "/Users/Pesi/work"

    let store = ModelStore()
    let library = LibraryStore()
    @Published var sessions: [Session] = []
    func reload() { Task { sessions = await library.all() } }
    func remove(_ s: Session) { Task { await library.delete(s.id); sessions = await library.all() } }
    func open(_ s: Session) { lines = s.lines; notes = s.notes; title = s.title; summary = s.summary; status = "Archive du \(s.date.formatted(date: .abbreviated, time: .shortened))" }
    private func archive(lines: [Utterance], notes: [Note], title: String, summary: String, seconds: Double) async {
        guard !lines.isEmpty else { return }
        let fallback = lines.first.map { String($0.text.prefix(20)) } ?? "Réunion"
        try? await library.save(Session(title: title.isEmpty ? fallback : title, summary: summary, seconds: seconds, lines: lines, notes: notes))
        sessions = await library.all()
    }
    @Published var recording = false
    private var recorder: Recorder?
    private let buffer = ChunkBuffer()

    func toggleRecord() {
        if recording { recorder?.stop(); recorder = nil; recording = false; status = "Arrêt…"; return }
        Task {
            guard await Recorder.requestPermission() else { status = "Micro refusé"; return }
            guard await downloadSpeech() else { return }
            status = "Chargement des modèles…"; lines = []; notes = []; title = ""; summary = ""
            let r = Recorder(); recorder = r; recording = true
            let b = base
            Task.detached { [weak self] in
                guard let self, let eng = NemoEngine(xasr: self.modelPath("x-asr-zh-en-q8_0.gguf", b), diar: self.modelPath("nemotron-3-diarization-q8_0.gguf", b)) else {
                    await MainActor.run { self?.status = "Modèles ASR absents"; self?.recording = false }; return }
                do { try r.start { [buffer = self.buffer] c in buffer.add(c) } }
                catch { await MainActor.run { self.status = "Micro : \(error)"; self.recording = false }; return }
                var seen = 0
                while await MainActor.run(body: { self.recording }) {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let chunk = self.buffer.take()
                    if !chunk.isEmpty { _ = eng.push(chunk) }
                    let (frozen, tail) = eng.live(); seen = frozen.count
                    await MainActor.run { self.lines = frozen + tail; self.status = String(format: "Enregistrement %.0f s", eng.fedSeconds) }
                }
                let final = eng.finish() ?? []
                let secs = eng.fedSeconds
                await MainActor.run { self.lines = final; self.status = "Terminé" }
                await self.archive(lines: final, notes: [], title: "", summary: "", seconds: secs)
            }
        }
    }
    /// Dev override (VOX_BASE, simulator only) else the downloaded copy in Application Support.
    nonisolated func modelPath(_ n: String, _ b: String) -> String {
        if ProcessInfo.processInfo.environment["VOX_BASE"] != nil { return "\(b)/models/\(n)" }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("models/nemo/\(n)").path
    }
    func downloadSpeech() async -> Bool {
        if ProcessInfo.processInfo.environment["VOX_BASE"] != nil { return true }
        if await store.isComplete(.speech) { return true }
        do {
            try await store.download(.speech) { d, t in Task { @MainActor in self.status = String(format: "Modèles de transcription %.0f / %.0f Mo", Double(d) / 1e6, Double(t) / 1e6) } }
            return true
        } catch { status = "Téléchargement : \(error)"; return false }
    }
    func downloadReader() {
        status = "Téléchargement du lecteur…"
        Task.detached { [store] in
            do {
                try await store.download(.e2b) { d, t in Task { @MainActor in self.status = String(format: "Lecteur %.0f / %.0f Mo", Double(d) / 1e6, Double(t) / 1e6) } }
                await MainActor.run { self.status = "Lecteur prêt" }
            } catch { await MainActor.run { self.status = "Téléchargement : \(error)" } }
        }
    }

    /// Transcribe + read a source of 16 kHz mono chunks (a file, the bundled sample). `feed` pushes chunks until done or false.
    func process(seconds: Double, feed: @escaping @Sendable (([Float]) -> Bool) throws -> Void) {
        status = "Chargement des modèles…"; lines = []; notes = []; title = ""; summary = ""
        let b = base
        Task.detached {
            guard await self.downloadSpeech(),
                  let eng = NemoEngine(xasr: self.modelPath("x-asr-zh-en-q8_0.gguf", b), diar: self.modelPath("nemotron-3-diarization-q8_0.gguf", b)) else {
                await MainActor.run { self.status = "Échec chargement" }; return }
            let stored = await self.store.isComplete(.e2b) ? await self.store.dir(.e2b).path : nil
            let r = ReaderFactory.make(dir: ProcessInfo.processInfo.environment["VOX_READER_DIR"] ?? stored)
            let reader = MeetingReader(llm: r.llm, systemPrompt: r.systemPrompt, budget: .mobile)
            do { try reader.start() } catch { await MainActor.run { self.status = "Lecteur : \(error)" }; return }
            var seenFrozen = 0
            do {
                try feed { chunk in
                    _ = eng.push(chunk)
                    let (frozen, tail) = eng.live()
                    for u in frozen.dropFirst(seenFrozen) { if let l = ReaderSummarizer.toLine(u) { try? reader.offer(l) } }
                    seenFrozen = frozen.count
                    let j = reader.journal, fed = eng.fedSeconds
                    Task { @MainActor in
                        self.lines = frozen + tail; self.notes = j
                        self.status = String(format: "Transcription %.0f s / %.0f s", fed, seconds)
                    }
                    return true
                }
            } catch { await MainActor.run { self.status = "Audio : \(error.localizedDescription)" }; return }
            let final = eng.finish() ?? []
            _ = try? reader.finish(); let journal = reader.journal
            let sum = ReaderSummarizer(llm: r.llm)
            let t = sum.title(journal), prose = sum.prose(journal) ?? ReaderProtocol.minutes(journal)
            await MainActor.run { self.lines = final; self.notes = journal; self.title = t ?? ""; self.summary = prose; self.status = "Terminé" }
            await self.archive(lines: final, notes: journal, title: t ?? "", summary: prose, seconds: seconds)
        }
    }

    func run() {
        guard let pcm = loadWav("\(base)/clips/diar_ref_2spk_123s.wav") else { status = "Exemple absent"; return }
        process(seconds: Double(pcm.count) / 16000) { sink in
            for s in stride(from: 0, to: pcm.count, by: 16000) { if !sink(Array(pcm[s..<min(pcm.count, s + 16000)])) { return } }
        }
    }

    func importAudio(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        guard let secs = AudioDecode.duration(url) else { if scoped { url.stopAccessingSecurityScopedResource() }; status = "Fichier audio illisible"; return }
        process(seconds: secs) { sink in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try AudioDecode.stream(url, onChunk: sink)
        }
    }
}

struct ContentView: View {
    @StateObject var m = Model()
    @State private var picking = false
    var body: some View {
        NavigationStack {
            List {
                if !m.sessions.isEmpty {
                    Section("Bibliothèque") {
                        ForEach(m.sessions) { x in
                            Button { m.open(x) } label: {
                                VStack(alignment: .leading) {
                                    Text(x.title).font(.headline)
                                    Text("\(x.date.formatted(date: .abbreviated, time: .shortened)) · \(Int(x.seconds)) s").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions { Button("Supprimer", role: .destructive) { m.remove(x) } }
                        }
                    }
                }
                if !m.summary.isEmpty { Section(m.title.isEmpty ? "Résumé" : m.title) { Text(m.summary) } }
                if !m.notes.isEmpty { Section("Agent") { ForEach(m.notes) { Text(ReaderProtocol.render($0)).font(.caption) } } }
                Section("Transcription") {
                    ForEach(m.lines) { l in
                        VStack(alignment: .leading) {
                            Text("Locuteur \(l.speaker + 1) · \(Int(l.start)) s").font(.caption2).foregroundStyle(.secondary)
                            Text(l.text)
                        }
                    }
                }
            }
            .navigationTitle("VoxSum")
            .onAppear { m.reload(); if let d = ProcessInfo.processInfo.environment["VOX_DOWNLOAD"] { if d == "speech" { Task { _ = await m.downloadSpeech() } } else { m.downloadReader() } }; if ProcessInfo.processInfo.environment["VOX_AUTORUN"] != nil { m.run() }; if let f = ProcessInfo.processInfo.environment["VOX_IMPORT"] { m.importAudio(URL(fileURLWithPath: f)) } }
            .toolbar {
                ToolbarItem(placement: .bottomBar) { Button("Transcrire l'exemple") { m.run() } }
                ToolbarItem(placement: .bottomBar) { Button("Importer") { picking = true } }
                ToolbarItem(placement: .bottomBar) { Button("Lecteur") { m.downloadReader() } }
                ToolbarItem(placement: .bottomBar) { Button(m.recording ? "Stop" : "Micro") { m.toggleRecord() } }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.audio]) { if case .success(let u) = $0 { m.importAudio(u) } }
            .safeAreaInset(edge: .bottom) { Text(m.status).font(.footnote).padding(4) }
        }
    }
}
