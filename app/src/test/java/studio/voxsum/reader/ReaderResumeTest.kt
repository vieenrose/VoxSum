package studio.voxsum.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.voxsum.core.reader.Line
import studio.voxsum.core.reader.MeetingReader
import studio.voxsum.core.reader.ReaderBudget
import studio.voxsum.core.reader.ReaderCheckpoint
import studio.voxsum.core.reader.ReaderLlm

/** An interrupted reading continues from its saved notes instead of re-reading from line 0. */
class ReaderResumeTest {
    private class Llm(var turns: Int = 0) : ReaderLlm {
        val seq = StringBuilder(); var appended = 0
        override fun tokenize(text: String, special: Boolean) = text.codePoints().toArray()
        override fun append(tokens: IntArray): Int { appended += tokens.size; tokens.forEach { seq.appendCodePoint(it) }; return seqLength() }
        override fun generateContinue(maxTokens: Int, stop: String, temp: Float, onToken: (String) -> Unit): String {
            turns++
            val r = "NOTE [${(turns - 1) * 100 / 60}:${"%02d".format((turns - 1) * 100 % 60)}] (DECISION) 決定$turns\n$stop"; seq.append(r); return r
        }
        override fun seqLength() = seq.codePointCount(0, seq.length)
        override fun reset() { seq.setLength(0) }
    }

    private val budget = ReaderBudget.MOBILE
    private fun reader(llm: Llm) = MeetingReader(llm, "系統", count = { it.codePointCount(0, it.length) }, events = {}, budget = budget)
    private val lines = List(60) { Line(it * 100, "S1", "第${it}句，" + "內容".repeat(120)) }

    @Test fun resumeSkipsTheLinesAlreadyRead() {
        val first = Llm(); val a = reader(first); val cps = ArrayList<ReaderCheckpoint>()
        a.onCheckpoint = { cps += it }
        a.start(); lines.take(40).forEach(a::offer)
        val cp = cps.last()
        assertTrue("some window closed", cp.window >= 1 && cp.journal.isNotEmpty() && cp.offered in 1..40)

        val second = Llm(first.turns); val b = reader(second)
        b.seed(cp, lines.take(cp.offered))
        assertEquals(cp.journal, b.journal)
        assertEquals(cp.window, b.window)
        lines.drop(cp.offered).forEach(b::offer)
        b.finish()
        assertTrue("notes only grow", b.journal.size > cp.journal.size)
        assertEquals("ids continue", (1..b.journal.size).toList(), b.journal.map { it.id })
        assertEquals(cp.digest, ReaderCheckpoint.digestOf(lines.take(cp.offered)))
        assertTrue("second run fed less than a whole transcript", second.appended < first.appended + 2000)
    }

    /** Same windows as an uninterrupted run: the resumed reader opens the next window at the same line. */
    @Test fun resumedWindowsMatchAnUninterruptedRun() {
        val full = Llm(); val a = reader(full); a.start(); lines.forEach(a::offer); a.finish()

        val cut = Llm(); val b = reader(cut); val cps = ArrayList<ReaderCheckpoint>()
        b.onCheckpoint = { cps += it }
        b.start(); lines.take(30).forEach(b::offer)
        val cp = cps[cps.size / 2]                      // interrupted after an earlier window
        val res = Llm(cp.window); val c = reader(res)
        c.seed(cp, lines.take(cp.offered)); lines.drop(cp.offered).forEach(c::offer); c.finish()
        assertEquals(full.turns, res.turns)             // the same number of windows read overall
        assertEquals(a.journal.map { it.window }, c.journal.map { it.window })
        assertEquals(a.journal.map { it.ts }, c.journal.map { it.ts })
    }

    @Test fun aDifferentTranscriptDoesNotMatchTheDigest() {
        val cp = ReaderCheckpoint(emptyList(), 1, 3, ReaderCheckpoint.digestOf(lines.take(3)))
        val other = lines.take(3).toMutableList().also { it[1] = it[1].copy(text = "不同") }
        assertTrue(ReaderCheckpoint.digestOf(other) != cp.digest)
    }
}
