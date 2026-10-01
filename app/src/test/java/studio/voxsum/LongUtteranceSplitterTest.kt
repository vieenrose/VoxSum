package studio.voxsum

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.voxsum.core.asr.LongUtteranceSplitter
import studio.voxsum.core.events.TranscriptEvent.Utterance

class LongUtteranceSplitterTest {
    private fun sentence(n: Int) = "這是第${n}句話，內容大約有二十個字左右而已。".repeat(1)

    @Test fun shortUtterancesAreUntouched() {
        val l = listOf(Utterance(0, "你好。", 0.0, 3.0, 1))
        assertEquals(l, LongUtteranceSplitter.split(l))
    }

    @Test fun longMonologueIsCutAtSentenceEndsWithContiguousTimes() {
        val text = (1..20).joinToString("") { sentence(it) }
        val out = LongUtteranceSplitter.split(listOf(Utterance(0, text, 10.0, 130.0, 2)))
        assertTrue(out.size > 3)
        assertEquals(10.0, out.first().startSec, 1e-9)
        assertEquals(130.0, out.last().endSec, 1e-9)
        out.zipWithNext().forEach { (a, b) -> assertEquals(a.endSec, b.startSec, 1e-9) }
        assertEquals(text, out.joinToString("") { it.text })
        assertTrue(out.all { it.speaker == 2 })
        assertEquals(out.indices.toList(), out.map { it.index })
    }

    @Test fun noPunctuationMeansNoCut() {
        val text = "字".repeat(400)
        assertEquals(1, LongUtteranceSplitter.split(listOf(Utterance(0, text, 0.0, 100.0, 0))).size)
    }
}
