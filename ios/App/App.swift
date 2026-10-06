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
    @Published var status = L("app_ready")
    // Dev paths on the Mac (the simulator shares its filesystem).
    let base = ProcessInfo.processInfo.environment["VOX_BASE"] ?? "/Users/Pesi/work"

    let store = ModelStore()
    let library = LibraryStore()
    @Published var sessions: [Session] = []
    func reload() { Task { sessions = await library.all() } }
    func remove(_ s: Session) { Task { await library.delete(s.id); sessions = await library.all() } }
    func open(_ s: Session) { lines = s.lines; notes = s.notes; title = s.title; summary = s.summary; status = L("archive_of", s.date.formatted(date: .abbreviated, time: .shortened)) }
    private func archive(lines: [Utterance], notes: [Note], title: String, summary: String, seconds: Double, job: Job? = nil) async {
        guard !lines.isEmpty else { return }
        let fallback = lines.first.map { String($0.text.prefix(20)) } ?? L("meeting")
        var s = Session(title: title.isEmpty ? fallback : title, summary: summary, seconds: seconds, lines: lines, notes: notes)
        if let job { s.id = job.id; s.date = job.date; s.audio = job.audio }
        try? await library.save(s)
        sessions = await library.all()
    }
    @Published var recording = false
    private var recorder: Recorder?
    private let buffer = ChunkBuffer()

    func toggleRecord() {
        if recording { recorder?.stop(); recorder = nil; recording = false; status = L("stopping"); return }
        Task {
            guard await Recorder.requestPermission() else { status = L("mic_denied"); return }
            guard await downloadSpeech() else { return }
            status = L("loading_models"); lines = []; notes = []; title = ""; summary = ""
            let r = Recorder(); recorder = r; recording = true
            let job = Job(audio: UUID().uuidString + ".wav")
            guard let wav = try? WavWriter(JobQueue.url(job)) else { recording = false; return }
            recordingJob = job.id
            await queue.add(job)       // on the list before the first sample: a kill mid-recording keeps the audio
            let b = base
            Task.detached { [weak self] in
                guard let self, let eng = NemoEngine(xasr: self.modelPath("x-asr-zh-en-q8_0.gguf", b), diar: self.modelPath("nemotron-3-diarization-q8_0.gguf", b), threads: Prefs.effectiveThreads) else {
                    await MainActor.run { self?.status = L("models_missing"); self?.recording = false }; return }
                do { try r.start { [buffer = self.buffer] c in wav.append(c); buffer.add(c) } }
                catch { await MainActor.run { self.status = L("mic_error", "\(error)"); self.recording = false }; return }
                var seen = 0; let conv = TextConv()
                while await MainActor.run(body: { self.recording }) {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let chunk = self.buffer.take()
                    if !chunk.isEmpty { _ = eng.push(chunk) }
                    let (frozen, tail) = eng.live(); seen = frozen.count
                    await MainActor.run { self.lines = conv.utterances(frozen + tail); self.status = L("recording_s", Int(eng.fedSeconds)) }
                }
                wav.finish()
                await MainActor.run { self.recordingJob = nil }
                await MainActor.run { self.drain() }   // full pipeline (diarization settled + notes) from the saved audio
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
            try await store.download(.speech) { d, t in Task { @MainActor in self.status = L("download_speech", Int(d / 1_000_000), Int(t / 1_000_000)) } }
            return true
        } catch { status = L("download_failed", "\(error)"); return false }
    }
    func downloadReader() {
        status = L("download_reader")
        Task.detached { [store] in
            do {
                try await store.download(Prefs.reader) { d, t in Task { @MainActor in self.status = L("download_reader_p", Int(d / 1_000_000), Int(t / 1_000_000)) } }
                await MainActor.run { self.status = L("reader_ready") }
            } catch { await MainActor.run { self.status = L("download_failed", "\(error)") } }
        }
    }

    /// Transcribe + read a source of 16 kHz mono chunks (a file, the bundled sample). `feed` pushes chunks until done or false.
    func process(seconds: Double, job: Job? = nil, feed: @escaping @Sendable (([Float]) -> Bool) throws -> Void) async {
        status = L("loading_models"); lines = []; notes = []; title = ""; summary = ""
        let b = base
        await Task.detached {
            guard await self.downloadSpeech(),
                  let eng = NemoEngine(xasr: self.modelPath("x-asr-zh-en-q8_0.gguf", b), diar: self.modelPath("nemotron-3-diarization-q8_0.gguf", b), threads: Prefs.effectiveThreads) else {
                await MainActor.run { self.status = L("load_failed") }; return }
            let rm = Prefs.reader
            let stored = await self.store.isComplete(rm) ? await self.store.dir(rm).path : nil
            let r = ReaderFactory.make(dir: ProcessInfo.processInfo.environment["VOX_READER_DIR"] ?? stored)
            let reader = MeetingReader(llm: r.llm, systemPrompt: r.systemPrompt, budget: .mobile)
            do { try reader.start() } catch { await MainActor.run { self.status = L("reader_error", "\(error)") }; return }
            var seenFrozen = 0; let conv = TextConv()
            do {
                try feed { chunk in
                    _ = eng.push(chunk)
                    let (frozen, tail) = eng.live()
                    for u in frozen.dropFirst(seenFrozen) { if let l = ReaderSummarizer.toLine(u) { try? reader.offer(l) } }
                    seenFrozen = frozen.count
                    let j = reader.journal, fed = eng.fedSeconds
                    Task { @MainActor in
                        self.lines = conv.utterances(frozen + tail); self.notes = conv.notes(j)
                        self.status = L("transcribing_s", Int(fed), Int(seconds))
                    }
                    return true
                }
            } catch { await MainActor.run { self.status = L("audio_error", error.localizedDescription) }; return }
            let final = eng.finish() ?? []
            _ = try? reader.finish(); let journal = reader.journal
            let sum = ReaderSummarizer(llm: r.llm)
            let t = sum.title(journal), prose = sum.prose(journal) ?? ReaderProtocol.minutes(journal)
            let (fl, fn, ft, fp) = (conv.utterances(final), conv.notes(journal), conv.text(t ?? ""), conv.text(prose))
            await MainActor.run { self.lines = fl; self.notes = fn; self.title = ft; self.summary = fp; self.status = L("finished") }
            await self.archive(lines: fl, notes: fn, title: ft, summary: fp, seconds: seconds, job: job)
            if let job { await self.queue.remove(job.id) }
        }.value
    }

    func run() {
        guard let pcm = loadWav("\(base)/clips/diar_ref_2spk_123s.wav") else { status = L("sample_missing"); return }
        Task { await process(seconds: Double(pcm.count) / 16000) { sink in
            for s in stride(from: 0, to: pcm.count, by: 16000) { if !sink(Array(pcm[s..<min(pcm.count, s + 16000)])) { return } }
        } }
    }

    // MARK: processing queue
    let queue = JobQueue()
    private var draining = false
    private var recordingJob: UUID?   // being recorded: not for the queue yet
    /// Processes every queued job in order (also at launch: recordings cut short by a kill are picked up here).
    func drain() {
        guard !draining else { return }
        draining = true
        Task {
            while let job = await queue.first(skipping: recordingJob) {
                let url = JobQueue.url(job)
                WavWriter.repair(url)
                guard let secs = AudioDecode.duration(url), secs > 0 else { await queue.remove(job.id); continue }
                let left = await queue.count
                if left > 1 { status = L("queue_n", left) }
                await process(seconds: secs, job: job) { sink in try AudioDecode.stream(url, onChunk: sink) }
                if await queue.first(skipping: recordingJob)?.id == job.id { await queue.remove(job.id) }   // failed run: never loop on it
            }
            draining = false
        }
    }

    func importAudio(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let j = Job(audio: UUID().uuidString + "." + (url.pathExtension.isEmpty ? "m4a" : url.pathExtension))
        do { try FileManager.default.copyItem(at: url, to: JobQueue.url(j)) } catch { status = L("audio_unreadable"); return }
        Task { await queue.add(j); drain() }
    }
}

struct ContentView: View {
    @StateObject var m = Model()
    @State private var picking = false
    @State private var showSettings = false
    @AppStorage("language") private var language = "system"
    var body: some View {
        NavigationStack {
            List {
                if !m.sessions.isEmpty {
                    Section(L("library")) {
                        ForEach(m.sessions) { x in
                            Button { m.open(x) } label: {
                                VStack(alignment: .leading) {
                                    Text(x.title).font(.headline)
                                    Text(L("session_meta", x.date.formatted(date: .abbreviated, time: .shortened), Int(x.seconds))).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions { Button(L("delete"), role: .destructive) { m.remove(x) } }
                        }
                    }
                }
                if !m.summary.isEmpty { Section(m.title.isEmpty ? L("summary") : m.title) { Text(m.summary) } }
                if !m.notes.isEmpty { Section(L("agent")) { ForEach(m.notes) { Text(ReaderProtocol.render($0)).font(.caption) } } }
                Section(L("transcript")) {
                    ForEach(m.lines) { l in
                        VStack(alignment: .leading) {
                            Text(L("speaker_at", l.speaker + 1, Int(l.start))).font(.caption2).foregroundStyle(.secondary)
                            Text(l.text)
                        }
                    }
                }
            }
            .navigationTitle("VoxSum")
            .onAppear { m.reload(); if let d = ProcessInfo.processInfo.environment["VOX_DOWNLOAD"] { if d == "speech" { Task { _ = await m.downloadSpeech() } } else { m.downloadReader() } }; if ProcessInfo.processInfo.environment["VOX_AUTORUN"] != nil { m.run() }; m.drain(); if let f = ProcessInfo.processInfo.environment["VOX_IMPORT"] { m.importAudio(URL(fileURLWithPath: f)) } }
            .toolbar {
                ToolbarItem(placement: .bottomBar) { Button(L("settings")) { showSettings = true } }
                ToolbarItem(placement: .bottomBar) { Button(L("sample")) { m.run() } }
                ToolbarItem(placement: .bottomBar) { Button(L("import_audio")) { picking = true } }
                ToolbarItem(placement: .bottomBar) { Button(L("download_reader")) { m.downloadReader() } }
                ToolbarItem(placement: .bottomBar) { Button(m.recording ? L("stop") : L("record")) { m.toggleRecord() } }
            }
            .sheet(isPresented: $showSettings) { SettingsView(language: $language) }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.audio]) { if case .success(let u) = $0 { m.importAudio(u) } }
            .safeAreaInset(edge: .bottom) { Text(m.status).font(.footnote).padding(4) }
        }
    }
}

struct SettingsView: View {
    @Binding var language: String
    @State private var threads = Prefs.threads
    @State private var reader = Prefs.readerId
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section { Picker(L("language"), selection: $language) { ForEach(AppLanguage.allCases) { Text($0.autonym).tag($0.rawValue) } } }
                footer: { Text(L("settings_language_note")) }
                Section(L("notes_model")) {
                    Picker(L("notes_model"), selection: $reader) {
                        Text("Gemma 4 E2B · 2.2 GB").tag("E2B")
                        if Prefs.e4bAllowed { Text("Gemma 4 E4B · 3.3 GB").tag("E4B") }
                    }.pickerStyle(.inline).labelsHidden()
                    .onChange(of: reader) { Prefs.readerId = reader }
                }
                Section {
                    Toggle(L("threads_auto"), isOn: Binding(get: { threads == 0 }, set: { threads = $0 ? 0 : Prefs.effectiveThreads; Prefs.threads = threads }))
                    if threads > 0 {
                        Stepper(L("threads_n", threads), value: Binding(get: { threads }, set: { threads = $0; Prefs.threads = $0 }), in: 2...max(2, Prefs.cores))
                    }
                } header: { Text(L("threads")) } footer: { Text(L("threads_note", Prefs.effectiveThreads, Prefs.cores)) }
            }
            .navigationTitle(L("settings"))
            .toolbar { Button(L("done")) { dismiss() } }
        }
    }
}
