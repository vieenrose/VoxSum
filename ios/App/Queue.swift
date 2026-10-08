import Foundation

/// A recording or import waiting for the full pipeline (ASR + diarization + reader). Port of the Android persistent
/// processing queue: the audio is on disk before anything else happens, the job list survives an app kill, and a job
/// leaves the list only once its session is saved.
struct Job: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var audio: String        // file name in Application Support/audio
    var title: String? = nil // source title (podcast episode) — wins over a generated one
}

actor JobQueue {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let audioDir = support.appendingPathComponent("audio")
    private let file = support.appendingPathComponent("jobs.json")
    private(set) var jobs: [Job] = []

    init() {
        try? FileManager.default.createDirectory(at: Self.audioDir, withIntermediateDirectories: true)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        jobs = (try? dec.decode([Job].self, from: Data(contentsOf: file))) ?? []
    }
    private func persist() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(jobs).write(to: file, options: .atomic)
    }
    func add(_ j: Job) { jobs.append(j); persist() }
    func promote(_ id: UUID) { if let i = jobs.firstIndex(where: { $0.id == id }), i > 0 { jobs.insert(jobs.remove(at: i), at: 0); persist() } }
    func remove(_ id: UUID) { jobs.removeAll { $0.id == id }; persist() }
    func first(skipping: UUID? = nil) -> Job? { jobs.first { $0.id != skipping } }
    func first(excluding: Set<UUID>) -> Job? { jobs.first { !excluding.contains($0.id) } }
    var count: Int { jobs.count }
    var all: [Job] { jobs }
    static func url(_ j: Job) -> URL { audioDir.appendingPathComponent(j.audio) }
}

/// 16 kHz mono 16-bit WAV written while recording. The header is patched on `finish`; after a kill `repair` does it
/// from the file size, so the audio recorded so far is never lost.
final class WavWriter: @unchecked Sendable {
    private let h: FileHandle, lock = NSLock(); private var bytes: UInt32 = 0
    init(_ url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        h = try FileHandle(forWritingTo: url)
        try h.write(contentsOf: Self.header(0))
    }
    func append(_ pcm: [Float]) {
        var d = Data(capacity: pcm.count * 2)
        for f in pcm { let v = Int16(max(-1, min(1, f)) * 32767); d.append(UInt8(truncatingIfNeeded: v)); d.append(UInt8(truncatingIfNeeded: v >> 8)) }
        lock.lock(); defer { lock.unlock() }
        try? h.write(contentsOf: d); bytes += UInt32(d.count)
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        try? h.seek(toOffset: 0); try? h.write(contentsOf: Self.header(bytes)); try? h.close()
    }
    static func repair(_ url: URL) {
        guard url.pathExtension == "wav", let a = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64, a > 44,
              let h = try? FileHandle(forUpdating: url) else { return }
        try? h.seek(toOffset: 0); try? h.write(contentsOf: header(UInt32(a - 44))); try? h.close()
    }
    private static func header(_ n: UInt32) -> Data {
        func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8)] }
        var b = [UInt8]("RIFF".utf8) + le(36 + n) + [UInt8]("WAVEfmt ".utf8) + le(16) + le16(1) + le16(1) + le(16000) + le(32000) + le16(2) + le16(16)
        b += [UInt8]("data".utf8) + le(n); return Data(b)
    }
}

/// Transcript saved when the speech stage ends, so a kill while the reader works (3 GB phones) does not redo the
/// transcription: the retry restores it and runs the reader alone. Times are already in the original audio.
enum Checkpoint {
    static var dir: URL { JobQueue.audioDir.deletingLastPathComponent().appendingPathComponent("checkpoints") }
    private static func url(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString + ".json") }
    static func save(_ us: [Utterance], _ id: UUID) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(us) { try? d.write(to: url(id), options: .atomic) }
    }
    static func load(_ id: UUID) -> [Utterance]? { (try? Data(contentsOf: url(id))).flatMap { try? JSONDecoder().decode([Utterance].self, from: $0) } }
    static func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)); try? FileManager.default.removeItem(at: partialUrl(id)) }

    /// Android SessionLibrary.Progress: the frozen transcript of a run stopped before the end (original-audio times),
    /// so Resume transcribes only the audio after `seam`.
    struct Partial: Codable { var lines: [Utterance]; var seam: Double }
    private static func partialUrl(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString + ".partial.json") }
    static func savePartial(_ p: Partial, _ id: UUID) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: partialUrl(id), options: .atomic) }
    }
    static func loadPartial(_ id: UUID) -> Partial? { (try? Data(contentsOf: partialUrl(id))).flatMap { try? JSONDecoder().decode(Partial.self, from: $0) } }
}

/// Android SeamStitcher: a resumed run restarts the diarizer PREROLL seconds before the seam; the overlap maps its
/// fresh speaker ids onto the saved ones (greedy by overlapping seconds), and only fresh lines centred after the seam are kept.
enum SeamStitcher {
    static let preroll = 30.0
    static func stitch(_ prior: [Utterance], seam: Double, _ fresh: [Utterance], stable: Int) -> ([Utterance], Int) {
        if prior.isEmpty { return (fresh, stable) }
        var overlap: [[Int]: Double] = [:]
        for f in fresh where f.start < seam { for p in prior { let o = min(f.end, p.end) - max(f.start, p.start); if o > 0 { overlap[[f.speaker, p.speaker], default: 0] += o } } }
        var map: [Int: Int] = [:], taken = Set<Int>()
        for (k, _) in overlap.sorted(by: { $0.value > $1.value }) where map[k[0]] == nil && !taken.contains(k[1]) { map[k[0]] = k[1]; taken.insert(k[1]) }
        var next = (prior.map(\.speaker).max() ?? -1) + 1
        var kept: [Utterance] = [], keptStable = 0
        for (i, f) in fresh.enumerated() where (f.start + f.end) / 2 >= seam {
            var u = f; if let m = map[f.speaker] { u.speaker = m } else { map[f.speaker] = next; u.speaker = next; next += 1 }
            kept.append(u); if i < stable { keptStable += 1 }
        }
        return (prior + kept, prior.count + keptStable)
    }
}
