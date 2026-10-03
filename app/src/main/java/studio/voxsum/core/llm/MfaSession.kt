package studio.voxsum.core.llm

import studio.voxsum.core.reader.ReaderLlm

/**
 * The meeting reader's session ([ReaderLlm]) on the mobile engine. The engine keeps no sessions:
 * it reuses the longest prefix of each prompt already in its KV cache. So the "conversation" is
 * this token list — [append] prefills it (only the new tail is computed), [generateContinue]
 * resends it with a decode budget and appends the reply, [reset] just forgets it (the next prompt
 * shares its system-prompt prefix with the cache and reuses that).
 */
class MfaSession(
    private val engine: MfaEngine,
    private val tok: SpTokenizer,
    private val topK: Int = 40,
    private val topP: Float = 0.95f,
    private val seed: Int = 0,
) : ReaderLlm {

    private val seq = ArrayList<Int>()

    /** Sticky: the engine clears its own flag at each request, but a stopped reading must stay
     *  stopped through its remaining windows. Cleared by [resume] before the next reading. */
    @Volatile private var cancelled = false

    fun cancel() { cancelled = true; engine.cancel() }

    fun resume() { cancelled = false }

    override fun tokenize(text: String, special: Boolean): IntArray {
        // SentencePiece parses the template's pieces (<|turn>, <turn|>) but not <bos>: map it here.
        if (!special || !text.contains(BOS_TEXT)) return tok.encode(text)
        val out = ArrayList<Int>()
        text.split(BOS_TEXT).forEachIndexed { i, part ->
            if (i > 0) out += MfaEngine.BOS
            if (part.isNotEmpty()) out += tok.encode(part).toList()
        }
        return out.toIntArray()
    }

    override fun append(tokens: IntArray): Int {
        if (cancelled) return -1
        val next = seq + tokens.toList()
        // The prompt must leave room in the cache; a refused append leaves the sequence as it was.
        if (next.size >= engine.context) return -1
        return try {
            engine.generate(next.toIntArray(), maxNew = 0, temp = 0f, topK = 1, topP = 1f, seed = seed)
            if (cancelled) return -1
            seq += tokens.toList()
            seq.size
        } catch (e: IllegalStateException) {
            -1
        }
    }

    override fun generateContinue(maxTokens: Int, stop: String, temp: Float, onToken: (String) -> Unit): String {
        val gen = ArrayList<Int>()
        var shown = ""
        var stopped = false
        // Never ask past the cache: the reply is cut at its end, like a length stop.
        val room = engine.context - seq.size - 1
        if (room <= 0 || cancelled) return ""
        engine.generate(seq.toIntArray(), minOf(maxTokens, room), temp, topK, topP, seed) { id ->
            gen += id
            val text = tok.decode(gen.toIntArray())
            // Stream only complete characters: a reply cut mid-character decodes to U+FFFD.
            val stable = text.trimEnd('�')
            if (stable.length > shown.length && stable.startsWith(shown)) { onToken(stable.substring(shown.length)); shown = stable }
            if (stop.isNotEmpty() && text.contains(stop)) { stopped = true; false } else true
        }
        // The reply joins the sequence, and the stop string with it. The
        // generated ids themselves go in (re-tokenizing the text could differ and break the
        // engine's prefix reuse); an end-of-turn id is the model's, not the text's, so it is left out.
        val kept = gen.filter { it !in STOP_IDS }
        var text = tok.decode(kept.toIntArray())
        if (stopped) text = text.substring(0, text.indexOf(stop) + stop.length)
        seq += kept
        return text
    }

    override fun seqLength(): Int = seq.size

    override fun reset() { seq.clear() }

    private companion object {
        const val BOS_TEXT = "<bos>"
        val STOP_IDS = setOf(1, 50, 106)
    }
}
