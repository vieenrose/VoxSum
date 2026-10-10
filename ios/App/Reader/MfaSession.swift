import os
import Foundation

#if VOX_REAL_READER   // needs LiteRT: CLiteRTLM (device) or the x86_64 libLiteRt.so built by native/litert_x86_sim (Intel simulator)

/// The Gemma-4 SentencePiece tokenizer (`Section1_SP_Tokenizer.spiece`). It parses the chat
/// template's special tokens itself (`<|turn>` = 105, `<turn|>` = 106); `<bos>` is not added.
final class SpTokenizer {
    private let h: OpaquePointer
    init(path: String) throws {
        var err = [CChar](repeating: 0, count: 512)
        guard let p = mfa_tok_load(path, &err, 512) else { throw ReaderError(description: String(cString: err)) }
        h = p
    }
    deinit { mfa_tok_free(h) }

    func encode(_ text: String) -> [Int] {
        var out: UnsafeMutablePointer<Int32>?
        let n = Int(mfa_tok_encode(h, text, &out))
        defer { mfa_ids_free(out) }
        return (0..<n).map { Int(out![$0]) }
    }
    /// A reply cut mid-character ends with U+FFFD, which a later call completes.
    func decode(_ ids: [Int]) -> String {
        let a = ids.map { Int32($0) }
        var n: Int32 = 0
        guard let p = mfa_tok_decode(h, a, Int32(a.count), &n) else { return "" }
        defer { free(p) }
        return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: Int(n)), as: UTF8.self)
    }
}

/// The forked LiteRT-LM CPU engine (cpp/mfa) running Google's Gemma-4 mobile graphs. Takes token
/// ids and reuses the longest prefix of each prompt already in its KV cache.
final class MfaEngine {
    private var h: OpaquePointer?
    static let bos = 2

    /// `dir` = the folder with the three `.tflite` files; `weightCache` is built on first load (CPU).
    /// `gpuGraph`: run on the GPU (ML Drift Metal) with this prefill/decode graph instead.
    init(dir: String, ctx: Int, threads: Int, weightCache: String, gpuGraph: String? = nil) throws {
        var err = [CChar](repeating: 0, count: 1024)
        guard let p = mfa_load(dir, gpuGraph ?? dir + "/prefill_decode_fused.tflite", Int32(ctx), Int32(threads),
                               gpuGraph == nil ? weightCache : "", gpuGraph == nil ? 0 : 1, &err, 1024)
        else { throw ReaderError(description: "mobile reader load failed: " + String(cString: err)) }
        h = p
    }
    deinit { mfa_free(h) }

    var context: Int { h.map { Int(mfa_context($0)) } ?? 0 }
    /// The last `generate`: prefilled, reused, generated, prefill_s, decode_s.
    private(set) var lastStats = [Double](repeating: 0, count: 5)

    /// Teacher-forced agreement with `forced` (another backend's greedy reply to `ids`): how many
    /// steps pick the next forced token. Near `forced.count` computes right, near 0 does not.
    func agree(_ ids: [Int], forced: [Int]) throws -> Int {
        guard let h else { throw ReaderError(description: "engine closed") }
        var err = [CChar](repeating: 0, count: 512)
        let r = mfa_agree(h, ids.map { Int32($0) }, Int32(ids.count), forced.map { Int32($0) }, Int32(forced.count), &err, 512)
        if r < 0 { throw ReaderError(description: String(cString: err)) }
        return Int(r)
    }
    func cancel() { if let h { mfa_cancel(h) } }

    /// Prefill `ids` (starting with `<bos>`) and generate up to `maxNew` tokens (0 = prefill only);
    /// `onToken` returns false to stop.
    func generate(_ ids: [Int], maxNew: Int, temp: Float, topK: Int, topP: Float, seed: UInt32,
                  onToken: (Int) -> Bool = { _ in true }) throws -> [Int] {
        guard let h else { throw ReaderError(description: "engine closed") }
        let a = ids.map { Int32($0) }
        var err = [CChar](repeating: 0, count: 512)
        var out: UnsafeMutablePointer<Int32>?
        var stats = [Double](repeating: 0, count: 5)
        typealias CB = (Int) -> Bool
        let n: Int32 = withoutActuallyEscaping(onToken) { cb in
            var box = cb
            return withUnsafeMutablePointer(to: &box) { ptr in
                mfa_generate(h, a, Int32(a.count), Int32(maxNew), temp, Int32(topK), topP, seed,
                             { id, user in user!.assumingMemoryBound(to: CB.self).pointee(Int(id)) ? 1 : 0 },
                             UnsafeMutableRawPointer(ptr), &out, &stats, &err, 512)
            }
        }
        guard n >= 0 else { throw ReaderError(description: String(cString: err)) }
        lastStats = stats
        if stats[3] + stats[4] > 5 {   // prefilled, reused, generated, prefill_s, decode_s: compute-bound or paging?
            StatusLog.add("trace mfa prefilled \(Int(stats[0])) (reused \(Int(stats[1]))) in \(Int(stats[3])) s = \(Int(stats[0] / max(stats[3], 0.1))) tok/s; generated \(Int(stats[2])) in \(Int(stats[4])) s; \(os_proc_available_memory() / 1_048_576) MB free")
        }
        defer { mfa_ids_free(out) }
        return (0..<Int(n)).map { Int(out![$0]) }
    }
}

/// The meeting reader's session on the mobile engine (port of Android `MfaSession`). The engine
/// keeps no sessions: the "conversation" is this token list — `append` prefills it (only the new
/// tail is computed), `generateContinue` resends it with a decode budget and appends the reply,
/// `reset` just forgets it.
final class MfaSession: ReaderLlm {
    private let engine: MfaEngine, tok: SpTokenizer
    private let topK: Int, topP: Float, seed: UInt32
    private var seq: [Int] = []
    /// Sticky: a stopped reading stays stopped through its remaining windows until `resume()`.
    private let cancelledLock = NSLock()
    private var cancelled = false

    init(engine: MfaEngine, tok: SpTokenizer, topK: Int = 40, topP: Float = 0.95, seed: UInt32 = 0) {
        self.engine = engine; self.tok = tok; self.topK = topK; self.topP = topP; self.seed = seed
    }

    private var isCancelled: Bool { cancelledLock.lock(); defer { cancelledLock.unlock() }; return cancelled }
    func cancel() { cancelledLock.lock(); cancelled = true; cancelledLock.unlock(); engine.cancel() }
    func resume() { cancelledLock.lock(); cancelled = false; cancelledLock.unlock() }

    func tokenize(_ text: String, special: Bool) -> [Int] {
        // SentencePiece parses the template's pieces (<|turn>, <turn|>) but not <bos>: map it here.
        guard special, text.contains("<bos>") else { return tok.encode(text) }
        var out: [Int] = []
        for (i, part) in text.components(separatedBy: "<bos>").enumerated() {
            if i > 0 { out.append(MfaEngine.bos) }
            if !part.isEmpty { out += tok.encode(part) }
        }
        return out
    }

    func append(_ tokens: [Int]) -> Int {
        if isCancelled || engine.context == 0 { return -1 }
        let next = seq + tokens
        if next.count >= engine.context { return -1 }   // a refused append leaves the sequence as it was
        do { _ = try engine.generate(next, maxNew: 0, temp: 0, topK: 1, topP: 1, seed: seed) } catch { return -1 }
        if isCancelled { return -1 }
        seq = next
        return seq.count
    }

    func generateContinue(maxTokens: Int, stop: String, temp: Float, onToken: (String) -> Void) -> String {
        let room = engine.context - seq.count - 1
        if room <= 0 || isCancelled { return "" }
        var gen: [Int] = [], shown = "", stopped = false
        _ = try? engine.generate(seq, maxNew: min(maxTokens, room), temp: temp, topK: topK, topP: topP, seed: seed) { [tok] id in
            gen.append(id)
            let text = tok.decode(gen)
            // Stream only complete characters: a reply cut mid-character decodes to U+FFFD.
            var stable = text; while stable.hasSuffix("\u{FFFD}") { stable.removeLast() }
            if stable.utf16.count > shown.utf16.count && stable.hasPrefix(shown) {
                onToken(String(stable.dropFirst(shown.count))); shown = stable
            }
            if !stop.isEmpty && text.contains(stop) { stopped = true; return false }
            return true
        }
        // The generated ids themselves join the sequence (re-tokenizing the text could differ and
        // break the engine's prefix reuse); an end-of-turn id is the model's, not the text's.
        let kept = gen.filter { !Self.stopIds.contains($0) }
        var text = tok.decode(kept)
        if stopped, let r = text.range(of: stop) { text = String(text[..<r.upperBound]) }
        seq += kept
        return text
    }

    var seqLength: Int { seq.count }
    func reset() { seq.removeAll() }

    private static let stopIds: Set<Int> = [1, 50, 106]
}

#endif
