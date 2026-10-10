import Foundation

/// One backend's verdict (Android BackendResult). `note` says why it did not pass:
/// no_runtime, no_model, crashed, unsupported, no_output, wrong_output.
struct BackendResult: Codable { var passed: Bool, prefill: Double = 0, decode: Double = 0, note: String = "" }

/// Where the reader runs (Android Backend + BackendBench): the CPU by default, the GPU (ML Drift Metal,
/// the model's own GPU graph, E2B only) once its test passed. The test reads the same 80-token prompt on
/// each backend; the GPU passes only if, fed the CPU's greedy reply token by token, its greedy choice
/// matches the next token at least `minAgree` of the time (iPhone 14 Pro Max: 30/32), so a GPU that
/// produces tokens but computes wrong stays off.
enum BackendBench {
    static let all = ["CPU", "GPU"]
    private static let reply = 32, minAgree = 0.75
    private static let prompt = "會議討論新辦公室的搬遷時程，搬家公司報價有三種，發言者傾向中間價位，並要求合約註明損壞賠償條款。" +
        "資訊部自行搬運電腦與伺服器，三月七號搬家，三月十號正式上班。"
    private static var d: UserDefaults { .standard }
    /// Results hold for this model and build (a new LiteRT may change what the GPU can run).
    private static func key(_ m: ReaderModel, _ b: String) -> String {
        "backend|\(m.id)|\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")|\(b)"
    }

    static func results(_ m: ReaderModel) -> [String: BackendResult] {
        settleCrash()
        var r: [String: BackendResult] = [:]
        for b in all { if let data = d.data(forKey: key(m, b)), let v = try? JSONDecoder().decode(BackendResult.self, from: data) { r[b] = v } }
        return r
    }
    private static func save(_ m: ReaderModel, _ b: String, _ r: BackendResult) { d.set(try? JSONEncoder().encode(r), forKey: key(m, b)) }

    /// The user's choice ("CPU" / "GPU").
    static var chosen: String {
        get { d.string(forKey: "readerBackend") ?? "CPU" }
        set { d.set(newValue, forKey: "readerBackend") }
    }

    /// The GPU graph to read with: the GPU is chosen, its last test on this model passed, and the graph is there.
    static func gpuGraph(_ m: ReaderModel) -> String? {
        guard chosen == "GPU", results(m)["GPU"]?.passed == true, let g = m.gpu else { return nil }
        let p = Storage.modelsRoot.appendingPathComponent(m.id).appendingPathComponent(g.name).path
        return (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int64) == g.size ? p : nil
    }

    /// A GPU probe that killed the app (Metal abort, jetsam) left its flag: record it as crashed.
    static func settleCrash() {
        guard let k = d.string(forKey: "backendProbing") else { return }
        d.removeObject(forKey: "backendProbing")
        d.set(try? JSONEncoder().encode(BackendResult(passed: false, note: "crashed")), forKey: k)
    }

    /// Tests every backend on `m` (files in `dir`, GPU graph `gpu` or nil when it has none); `onStep` gets each as it starts.
    static func run(_ m: ReaderModel, dir: String, gpu: String?, threads: Int, onStep: (String) -> Void) -> [String: BackendResult] {
        var out: [String: BackendResult] = [:]
        #if VOX_REAL_READER
        guard let tok = try? SpTokenizer(path: dir + "/Section1_SP_Tokenizer.spiece") else { return results(m) }
        let ids = [MfaEngine.bos] + tok.encode(prompt).prefix(80)
        var ref: [Int] = []   // the CPU's greedy reply
        for b in all {
            onStep(b)
            let r: BackendResult
            if b == "GPU" && gpu == nil { r = BackendResult(passed: false, note: "no_model") }
            else if b != "CPU" && ref.isEmpty { r = BackendResult(passed: false, note: "no_output") }
            else {
                if b != "CPU" { d.set(key(m, b), forKey: "backendProbing"); d.synchronize() }
                r = probe(b, dir: dir, gpu: gpu, ids: ids, threads: threads, ref: ref) { ref = $0 }
                d.removeObject(forKey: "backendProbing")
            }
            out[b] = r; save(m, b, r)
        }
        #else
        for b in all { out[b] = BackendResult(passed: b == "CPU", note: b == "CPU" ? "" : "no_runtime") }
        #endif
        if out[chosen]?.passed != true { chosen = "CPU" }
        return out
    }

    #if VOX_REAL_READER
    private static func probe(_ b: String, dir: String, gpu: String?, ids: [Int], threads: Int, ref: [Int], onReply: ([Int]) -> Void) -> BackendResult {
        do {
            let e = try MfaEngine(dir: dir, ctx: ReaderBudget.mobile.ctxBudget, threads: threads,
                                  weightCache: dir + "/weights.xnnpack_cache", gpuGraph: b == "GPU" ? gpu : nil)
            let out = try e.generate(ids, maxNew: reply, temp: 0, topK: 1, topP: 1, seed: 0)
            let s = e.lastStats
            guard s[2] > 0 else { return BackendResult(passed: false, note: "no_output") }
            let ok = BackendResult(passed: true, prefill: s[0] / max(s[3], 1e-3), decode: s[2] / max(s[4], 1e-3))
            if b == "CPU" { onReply(out); return ok }
            let hit = try e.agree(ids, forced: ref)
            StatusLog.add("backend \(b) agrees with the CPU on \(hit)/\(ref.count) tokens")
            return Double(hit) >= minAgree * Double(ref.count) ? ok : BackendResult(passed: false, prefill: ok.prefill, decode: ok.decode, note: "wrong_output")
        } catch {
            StatusLog.add("backend \(b) probe failed: \(error)")
            return BackendResult(passed: false, note: "unsupported")
        }
    }
    #endif
}
