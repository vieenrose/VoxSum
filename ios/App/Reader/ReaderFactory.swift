import Foundation

/// The reader backend: the real mobile engine when built with VOX_REAL_READER (device, or the Intel simulator
/// with the locally built libLiteRt.so), the stub otherwise.
enum ReaderFactory {
    /// `dir` holds the reader model files (see ModelStore); nil/missing → stub.
    /// `gpu`: the GPU graph when the GPU is chosen and passed its test; a GPU that fails to load falls back to the CPU.
    static func make(dir: String?, threads: Int = Prefs.effectiveThreads, gpu: String? = BackendBench.gpuGraph(Prefs.reader)) -> (llm: ReaderLlm, systemPrompt: String, real: Bool) {
        let fallback = "你是會議記錄助理。"
        #if !VOX_REAL_READER
        return (StubLlm(), fallback, false)
        #else
        guard let dir else { return (StubLlm(), fallback, false) }
        let tok: SpTokenizer, eng: MfaEngine
        do {
            tok = try SpTokenizer(path: dir + "/Section1_SP_Tokenizer.spiece")
            let onGpu = gpu.flatMap { g -> MfaEngine? in
                do { return try MfaEngine(dir: dir, ctx: ReaderBudget.mobile.ctxBudget, threads: threads, weightCache: "", gpuGraph: g) }
                catch { FileHandle.standardError.write(Data("voxsum-reader: GPU load failed, reading on the CPU: \(error)\n".utf8)); return nil }
            }
            eng = try onGpu ?? MfaEngine(dir: dir, ctx: ReaderBudget.mobile.ctxBudget, threads: threads, weightCache: dir + "/weights.xnnpack_cache")
        } catch {
            FileHandle.standardError.write(Data("voxsum-reader: load failed, using the stub: \(error)\n".utf8))
            Prefs.reportReadFailure()
            return (StubLlm(), fallback, false)
        }
        StatusLog.add("reader on the \(eng.onGpu ? "GPU" : "CPU")")
        let prompt = (try? String(contentsOfFile: dir + "/system_prompt.txt", encoding: .utf8)) ?? fallback
        return (MfaSession(engine: eng, tok: tok), prompt, true)
        #endif
    }
}
