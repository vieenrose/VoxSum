import Foundation

/// A recording or import waiting for the full pipeline (ASR + diarization + reader). Port of the Android persistent
/// processing queue: the audio is on disk before anything else happens, the job list survives an app kill, and a job
/// leaves the list only once its session is saved.
struct Job: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var audio: String        // file name in Application Support/audio
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
    func remove(_ id: UUID) { jobs.removeAll { $0.id == id }; persist() }
    func first(skipping: UUID? = nil) -> Job? { jobs.first { $0.id != skipping } }
    var count: Int { jobs.count }
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
