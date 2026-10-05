import Foundation

/// Mirror of Android's `ReaderLlm`: the meeting reader sees the stable transcript and emits notes.
protocol ReaderLlm {
    /// `transcript` = stable lines so far; returns the note lines the agent wrote for this window.
    func read(window: [String]) async -> [String]
    /// Prose summary written from the notes.
    func prose(notes: [String]) async -> String
}

/// Placeholder until LiteRT-LM (iPhone-only xcframework) is linked.
struct StubReader: ReaderLlm {
    func read(window: [String]) async -> [String] {
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let last = window.last else { return [] }
        return ["[stub] \(last.prefix(60))"]
    }
    func prose(notes: [String]) async -> String {
        "[stub] \(notes.count) notes — real reader runs on device."
    }
}
