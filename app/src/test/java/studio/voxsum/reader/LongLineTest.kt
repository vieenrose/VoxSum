package studio.voxsum.reader

import org.junit.Assert.assertTrue
import org.junit.Test
import studio.voxsum.core.reader.Line
import studio.voxsum.core.reader.MeetingReader
import studio.voxsum.core.reader.ReaderBudget
import studio.voxsum.core.reader.ReaderLlm

/** A transcript line longer than a whole window must not overflow the 4k context. */
class LongLineTest {
    private class Llm(val ctx: Int) : ReaderLlm {
        val seq = StringBuilder(); var maxSeq = 0
        override fun tokenize(text: String, special: Boolean) = text.codePoints().toArray()
        override fun append(tokens: IntArray): Int {
            tokens.forEach { seq.appendCodePoint(it) }; maxSeq = maxOf(maxSeq, seqLength())
            return if (seqLength() < ctx) seqLength() else -1
        }
        override fun generateContinue(maxTokens: Int, stop: String, temp: Float, onToken: (String) -> Unit): String {
            val r = "NOTE [0:00] (DECISION) 通過\n$stop"; seq.append(r); maxSeq = maxOf(maxSeq, seqLength() + maxTokens); return r
        }
        override fun seqLength() = seq.codePointCount(0, seq.length)
        override fun reset() { seq.setLength(0) }
    }

    @Test fun aMonologueLongerThanTheWindowStaysInsideTheContext() {
        val llm = Llm(ReaderBudget.MOBILE.ctxBudget)
        val reader = MeetingReader(llm, "系統".repeat(200), count = { it.codePointCount(0, it.length) }, events = {}, budget = ReaderBudget.MOBILE)
        reader.start()
        reader.offer(Line(0, "S1", "這是一段很長的獨白，沒有停頓。".repeat(400)))   // ~6,000 characters in one line
        reader.offer(Line(900, "S2", "好。"))
        reader.finish()
        assertTrue("peak ${llm.maxSeq} tokens", llm.maxSeq <= ReaderBudget.MOBILE.ctxBudget)
    }
}
