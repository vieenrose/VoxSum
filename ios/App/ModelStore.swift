import Foundation
import CryptoKit

/// Reader model files on the device (port of Android LlmRegistry + ModelManager download path):
/// Hugging Face, revision-pinned, size + sha256 checked, resumable via HTTP Range.
struct ModelFile { let name: String, remote: String, size: Int64, sha256: String? }

struct ReaderModel {
    let id: String, repo: String, rev: String
    let files: [ModelFile]
    func url(_ f: ModelFile) -> URL { URL(string: f.remote.hasPrefix("https://") ? f.remote : "https://huggingface.co/\(repo)/resolve/\(rev)/\(f.remote)")! }

    /// Speech engine (ASR + diarization), the two pins of Android `ModelManager.NEMO_FILES`; CPU only.
    static let speech: ReaderModel = {
        let x = "acb1a95eac809719a2c86d1048471f96fc6444ad", d = "647d39feaa0e91dca5ce355a95403837b76dff56"
        return ReaderModel(id: "nemo", repo: "", rev: "", files: [
            ModelFile(name: "x-asr-zh-en-q8_0.gguf", remote: "https://huggingface.co/cstr/x-asr-zh-en-GGUF/resolve/\(x)/x-asr-zh-en-q8_0.gguf",
                      size: 168_189_920, sha256: "1ca120084a1517cf02d96e44cdd9a9544f0c887f6d0149c9f85d151be6833a61"),
            ModelFile(name: "nemotron-3-diarization-q8_0.gguf", remote: "https://huggingface.co/audio-cpp/Nemotron-3-Diarization-GGUF/resolve/\(d)/nemotron-3-diarization-q8_0.gguf",
                      size: 106_675_136, sha256: "9a737455bd10123bcf1e036d9a0b07b6e8c42e7d0dd1a5ee4141dc386db46d0b"),
        ])
    }()

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
    func download(_ m: ReaderModel, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: dir(m), withIntermediateDirectories: true)
        let total = m.files.reduce(0) { $0 + $1.size }; var done: Int64 = 0
        for f in m.files {
            let dest = dir(m).appendingPathComponent(f.name), part = dest.appendingPathExtension("part")
            if let s = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64, s == f.size { done += f.size; progress(done, total); continue }
            let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
            var req = URLRequest(url: m.url(f))
            if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
            let base = done
            try await Chunked.fetch(req, to: part, resumeFrom: have) { got in progress(base + got, total) }
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

/// Streams a response to `file` in network-sized chunks (iterating `URLSession.bytes` is per-byte and slow).
/// Resumes with `Range` when `resumeFrom > 0` and the server answers 206; a 200 restarts the file.
final class Chunked: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var handle: FileHandle?, got: Int64 = 0, cont: CheckedContinuation<Void, Error>?
    private let file: URL, resumeFrom: Int64, onProgress: (Int64) -> Void
    private var lastReport = Date.distantPast
    private init(file: URL, resumeFrom: Int64, onProgress: @escaping (Int64) -> Void) { self.file = file; self.resumeFrom = resumeFrom; self.onProgress = onProgress }

    static func fetch(_ req: URLRequest, to file: URL, resumeFrom: Int64, onProgress: @escaping (Int64) -> Void) async throws {
        let d = Chunked(file: file, resumeFrom: resumeFrom, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        // Cancelling the calling task stops the transfer; the partial file stays for a later resume.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                d.cont = c
                var r = req
                if resumeFrom > 0 { r.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range") }
                session.dataTask(with: r).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive resp: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else { finish(ModelStoreError.badStatus(code)); completionHandler(.cancel); return }
        do {
            if code == 200 || !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil); got = 0 }
            else { got = resumeFrom }
            handle = try FileHandle(forWritingTo: file)
            if code == 206 { try handle?.seekToEnd() }
            completionHandler(.allow)
        } catch { finish(error); completionHandler(.cancel) }
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { finish(error); dataTask.cancel(); return }
        got += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 0.5 { lastReport = Date(); onProgress(got) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { onProgress(got); finish(error) }
    private func finish(_ error: Error?) {
        try? handle?.close(); handle = nil
        guard let c = cont else { return }; cont = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
