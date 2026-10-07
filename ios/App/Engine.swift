import Foundation

struct Utterance: Identifiable, Hashable, Codable {
    var id = UUID()
    private enum CodingKeys: String, CodingKey { case speaker, start, end, text }
    var speaker: Int, start: Double, end: Double, text: String
}

/// Swift face of the C bridge (nemo_c.h). Same wire format as nemo_jni.cpp.
final class NemoEngine: @unchecked Sendable {
    private let h: OpaquePointer
    init?(xasr: String, diar: String, threads: Int = 4, settle: Double = 5) {
        guard let p = nemo_create(xasr, diar, Int32(threads), settle) else { return nil }
        h = p
    }
    private var closed = false
    /// Frees the models now (the reader needs their memory on 3 GB devices).
    func close() { if !closed { closed = true; nemo_free(h) } }
    deinit { close() }

    func push(_ pcm: [Float]) -> Bool { pcm.withUnsafeBufferPointer { nemo_push(h, $0.baseAddress, Int32($0.count)) == 1 } }
    var fedSeconds: Double { nemo_fed_seconds(h) }

    func live() -> (frozen: [Utterance], tail: [Utterance]) {
        guard let c = nemo_live(h) else { return ([], []) }
        defer { nemo_string_free(c) }
        let parts = String(cString: c).split(separator: "\u{1d}", maxSplits: 1, omittingEmptySubsequences: false)
        return (LongUtteranceSplitter.split(Self.decode(parts.first.map(String.init) ?? "")), LongUtteranceSplitter.split(Self.decode(parts.count > 1 ? String(parts[1]) : "")))
    }
    func finish() -> [Utterance]? {
        guard let c = nemo_finish(h) else { return nil }
        defer { nemo_string_free(c) }
        return LongUtteranceSplitter.split(Self.decode(String(cString: c)))
    }
    static func decode(_ s: String) -> [Utterance] {
        s.split(separator: "\u{1e}").compactMap { rec in
            let f = rec.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4, let sp = Int(f[0]), let a = Double(f[1]), let b = Double(f[2]) else { return nil }
            return Utterance(speaker: sp, start: a, end: b, text: String(f[3]))
        }
    }
}

/// 16 kHz mono 16-bit PCM WAV → floats.
func loadWav(_ path: String) -> [Float]? {
    guard let d = FileManager.default.contents(atPath: path), d.count > 44 else { return nil }
    var i = 12
    while i + 8 <= d.count {
        let id = String(decoding: d[i..<i+4], as: UTF8.self)
        let n = Int(d[i+4]) | Int(d[i+5]) << 8 | Int(d[i+6]) << 16 | Int(d[i+7]) << 24
        if id == "data" {
            let end = min(d.count, i + 8 + n)
            return stride(from: i + 8, to: end - 1, by: 2).map { Float(Int16(bitPattern: UInt16(d[$0]) | UInt16(d[$0+1]) << 8)) / 32768 }
        }
        i += 8 + n + (n & 1)
    }
    return nil
}
