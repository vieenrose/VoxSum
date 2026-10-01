package studio.voxsum.core.asr

import studio.voxsum.core.events.TranscriptEvent.Utterance

/**
 * One speaker talking without a pause comes out of the engine as a single utterance, minutes long:
 * an unreadable wall of text whose every summary link seeks to the same second. Cut such an
 * utterance at sentence ends; the cut times are estimated from character counts (speech rate is
 * close to constant over a sentence), which is accurate to a second or two.
 */
object LongUtteranceSplitter {
    private const val MIN_SEC = 20.0
    private const val MIN_CHARS = 100
    private const val CHUNK_CHARS = 90          // a piece is closed at the first sentence end past this
    private val SENTENCE_END = setOf('。', '？', '！', '?', '!', '.', '；', ';')

    fun split(list: List<Utterance>): List<Utterance> {
        if (list.none { it.endSec - it.startSec > MIN_SEC && it.text.length > MIN_CHARS }) return list
        val out = ArrayList<Utterance>(list.size + 8)
        for (u in list) {
            val parts = if (u.endSec - u.startSec > MIN_SEC && u.text.length > MIN_CHARS) pieces(u.text) else listOf(u.text)
            if (parts.size <= 1) { out += u.copy(index = out.size); continue }
            val total = parts.sumOf { it.length }.toDouble()
            var at = u.startSec
            var used = 0
            for ((i, p) in parts.withIndex()) {
                used += p.length
                val end = if (i == parts.lastIndex) u.endSec else u.startSec + (u.endSec - u.startSec) * used / total
                // tokens/tokenTimes describe the whole utterance, so they cannot follow the cut
                out += u.copy(index = out.size, text = p.trim(), startSec = at, endSec = end, tokens = null, tokenTimes = null)
                at = end
            }
        }
        return out
    }

    private fun pieces(text: String): List<String> {
        val res = ArrayList<String>()
        val sb = StringBuilder()
        for ((i, c) in text.withIndex()) {
            sb.append(c)
            // ASCII '.' only ends a sentence when followed by a space (not 3.14, not "e.g.x")
            val ends = c in SENTENCE_END && (c != '.' || i + 1 >= text.length || text[i + 1] == ' ')
            if (ends && sb.length >= CHUNK_CHARS) { res += sb.toString(); sb.setLength(0) }
        }
        if (sb.isNotBlank()) {
            if (res.isNotEmpty() && sb.length < CHUNK_CHARS / 3) res[res.lastIndex] = res.last() + sb else res += sb.toString()
        }
        return res.filter { it.isNotBlank() }
    }
}
