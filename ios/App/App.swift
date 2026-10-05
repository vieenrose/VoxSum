import SwiftUI

@main struct VoxSumApp: App { var body: some Scene { WindowGroup { ContentView() } } }

@MainActor final class Model: ObservableObject {
    @Published var lines: [Line] = []
    @Published var notes: [String] = []
    @Published var summary = ""
    @Published var status = "Prêt"
    let reader: ReaderLlm = StubReader()
    // Dev paths on the Mac (the simulator shares its filesystem).
    let base = ProcessInfo.processInfo.environment["VOX_BASE"] ?? "/Users/Pesi/work"

    func run() {
        status = "Chargement des modèles…"; lines = []; notes = []; summary = ""
        let b = base
        Task.detached { [reader] in
            guard let eng = NemoEngine(xasr: "\(b)/models/x-asr-zh-en-q8_0.gguf", diar: "\(b)/models/nemotron-3-diarization-q8_0.gguf"),
                  let pcm = loadWav("\(b)/clips/diar_ref_2spk_123s.wav") else {
                await MainActor.run { self.status = "Échec chargement" }; return }
            let chunk = 16000
            var seenFrozen = 0
            for s in stride(from: 0, to: pcm.count, by: chunk) {
                _ = eng.push(Array(pcm[s..<min(pcm.count, s + chunk)]))
                let (frozen, tail) = eng.live()
                let fresh = Array(frozen.dropFirst(seenFrozen)); seenFrozen = frozen.count
                let notes = fresh.isEmpty ? [] : await reader.read(window: fresh.map(\.text))
                await MainActor.run {
                    self.lines = frozen + tail; self.notes += notes
                    self.status = String(format: "ASR %.0f s / %.0f s", eng.fedSeconds, Double(pcm.count) / 16000)
                }
            }
            let final = eng.finish() ?? []
            let prose = await reader.prose(notes: await MainActor.run { self.notes })
            await MainActor.run { self.lines = final; self.summary = prose; self.status = "Terminé" }
        }
    }
}

struct ContentView: View {
    @StateObject var m = Model()
    var body: some View {
        NavigationStack {
            List {
                if !m.summary.isEmpty { Section("Résumé") { Text(m.summary) } }
                if !m.notes.isEmpty { Section("Agent") { ForEach(m.notes, id: \.self) { Text($0).font(.caption) } } }
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
            .toolbar { ToolbarItem(placement: .bottomBar) { Button("Transcrire l'exemple") { m.run() } } }
            .safeAreaInset(edge: .bottom) { Text(m.status).font(.footnote).padding(4) }
        }
    }
}
