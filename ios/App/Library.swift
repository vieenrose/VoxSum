import Foundation

/// One finished (or stopped) meeting, saved as `<id>.json`.
struct Session: Identifiable, Codable, Hashable {
    var id = UUID()
    var date = Date()
    var title: String
    var summary: String
    var seconds: Double
    var lines: [Utterance]
    var notes: [Note]
    static func == (a: Session, b: Session) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// The meeting library: one JSON file per session in Application Support/sessions.
actor LibraryStore {
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("sessions")) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func file(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }

    /// Newest first; an unreadable file is skipped, not fatal.
    func all() -> [Session] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Session.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }
    func save(_ s: Session) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(s).write(to: file(s.id), options: .atomic)   // atomic: a crash never leaves half a file
    }
    func delete(_ id: UUID) { try? FileManager.default.removeItem(at: file(id)) }
}
