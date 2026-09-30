package studio.voxsum.core.reader

/**
 * The KV-keeping session the meeting reader drives: one growing conversation, extended by
 * [append] (prefill only) and [generateContinue] (its tokens join the sequence), restarted by
 * [reset]. Implemented by [studio.voxsum.core.llm.LlmEngine]; tests use a fake. Not thread-safe:
 * the reader serializes every call on one thread.
 */
interface ReaderLlm {
    /** Token ids of [text] without BOS; [special] parses template pieces (`<|turn>` …). */
    fun tokenize(text: String, special: Boolean): IntArray

    /** Prefill [tokens] onto the cache. Returns the new sequence length, or -1 on failure. */
    fun append(tokens: IntArray): Int

    /** Decode from the current state until [stop] (kept in the sequence AND at the end of the returned text),
     *  end of generation or [maxTokens]; [onToken] receives streamed pieces. */
    fun generateContinue(maxTokens: Int, stop: String, temp: Float, onToken: (String) -> Unit): String

    fun seqLength(): Int

    /** Clear the cache and the sequence. */
    fun reset()
}
