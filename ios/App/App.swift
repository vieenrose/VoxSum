import SwiftUI

@main struct VoxSumApp: App { var body: some Scene { WindowGroup { ContentView() } } }

@MainActor final class Model: ObservableObject {
    @Published var lines: [Utterance] = []
    @Published var notes: [Note] = []
    @Published var title = ""
    @Published var summary = ""
    @Published var status = "Prêt"
    // Dev paths on the Mac (the simulator shares its filesystem).
    let base = ProcessInfo.processInfo.environment["VOX_BASE"] ?? "/Users/Pesi/work"

    let store = ModelStore()
    func downloadReader() {
        status = "Téléchargement du lecteur…"
        Task.detached { [store] in
            do {
                try await store.download(.e2b) { d, t in Task { @MainActor in self.status = String(format: "Lecteur %.0f / %.0f Mo", Double(d) / 1e6, Double(t) / 1e6) } }
                await MainActor.run { self.status = "Lecteur prêt" }
            } catch { await MainActor.run { self.status = "Téléchargement : \(error)" } }
        }
    }

    func run() {
        status = "Chargement des modèles…"; lines = []; notes = []; title = ""; summary = ""
        let b = base
        Task.detached {
            guard let eng = NemoEngine(xasr: "\(b)/models/x-asr-zh-en-q8_0.gguf", diar: "\(b)/models/nemotron-3-diarization-q8_0.gguf"),
                  let pcm = loadWav("\(b)/clips/diar_ref_2spk_123s.wav") else {
                await MainActor.run { self.status = "Échec chargement" }; return }
            let stored = await self.store.isComplete(.e2b) ? await self.store.dir(.e2b).path : nil
            let r = ReaderFactory.make(dir: ProcessInfo.processInfo.environment["VOX_READER_DIR"] ?? stored)
            let reader = MeetingReader(llm: r.llm, systemPrompt: r.systemPrompt, budget: .mobile)
            do { try reader.start() } catch { await MainActor.run { self.status = "Lecteur : \(error)" }; return }
            var seenFrozen = 0
            for s in stride(from: 0, to: pcm.count, by: 16000) {
                _ = eng.push(Array(pcm[s..<min(pcm.count, s + 16000)]))
                let (frozen, tail) = eng.live()
                for u in frozen.dropFirst(seenFrozen) { if let l = ReaderSummarizer.toLine(u) { try? reader.offer(l) } }
                seenFrozen = frozen.count
                let j = reader.journal
                await MainActor.run {
                    self.lines = frozen + tail; self.notes = j
                    self.status = String(format: "ASR %.0f s / %.0f s", eng.fedSeconds, Double(pcm.count) / 16000)
                }
            }
            let final = eng.finish() ?? []
            _ = try? reader.finish(); let journal = reader.journal
            let sum = ReaderSummarizer(llm: r.llm)
            let t = sum.title(journal), prose = sum.prose(journal) ?? ReaderProtocol.minutes(journal)
            await MainActor.run { self.lines = final; self.notes = journal; self.title = t ?? ""; self.summary = prose; self.status = "Terminé" }
        }
    }
}

struct ContentView: View {
    @StateObject var m = Model()
    var body: some View {
        NavigationStack {
            List {
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
            .onAppear { if ProcessInfo.processInfo.environment["VOX_AUTORUN"] != nil { m.run() } }
            .toolbar {
                ToolbarItem(placement: .bottomBar) { Button("Transcrire l'exemple") { m.run() } }
                ToolbarItem(placement: .bottomBar) { Button("Lecteur") { m.downloadReader() } }
            }
            .safeAreaInset(edge: .bottom) { Text(m.status).font(.footnote).padding(4) }
        }
    }
}
