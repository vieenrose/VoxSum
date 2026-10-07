import Foundation
import AVFoundation
import Compression

/// Android-compatible VoxSum session container (.m4a): audio + `moov.udta.meta.ilst` carrying a freeform
/// `----` atom (mean=studio.voxsum, name=VOXSUM) with base64(gzip(JSON)), plus ©nam / ©cmt / ©lyr for ordinary players.
enum SessionFile {
    private static let mean = "studio.voxsum", field = "VOXSUM"
    private static let maxJSON = 16 << 20, maxBlob = 32 << 20

    // MARK: manifest
    struct Manifest: Codable {
        struct SN: Codable { var name: String; var confidence: String?; var reason: String? }
        struct U: Codable { var index: Int?; var start: Double; var end: Double; var text: String; var speaker: Int? }
        var voxsum_version = 1
        var title: String?, summary: String?, action_items: String?, notes: String?
        var asr_model: String?, asr_backend: String?, llm_model: String?
        var speaker_names: [String: SN]?
        var utterances: [U]?
    }

    static func manifest(_ s: Session) -> Manifest {
        var m = Manifest(); m.title = s.title; m.summary = s.summary
        m.notes = s.notes.isEmpty ? nil : s.notes.map { ReaderProtocol.render($0) }.joined(separator: "\n")
        m.action_items = s.actionItems ?? "-"
        m.asr_backend = "ios"
        m.speaker_names = (s.speakerNames ?? [:]).filter { !$0.value.isEmpty }.mapValues { Manifest.SN(name: $0, confidence: "user", reason: "") }
        m.utterances = s.lines.enumerated().map { Manifest.U(index: $0.offset, start: $0.element.start, end: $0.element.end, text: $0.element.text, speaker: $0.element.speaker) }
        return m
    }

    static func session(_ m: Manifest, audio: String?) -> Session {
        let lines = (m.utterances ?? []).map { Utterance(speaker: $0.speaker ?? 0, start: $0.start, end: $0.end, text: $0.text) }
        var names: [String: String] = [:]
        for (k, v) in m.speaker_names ?? [:] where !v.name.isEmpty { names[k] = v.name }
        return Session(title: m.title ?? "", summary: m.summary ?? "", seconds: lines.last?.end ?? 0, lines: lines, notes: [], audio: audio, speakerNames: names.isEmpty ? nil : names)
    }

    // MARK: gzip (Apple's COMPRESSION_ZLIB is raw deflate)
    private static let crcTable: [UInt32] = (0..<256).map { n in (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 } }
    private static func crc32(_ d: Data) -> UInt32 { ~d.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) } }

    static func gzip(_ d: Data) -> Data? {
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        let cap = d.count + d.count / 8 + 1024
        var buf = [UInt8](repeating: 0, count: cap)
        let n = d.withUnsafeBytes { src in compression_encode_buffer(&buf, cap, src.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_ZLIB) }
        guard n > 0 else { return nil }
        out.append(contentsOf: buf[0..<n])
        var c = crc32(d).littleEndian, sz = UInt32(truncatingIfNeeded: d.count).littleEndian
        out.append(Data(bytes: &c, count: 4)); out.append(Data(bytes: &sz, count: 4))
        return out
    }

    /// Bounded gunzip: nil when malformed or larger than `maxJSON`.
    static func gunzip(_ d: Data) -> Data? {
        let b = [UInt8](d)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        var p = 10; let flg = b[3]
        if flg & 4 != 0 { guard p + 2 <= b.count else { return nil }; p += 2 + Int(b[p]) + Int(b[p + 1]) << 8 }
        for bit in [8, 16] as [UInt8] where flg & bit != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
        if flg & 2 != 0 { p += 2 }
        guard p < b.count - 8 else { return nil }
        var out = [UInt8](repeating: 0, count: maxJSON)
        let n = b[p..<(b.count - 8)].withUnsafeBufferPointer { compression_decode_buffer(&out, maxJSON, $0.baseAddress!, $0.count, nil, COMPRESSION_ZLIB) }
        guard n > 0, n < maxJSON else { return nil }
        return Data(out[0..<n])
    }

    // MARK: MP4 boxes
    private static func u32(_ d: Data, _ o: Int) -> Int { d[o..<o + 4].reduce(0) { $0 << 8 | Int($1) } }
    private static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    private static func box(_ t: [UInt8], _ payload: Data) -> Data { Data(be32(payload.count + 8) + t) + payload }
    private static func box(_ t: String, _ payload: Data) -> Data { box(Array(t.utf8), payload) }
    private static let A9: UInt8 = 0xA9
    private static func dataBox(_ s: Data, type: Int = 1) -> Data { box("data", Data(be32(type) + be32(0)) + s) }
    private static func text(_ t: [UInt8], _ s: String) -> Data { box(t, dataBox(Data(s.utf8))) }

    /// (type, content range) for each child box of `d[range]`.
    private static func children(_ d: Data, _ r: Range<Int>) -> [(String, Range<Int>, Range<Int>)] {
        var o = r.lowerBound, out: [(String, Range<Int>, Range<Int>)] = []
        while o + 8 <= r.upperBound {
            var sz = u32(d, o); var hdr = 8
            if sz == 1 { guard o + 16 <= r.upperBound else { break }; sz = u32(d, o + 12); hdr = 16 }   // 64-bit size (low word; moov never exceeds 4 GB)
            if sz == 0 { sz = r.upperBound - o }
            guard sz >= hdr, o + sz <= r.upperBound else { break }
            let t = String(decoding: d[o + 4..<o + 8], as: UTF8.self)
            out.append((t == "\u{FFFD}" ? "?" : t, o..<o + sz, o + hdr..<o + sz)); o += sz
        }
        return out
    }
    private static func shift(_ d: inout Data, _ r: Range<Int>, by delta: Int) {
        for (t, _, c) in children(d, r) {
            switch t {
            case "trak", "mdia", "minf", "stbl": shift(&d, c, by: delta)
            case "stco":
                let n = u32(d, c.lowerBound + 4)
                for i in 0..<n { let o = c.lowerBound + 8 + i * 4; let v = u32(d, o) + delta; d.replaceSubrange(o..<o + 4, with: be32(v)) }
            case "co64":
                let n = u32(d, c.lowerBound + 4)
                for i in 0..<n {
                    let o = c.lowerBound + 8 + i * 8; var v = 0; for k in 0..<8 { v = v << 8 | Int(d[o + k]) }
                    v += delta; d.replaceSubrange(o..<o + 8, with: (0..<8).map { UInt8(v >> (56 - 8 * $0) & 255) })
                }
            default: break
            }
        }
    }

    /// Copy `src` (m4a) to `dest` as ftyp + moov(+udta) + mdat with the session tags injected. False on any structural surprise.
    static func write(src: URL, dest: URL, title: String, summary: String, lrc: String, blob: String) -> Bool {
        guard let rh = try? FileHandle(forReadingFrom: src) else { return false }
        defer { try? rh.close() }
        guard let size = try? rh.seekToEnd() else { return false }
        var ftyp: Data?, moov: Data?, mdat: (off: UInt64, len: UInt64)?
        var o: UInt64 = 0
        while o + 8 <= size {
            try? rh.seek(toOffset: o)
            guard let h = try? rh.read(upToCount: 16), h.count >= 8 else { return false }
            var len = UInt64(u32(h, 0)); var hdr: UInt64 = 8
            if len == 1 { guard h.count == 16 else { return false }; len = h[8..<16].reduce(0) { $0 << 8 | UInt64($1) }; hdr = 16 }
            if len == 0 { len = size - o }
            guard len >= hdr, o + len <= size else { return false }
            let t = String(decoding: h[4..<8], as: UTF8.self)
            if t == "ftyp" || t == "moov" {
                try? rh.seek(toOffset: o)
                guard let d = try? rh.read(upToCount: Int(len)), d.count == Int(len) else { return false }
                if t == "ftyp" { ftyp = d } else { moov = d }
            } else if t == "mdat" { mdat = (o, len) }
            o += len
        }
        guard let ftyp, let moov, let mdat else { return false }

        var kept = Data()
        for (t, r, _) in children(moov, 8..<moov.count) where t != "udta" { kept += moov[r] }
        let hdlr = box("hdlr", Data(be32(0) + be32(0) + Array("mdir".utf8) + Array("appl".utf8) + [UInt8](repeating: 0, count: 9)))
        let free = box("----", box("mean", Data(be32(0) + Array(mean.utf8))) + box("name", Data(be32(0) + Array(field.utf8))) + dataBox(Data(blob.utf8)))
        var ilst = free + text([A9, 0x6e, 0x61, 0x6d], title) + text([A9, 0x63, 0x6d, 0x74], summary)
        if !lrc.isEmpty { ilst += text([A9, 0x6c, 0x79, 0x72], lrc) }
        let udta = box("udta", box("meta", Data(be32(0)) + hdlr + box("ilst", ilst)))
        var newMoov = box("moov", kept + udta)
        shift(&newMoov, 8..<newMoov.count, by: ftyp.count + newMoov.count - Int(mdat.off))

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let wh = try? FileHandle(forWritingTo: dest) else { return false }
        defer { try? wh.close() }
        wh.write(ftyp); wh.write(newMoov)
        try? rh.seek(toOffset: mdat.off)
        var left = mdat.len
        while left > 0 {
            guard let c = try? rh.read(upToCount: Int(min(left, 1 << 20))), !c.isEmpty else { return false }
            wh.write(c); left -= UInt64(c.count)
        }
        return true
    }

    // MARK: export
    /// Transcode the session audio to AAC .m4a and inject the manifest. Returns the temp file URL.
    static func export(_ s: Session) async -> URL? {
        guard let a = s.audio else { return nil }
        let asset = AVURLAsset(url: JobQueue.audioDir.appendingPathComponent(a))
        let tmp = FileManager.default.temporaryDirectory
        let raw = tmp.appendingPathComponent("voxsum_raw_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: raw) }
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        ex.outputURL = raw; ex.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
        guard ex.status == .completed else { return nil }
        guard let json = try? JSONEncoder().encode(manifest(s)), let gz = gzip(json) else { return nil }
        let blob = gz.base64EncodedString()
        guard blob.utf8.count <= maxBlob else { return nil }
        let safe = String(s.title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? Character($0) : "_" }.prefix(60))
        let name = safe.replacingOccurrences(of: "_{2,}", with: "_", options: .regularExpression)
        let out = tmp.appendingPathComponent((name.trimmingCharacters(in: CharacterSet(charactersIn: "_")).isEmpty ? "voxsum_session" : name) + ".m4a")
        try? FileManager.default.removeItem(at: out)
        return write(src: raw, dest: out, title: s.title, summary: s.summary, lrc: Export.text(s, .lrc), blob: blob) ? out : nil
    }

    // MARK: open
    /// The embedded manifest of an .m4a, or nil (plain audio / unreadable).
    static func read(_ url: URL) -> Manifest? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size >= 12 else { return nil }
        try? h.seek(toOffset: 0)
        guard let head = try? h.read(upToCount: 12), String(decoding: head[4..<8], as: UTF8.self) == "ftyp" else { return nil }
        var o: UInt64 = 0
        while o + 8 <= size {
            try? h.seek(toOffset: o)
            guard let hd = try? h.read(upToCount: 16), hd.count >= 8 else { return nil }
            var len = UInt64(u32(hd, 0))
            if len == 1 { guard hd.count == 16 else { return nil }; len = hd[8..<16].reduce(0) { $0 << 8 | UInt64($1) } }
            if len == 0 { len = size - o }
            guard len >= 8, o + len <= size else { return nil }
            if String(decoding: hd[4..<8], as: UTF8.self) == "moov" {
                guard len < 64 << 20 else { return nil }
                try? h.seek(toOffset: o)
                guard let m = try? h.read(upToCount: Int(len)) else { return nil }
                return blob(in: m)
            }
            o += len
        }
        return nil
    }

    private static func blob(in moov: Data) -> Manifest? {
        for (t, _, c) in children(moov, 8..<moov.count) where t == "udta" {
            for (t2, _, c2) in children(moov, c) where t2 == "meta" {
                for (t3, _, c3) in children(moov, (c2.lowerBound + 4)..<c2.upperBound) where t3 == "ilst" {
                    for (t4, _, c4) in children(moov, c3) where t4 == "----" {
                        var mn = "", nm = "", val: Data?
                        for (t5, _, c5) in children(moov, c4) {
                            if t5 == "mean", c5.count > 4 { mn = String(decoding: moov[c5.lowerBound + 4..<c5.upperBound], as: UTF8.self) }
                            if t5 == "name", c5.count > 4 { nm = String(decoding: moov[c5.lowerBound + 4..<c5.upperBound], as: UTF8.self) }
                            if t5 == "data", c5.count > 8 { val = moov[c5.lowerBound + 8..<c5.upperBound] }
                        }
                        guard mn == mean, nm == field, let val, val.count <= maxBlob,
                              let gz = Data(base64Encoded: val, options: .ignoreUnknownCharacters), let json = gunzip(gz) else { continue }
                        return try? JSONDecoder().decode(Manifest.self, from: json)
                    }
                }
            }
        }
        return nil
    }
}
