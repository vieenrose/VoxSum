package studio.voxsum.core.llm

import java.io.Closeable
import kotlin.concurrent.withLock

/**
 * The mobile meeting reader's engine: the forked LiteRT-LM CPU engine (`cpp/mfa/`) running Google's
 * Gemma-4 mobile graphs (E2B, E4B) with the attention fused into one int8 op. It takes token ids
 * (see [SpTokenizer]) and reuses the longest prefix of each prompt that is already in its KV cache,
 * so callers resend the whole prompt every time and only its new tail is computed
 * (voxsumdroid-integration.md §13.3).
 *
 * One instance per loaded model. Not thread-safe: call [generate] from one thread; [cancel] may be
 * called from any thread.
 */
class MfaEngine private constructor(@Volatile private var handle: Long) : Closeable {

    /** Calls share it, [close] takes it alone: a call from a reader thread still queued when the
     *  model is closed must never reach the freed native engine (seen as a SIGSEGV in context()). */
    private val lock = java.util.concurrent.locks.ReentrantReadWriteLock()

    /** The context length the graph was loaded with (tokens). */
    val context: Int get() = lock.readLock().withLock { if (handle == 0L) 0 else nativeContext(handle) }

    /** What the last [generate] call did. */
    data class Stats(val prefilled: Int, val reused: Int, val generated: Int, val prefillSec: Double, val decodeSec: Double)

    var lastStats: Stats? = null
        private set

    fun interface TokenCallback { fun onToken(id: Int): Boolean }

    /**
     * Prefill [ids] (which must start with `<bos>`) and generate up to [maxNew] tokens; 0 only
     * prefills (feed the transcript as it arrives). [onToken] returns false to stop.
     */
    fun generate(
        ids: IntArray, maxNew: Int, temp: Float, topK: Int, topP: Float, seed: Int,
        onToken: TokenCallback? = null,
    ): IntArray {
        lock.readLock().withLock {
            check(handle != 0L) { "engine closed" }
            val st = DoubleArray(5)
            val out = nativeGenerate(handle, ids, maxNew, temp, topK, topP, seed, onToken, st)
            lastStats = Stats(st[0].toInt(), st[1].toInt(), st[2].toInt(), st[3], st[4])
            return out
        }
    }

    fun cancel() { lock.readLock().withLock { if (handle != 0L) nativeCancel(handle) } }

    /** Waits for a running [generate] (cancel it first to make that quick). */
    override fun close() {
        lock.writeLock().withLock { if (handle != 0L) { nativeFree(handle); handle = 0L } }
    }

    companion object {
        init { System.loadLibrary("voxsum-mfa") }

        /** `<bos>`: the engine does not add it (unlike LiteRT-LM), so every prompt starts with it.
         *  Generation stops by itself at `<turn|>` (106), `<eos>` (1) and 50. */
        const val BOS = 2

        /**
         * Load the model in [dir] (the `mfa/` folder of the HF repo). [weightCache] is built on the
         * first load (~0.8 GB for E2B, 2.2 GB for E4B) — do that once after the download, before any
         * recording, with nothing else loaded (§13.2). [backend]: 0 CPU, 1 GPU, 2 NPU (see
         * [studio.voxsum.core.hw.Backend]). Throws IllegalStateException on failure.
         */
        fun load(dir: String, ctx: Int, threads: Int, weightCache: String, backend: Int = 0): MfaEngine =
            MfaEngine(nativeLoad(dir, "$dir/prefill_decode_fused.tflite", ctx, threads, weightCache, backend))

        @JvmStatic private external fun nativeLoad(dir: String, main: String, ctx: Int, threads: Int, cache: String, backend: Int): Long
        @JvmStatic private external fun nativeGenerate(
            h: Long, ids: IntArray, maxNew: Int, temp: Float, topK: Int, topP: Float, seed: Int,
            cb: TokenCallback?, stats: DoubleArray,
        ): IntArray
        @JvmStatic private external fun nativeCancel(h: Long)
        @JvmStatic private external fun nativeFree(h: Long)
        @JvmStatic private external fun nativeContext(h: Long): Int
    }
}

/** The Gemma-4 SentencePiece tokenizer (`Section1_SP_Tokenizer.spiece`). It parses the chat
 *  template's special tokens itself (`<|turn>` = 105, `<turn|>` = 106); `<bos>` is not added. */
class SpTokenizer private constructor(@Volatile private var handle: Long) : Closeable {

    private val lock = java.util.concurrent.locks.ReentrantReadWriteLock()   // see MfaEngine.lock

    /** Empty once closed. */
    fun encode(text: String): IntArray = lock.readLock().withLock { if (handle == 0L) IntArray(0) else nativeEncode(handle, text) }

    /** Decoded text; a reply cut mid-character ends with U+FFFD, which a later call completes. */
    fun decode(ids: IntArray): String = lock.readLock().withLock {
        if (handle == 0L) "" else String(nativeDecode(handle, ids), Charsets.UTF_8)
    }

    override fun close() {
        lock.writeLock().withLock { if (handle != 0L) { nativeFree(handle); handle = 0L } }
    }

    companion object {
        init { System.loadLibrary("voxsum-mfa") }

        fun load(path: String): SpTokenizer = SpTokenizer(nativeLoad(path))

        @JvmStatic private external fun nativeLoad(path: String): Long
        @JvmStatic private external fun nativeEncode(h: Long, text: String): IntArray
        @JvmStatic private external fun nativeDecode(h: Long, ids: IntArray): ByteArray
        @JvmStatic private external fun nativeFree(h: Long)
    }
}
