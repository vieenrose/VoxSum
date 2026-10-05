import Foundation
import CryptoKit

/// Reader model files on the device (port of Android LlmRegistry + ModelManager download path):
/// Hugging Face, revision-pinned, size + sha256 checked, resumable via HTTP Range.
struct ModelFile { let name: String, remote: String, size: Int64, sha256: String? }

struct ReaderModel {
    let id: String, repo: String, rev: String
    let files: [ModelFile]
    func url(_ f: ModelFile) -> URL { URL(string: "https://huggingface.co/\(repo)/resolve/\(rev)/\(f.remote)")! }

    private static let tokSha = "e594c8a90eb08d8bda498ff4747977dc827ae0c3c56b5c0d41a605a22d02ef03"
    private static let promptSha = "406040c70270b5b9d47a4222138fcf2177f361dcbfb79fba164ca2559e0ffbf3"
    private static func make(_ id: String, _ repo: String, _ rev: String, dir: String, prompt: String, _ g: [(Int64, String)]) -> ReaderModel {
        ReaderModel(id: id, repo: repo, rev: rev, files: [
            ModelFile(name: "Section1_SP_Tokenizer.spiece", remote: dir + "/Section1_SP_Tokenizer.spiece", size: 4_689_013, sha256: tokSha),
            ModelFile(name: "Section2_TFLiteModel_tf_lite_embedder.tflite", remote: dir + "/Section2_TFLiteModel_tf_lite_embedder.tflite", size: g[0].0, sha256: g[0].1),
            ModelFile(name: "Section3_TFLiteModel_tf_lite_per_layer_embedder.tflite", remote: dir + "/Section3_TFLiteModel_tf_lite_per_layer_embedder.tflite", size: g[1].0, sha256: g[1].1),
            ModelFile(name: "prefill_decode_fused.tflite", remote: dir + "/prefill_decode_fused.tflite", size: g[2].0, sha256: g[2].1),
            ModelFile(name: "system_prompt.txt", remote: prompt, size: 1_686, sha256: promptSha),
        ])
    }
    static let e2b = make("E2B", "Luigi/gemma-4-E2B-meeting-agent-zh-GGUF", "f47086170552f9b8e8719e9884af9fb9b56156d1",
        dir: "mobile-v1/mfa", prompt: "mobile-v1/system_prompt.txt", [
        (103_811_720, "280327ee5720663acd2268c2e5d42caad33f70ba7931eef8c8b3018b4e2a4980"),
        (1_284_518_392, "dca1e5553b4159558b17073c94fcc7ff16646e99a56a0614728435ac4b571720"),
        (818_394_320, "6a7555ccc349be490fca4ed63ebf7fdafd8e4a4510012f3ae9c38f8009b5fcae")])
    static let e4b = make("E4B", "Luigi/gemma-4-E4B-meeting-agent-zh-LiteRT", "70e095dc5db8d4edac901578a6e0f04d994ad95e",
        dir: "mfa", prompt: "system_prompt.txt", [
        (170_920_584, "94cf45ffd3d0dd7040d27b22e70845cf1054db90613bf31d8ffc1623d23d4a40"),
        (836_778_512, "d35fe41db89fa0128f5da9530886a12581cee715369e1b9ed9a3644e43d16a6a"),
        (2_260_210_576, "34858194f4f596fae132470a2e0f2f0f276e540c7af8502e4ef7cca99e871424")])
}

enum ModelStoreError: Error { case badStatus(Int), size(String), hash(String) }

actor ModelStore {
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("models")) {
        self.root = root
    }
    func dir(_ m: ReaderModel) -> URL { root.appendingPathComponent(m.id) }
    func isComplete(_ m: ReaderModel) -> Bool {
        m.files.allSatisfy { (try? FileManager.default.attributesOfItem(atPath: dir(m).appendingPathComponent($0.name).path)[.size] as? Int64) == $0.size }
    }

    /// Downloads what is missing; `progress` gets (bytes done, bytes total) over the whole model.
    func download(_ m: ReaderModel, progress: @Sendable (Int64, Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: dir(m), withIntermediateDirectories: true)
        let total = m.files.reduce(0) { $0 + $1.size }; var done: Int64 = 0
        for f in m.files {
            let dest = dir(m).appendingPathComponent(f.name), part = dest.appendingPathExtension("part")
            if let s = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64, s == f.size { done += f.size; progress(done, total); continue }
            let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
            var req = URLRequest(url: m.url(f))
            if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 || code == 206 else { throw ModelStoreError.badStatus(code) }
            if code == 200 || !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
            let h = try FileHandle(forWritingTo: part)
            if code == 206 { try h.seekToEnd() }
            var buf = Data(); var got = code == 206 ? have : 0
            for try await b in bytes {
                buf.append(b)
                if buf.count >= 1 << 20 { try h.write(contentsOf: buf); got += Int64(buf.count); buf.removeAll(keepingCapacity: true); progress(done + got, total) }
            }
            try h.write(contentsOf: buf); try h.close()
            guard (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) == f.size else { throw ModelStoreError.size(f.name) }
            if let want = f.sha256, try Self.sha256(part) != want { try? FileManager.default.removeItem(at: part); throw ModelStoreError.hash(f.name) }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: part, to: dest)
            done += f.size; progress(done, total)
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
