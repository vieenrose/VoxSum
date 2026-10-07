import SwiftUI
import UserNotifications
import os

@main struct VoxSumApp: App { var body: some Scene { WindowGroup { ContentView() } } }

/// Mic chunks arrive on the audio thread, the engine loop drains them on another.
final class ChunkBuffer: @unchecked Sendable {
    private var data: [Float] = []; private let lock = NSLock()
    func add(_ c: [Float]) { lock.lock(); data += c; lock.unlock() }
    func take() -> [Float] { lock.lock(); defer { lock.unlock() }; let d = data; data = []; return d }
}

/// Local notification when a meeting is ready (Android posts one from its foreground service).
enum Notifier {
    static func requestPermission() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    static func done(_ title: String) {
        let c = UNMutableNotificationContent(); c.title = L("notif_ready"); c.body = title; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// Every status line, timestamped, in Documents/status.log (pullable with devicectl: the console is not always attached).
enum StatusLog {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("status.log")
    private static let q = DispatchQueue(label: "statuslog", qos: .utility)   // never block the app on file I/O (a stalled devicectl copy held the file)
    nonisolated(unsafe) private static var lastKey = "", lastAt = Date.distantPast
    static func add(_ s: String) {
        let now = Date()
        q.async {
            // progress lines ("轉錄中 12 / 300 秒") differ only by digits: keep one every 15 s
            let key = String(s.filter { !$0.isNumber })
            if key == lastKey && now.timeIntervalSince(lastAt) < 15 { return }
            lastKey = key; lastAt = now
            if let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, n > 1_000_000 { try? FileManager.default.removeItem(at: url) }
            guard let d = (ISO8601DateFormatter().string(from: now) + " " + s + "\n").data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: d) } else { try? d.write(to: url) }
        }
    }
}

/// Debug watchdog: logs the engine stage when it has not changed for 60 s (a hung call shows up in status.log).
enum Stage {
    nonisolated(unsafe) static var name = "idle"; nonisolated(unsafe) static var since = Date()
    static func set(_ n: String) { name = n; since = Date() }
    static let watchdog: Void = { Thread.detachNewThread { while true { Thread.sleep(forTimeInterval: 60)
        let d = Int(Date().timeIntervalSince(since)); if name != "idle" && d >= 60 { StatusLog.add("trace stage \(name) stuck \(d) s, \(os_proc_available_memory() / 1_048_576) MB free") } } } }()
}

/// Runs the reader on its own thread: on slow CPUs (A12: ~12 tok/s prefill) a reader call takes 1-2 min, and inline it
/// would throttle the transcription. Lines queue up; the reader catches up behind the ASR and after it.
final class ReaderWorker: @unchecked Sendable {
    private let reader: MeetingReader, lock = NSCondition()
    private var queue: [Line] = [], busy = false, paused = false, snapshot: [Note] = [], total = 0, done = 0
    /// `paused`: hold the lines until `resume()` (low-RAM devices read after the transcription, not during it).
    init(_ r: MeetingReader, paused: Bool = false) {
        reader = r; self.paused = paused
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); while queue.isEmpty || paused { busy = false; lock.broadcast(); lock.wait() }
                let l = queue.removeFirst(); busy = true; lock.unlock()
                Stage.set("offer")
                do { try reader.offer(l) } catch { StatusLog.add("trace reader.offer error: \(error)") }
                lock.lock(); snapshot = reader.journal; done += 1; lock.unlock()
            }
        }
    }
    func offer(_ l: Line) { lock.lock(); queue.append(l); total += 1; lock.broadcast(); lock.unlock() }
    func resume() { lock.lock(); paused = false; lock.broadcast(); lock.unlock() }
    var journal: [Note] { lock.lock(); defer { lock.unlock() }; return snapshot }
    var progress: (done: Int, total: Int) { lock.lock(); defer { lock.unlock() }; return (done, total) }
    /// Blocks until every queued line has been read.
    func drain(_ tick: (Int, Int) -> Void) {
        lock.lock()
        while !queue.isEmpty || busy { lock.broadcast(); lock.wait(until: Date().addingTimeInterval(2)); let p = (done, total); lock.unlock(); tick(p.0, p.1); lock.lock() }
        lock.unlock()
    }
}

@MainActor final class Model: ObservableObject {
    @Published var lines: [Utterance] = []
    @Published var notes: [Note] = []
    @Published var title = ""
    @Published var summary = ""
    @Published var status = L("app_ready") { didSet { StatusLog.add(status) } }
    // Dev paths on the Mac (the simulator shares its filesystem).
    let base = ProcessInfo.processInfo.environment["VOX_BASE"] ?? "/Users/Pesi/work"

    let store = ModelStore()
    let library = LibraryStore()
    @Published var sessions: [Session] = []
    func reload() { Task { sessions = await library.all() } }
    func update(_ s: Session) { Task { try? await library.save(s); sessions = await library.all() } }
    func remove(_ s: Session) { Task { await library.delete(s.id); sessions = await library.all() } }
    func open(_ s: Session) { lines = s.lines; notes = s.notes; title = s.title; summary = s.summary; status = L("archive_of", s.date.formatted(date: .abbreviated, time: .shortened)) }
    private func archive(lines: [Utterance], notes: [Note], title: String, summary: String, seconds: Double, job: Job? = nil) async {
        guard !lines.isEmpty else { return }
        let fallback = lines.first.map { String($0.text.prefix(20)) } ?? L("meeting")
        var s = Session(title: title.isEmpty ? fallback : title, summary: summary, seconds: seconds, lines: lines, notes: notes)
        if let job { s.id = job.id; s.date = job.date; s.audio = job.audio; if let t = job.title, !t.isEmpty { s.title = t } }
        try? await library.save(s)
        sessions = await library.all()
        Notifier.done(s.title)
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
            let r = Recorder(); recorder = r; recording = true; UIApplication.shared.isIdleTimerDisabled = true
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
            var seenFrozen = 0; let conv = TextConv(); let lowRam = ProcessInfo.processInfo.physicalMemory < 4_500_000_000   // 3 GB phones cannot hold ASR + diarizer + E2B at once
            let worker = ReaderWorker(reader, paused: lowRam)
            do {
                try feed { chunk in
                    _ = Stage.watchdog; Stage.set("push")
                    if !eng.push(chunk) { StatusLog.add("trace push failed at \(Int(eng.fedSeconds)) s") }
                    let (frozen, tail) = eng.live()
                    for u in frozen.dropFirst(seenFrozen) { if let l = ReaderSummarizer.toLine(u) { worker.offer(l) } }
                    seenFrozen = frozen.count
                    let j = worker.journal, fed = eng.fedSeconds
                    Task { @MainActor in
                        self.lines = conv.utterances(frozen + tail); self.notes = conv.notes(j)
                        self.status = L("transcribing_s", Int(fed), Int(seconds))
                    }
                    Stage.set("idle")
                    return true
                }
            } catch { await MainActor.run { self.status = L("audio_error", error.localizedDescription) }; return }
            Stage.set("finish")
            let final = eng.finish() ?? []
            if lowRam { eng.close(); StatusLog.add("trace models freed, reader starts (\(os_proc_available_memory() / 1_048_576) MB free)"); worker.resume() }
            worker.drain { d, t in Task { @MainActor in self.status = L("reading_s", d, t) } }
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
        guard let pcm = loadWav(Bundle.main.path(forResource: "sample", ofType: "wav") ?? "\(base)/clips/diar_ref_2spk_123s.wav") else { status = L("sample_missing"); return }
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
        UIApplication.shared.isIdleTimerDisabled = true   // iOS suspends a locked app: stay awake while the queue works (Android: wake lock)
        Notifier.requestPermission()
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
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Podcast episode: download into the audio directory, then queue it like any import.
    @Published var downloading: String?
    func addEpisode(_ ep: Episode) {
        guard downloading == nil else { return }
        let j = Job(audio: UUID().uuidString + "." + Podcast.ext(ep.audioUrl), title: ep.title)
        downloading = ep.title; status = L("podcast_downloading", 0)
        Task {
            defer { downloading = nil }
            do {
                _ = try await Podcast.download(ep, name: j.audio) { f in Task { @MainActor in self.status = L("podcast_downloading", Int(f * 100)) } }
                await queue.add(j); drain()
            } catch { status = L("download_failed", error.localizedDescription) }
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
    @State private var showPodcast = false
    @State private var path: [Session] = []
    @AppStorage("language") private var language = "system"
    @AppStorage("theme") private var theme = "auto"
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !m.sessions.isEmpty {
                    Section(L("library")) {
                        ForEach(m.sessions) { x in
                            NavigationLink(value: x) {
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
            .navigationDestination(for: Session.self) { x in SessionView(session: m.sessions.first { $0.id == x.id } ?? x) { m.update($0) } }
            .onAppear { m.reload(); if ProcessInfo.processInfo.environment["VOX_OPEN"] != nil { Task { path = await m.library.all().prefix(1).map { $0 } } }; if let d = ProcessInfo.processInfo.environment["VOX_DOWNLOAD"] { if d == "speech" { Task { _ = await m.downloadSpeech() } } else { m.downloadReader() } }; if ProcessInfo.processInfo.environment["VOX_AUTORUN"] != nil { m.run() }; m.drain(); if let f = ProcessInfo.processInfo.environment["VOX_IMPORT"] { m.importAudio(URL(fileURLWithPath: f.hasPrefix("/") ? f : NSHomeDirectory() + "/" + f)) }; if let q = ProcessInfo.processInfo.environment["VOX_PODCAST"] { Task { if let sr = try? await Podcast.search(q).first, let ep = try? await Podcast.episodes(sr.feedUrl, limit: 3).last { m.addEpisode(ep) } else { m.status = "podcast: no result" } } } }
            .toolbar {
                ToolbarItem(placement: .bottomBar) { Button(L("settings")) { showSettings = true } }
                ToolbarItem(placement: .bottomBar) { Button(L("sample")) { m.run() } }
                ToolbarItem(placement: .bottomBar) { Menu(L("import_audio")) { Button(L("from_files")) { picking = true }; Button(L("podcast")) { showPodcast = true } } }
                ToolbarItem(placement: .bottomBar) { Button(L("download_reader")) { m.downloadReader() } }
                ToolbarItem(placement: .bottomBar) { Button(m.recording ? L("stop") : L("record")) { m.toggleRecord() } }
            }
            .sheet(isPresented: $showPodcast) { PodcastView { m.addEpisode($0) } }
            .sheet(isPresented: $showSettings) { SettingsView(language: $language, theme: $theme) }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.audio]) { if case .success(let u) = $0 { m.importAudio(u) } }
            .safeAreaInset(edge: .bottom) { Text(m.status).font(.footnote).padding(4) }
        }
        .preferredColorScheme((Theme(rawValue: theme) ?? .auto).scheme)
    }
}

struct SettingsView: View {
    @Binding var language: String
    @Binding var theme: String
    @State private var models = Storage.models()
    @State private var threads = Prefs.threads
    @State private var reader = Prefs.readerId
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section { Picker(L("language"), selection: $language) { ForEach(AppLanguage.allCases) { Text($0.autonym).tag($0.rawValue) } } }
                footer: { Text(L("settings_language_note")) }
                Section(L("theme")) { Picker(L("theme"), selection: $theme) { ForEach(Theme.allCases) { Text($0.label).tag($0.rawValue) } }.pickerStyle(.segmented) }
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
                if !models.isEmpty {
                    Section(L("storage")) {
                        ForEach(models) { i in
                            HStack { Text(i.name); Spacer(); Text(ByteCountFormatter.string(fromByteCount: i.bytes, countStyle: .file)).foregroundStyle(.secondary) }
                                .swipeActions { Button(L("delete"), role: .destructive) { Storage.delete(i); models = Storage.models() } }
                        }
                    }
                }
            }
            .navigationTitle(L("settings"))
            .toolbar { Button(L("done")) { dismiss() } }
        }
    }
}

struct PodcastView: View {
    let pick: (Episode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var series: [PodcastSeries] = []
    @State private var episodes: [Episode] = []
    @State private var current: PodcastSeries?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                if current == nil {
                    ForEach(series) { s in
                        Button { open(s) } label: {
                            VStack(alignment: .leading) { Text(s.title).font(.headline); Text(s.artist).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } else {
                    ForEach(episodes) { e in
                        Button { pick(e); dismiss() } label: {
                            VStack(alignment: .leading) {
                                Text(e.title)
                                Text([e.duration, String(e.published.prefix(16))].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if busy { ProgressView() }
            }
            .navigationTitle(current?.title ?? L("podcast"))
            .searchable(text: $query, prompt: L("podcast_search"))
            .onSubmit(of: .search) { search() }
            .toolbar {
                if current != nil { ToolbarItem(placement: .navigation) { Button(L("back")) { current = nil; episodes = [] } } }
                ToolbarItem { Button(L("done")) { dismiss() } }
            }
        }
    }
    private func search() {
        busy = true; error = nil; current = nil
        Task { defer { busy = false }; do { series = try await Podcast.search(query) } catch { self.error = error.localizedDescription } }
    }
    private func open(_ s: PodcastSeries) {
        busy = true; error = nil; current = s
        Task { defer { busy = false }; do { episodes = try await Podcast.episodes(s.feedUrl) } catch { self.error = error.localizedDescription } }
    }
}
