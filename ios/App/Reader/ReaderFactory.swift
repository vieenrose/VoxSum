import Foundation

/// The reader backend: the real mobile engine when built with VOX_REAL_READER (device, or the Intel simulator
/// with the locally built libLiteRt.so), the stub otherwise.
enum ReaderFactory {
    /// `dir` holds the reader model files (see ModelStore); nil/missing → stub.
    static func make(dir: String?, threads: Int = Prefs.effectiveThreads) -> (llm: ReaderLlm, systemPrompt: String, real: Bool) {
        let fallback = "你是會議記錄助理。"
        #if !VOX_REAL_READER
        return (StubLlm(), fallback, false)
        #else
        guard let dir, let tok = try? SpTokenizer(path: dir + "/Section1_SP_Tokenizer.spiece"),
              let eng = try? MfaEngine(dir: dir, ctx: ReaderBudget.mobile.ctxBudget, threads: threads,
                                       weightCache: dir + "/weights.xnnpack_cache")
        else { return (StubLlm(), fallback, false) }
        let prompt = (try? String(contentsOfFile: dir + "/system_prompt.txt", encoding: .utf8)) ?? fallback
        return (MfaSession(engine: eng, tok: tok), prompt, true)
        #endif
    }
}
