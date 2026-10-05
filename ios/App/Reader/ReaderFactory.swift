import Foundation

/// The reader backend: the real mobile engine on a device, the stub in the (Intel) simulator.
enum ReaderFactory {
    /// `dir` holds the reader model files (see ModelStore); nil/missing → stub.
    static func make(dir: String?) -> (llm: ReaderLlm, systemPrompt: String, real: Bool) {
        let fallback = "你是會議記錄助理。"
        #if targetEnvironment(simulator)
        return (StubLlm(), fallback, false)
        #else
        guard let dir, let tok = try? SpTokenizer(path: dir + "/Section1_SP_Tokenizer.spiece"),
              let eng = try? MfaEngine(dir: dir, ctx: ReaderBudget.mobile.ctxBudget, threads: max(2, ProcessInfo.processInfo.activeProcessorCount - 2),
                                       weightCache: dir + "/weights.xnnpack_cache")
        else { return (StubLlm(), fallback, false) }
        let prompt = (try? String(contentsOfFile: dir + "/system_prompt.txt", encoding: .utf8)) ?? fallback
        return (MfaSession(engine: eng, tok: tok), prompt, true)
        #endif
    }
}
