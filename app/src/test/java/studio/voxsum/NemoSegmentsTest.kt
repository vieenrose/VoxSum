package studio.voxsum

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import studio.voxsum.core.asr.NemoStreamEngine
import studio.voxsum.core.asr.SnapshotConverter
import studio.voxsum.core.events.TranscriptEvent.Utterance
import studio.voxsum.core.events.TranscriptEvent.UtteranceSnapshot

class NemoSegmentsTest {

    private fun rec(spk: Int, a: Double, b: Double, t: String) = "$spk\u001f$a\u001f$b\u001f$t\u001e"

    @Test
    fun parsesJniEncoding() {
        val u = NemoStreamEngine.parseSegments(rec(0, 0.0, 2.5, "你 好 ， 世界") + rec(-1, 2.5, 3.0, "hi there") + rec(1, 3.0, 4.0, "  "))
        assertEquals(2, u.size)                      // whitespace-only record dropped
        assertEquals("你好，世界", u[0].text)          // cleanTranscript joined the spaced CJK
        assertEquals(0, u[0].speaker)
        assertNull(u[1].speaker)                     // -1 = unattributed
        assertEquals(1, u[1].index)
        assertEquals(2.5, u[1].startSec, 0.0)
    }

    @Test
    fun emptyInputIsEmpty() {
        assertEquals(0, NemoStreamEngine.parseSegments("").size)
    }

    @Test
    fun parsesLiveFrozenAndTail() {
        val raw = rec(0, 0.0, 2.0, "a") + rec(1, 2.0, 3.0, "b") + "\u001d" + rec(1, 3.0, 4.0, "c")
        val (frozen, tail) = NemoStreamEngine.parseLive(raw, firstIndex = 5)
        assertEquals(listOf("a", "b"), frozen.map { it.text })
        assertEquals(listOf(5, 6), frozen.map { it.index })   // continues after what is already frozen
        assertEquals(listOf("c"), tail.map { it.text })
        val (none, onlyTail) = NemoStreamEngine.parseLive("\u001d" + rec(0, 0.0, 1.0, "x"), 0)
        assertEquals(0, none.size)
        assertEquals(1, onlyTail.size)
    }

    @Test
    fun converterConvertsOnlyWhatChanged() {
        val calls = ArrayList<String>()
        val conv = SnapshotConverter({ t -> calls += t; t.uppercase() })
        val a = Utterance(0, "a", 0.0, 1.0, speaker = 0)
        val b = Utterance(1, "b", 1.0, 2.0, speaker = 1)
        val first = conv.apply(UtteranceSnapshot(listOf(a, b), stable = 1))
        assertEquals(listOf("A", "B"), first.utterances.map { it.text })
        assertEquals(1, first.stable)
        calls.clear()
        val b2 = b.copy(text = "bc")
        val second = conv.apply(UtteranceSnapshot(listOf(a, b2), stable = 1))
        assertEquals(listOf("bc"), calls)             // the unchanged first line was not re-converted
        assertEquals(listOf("A", "BC"), second.utterances.map { it.text })
    }

    @Test
    fun converterKeepsSpeakers() {
        val conv = SnapshotConverter(null)
        val out = conv.apply(UtteranceSnapshot(listOf(Utterance(0, "a", 0.0, 1.0, speaker = 3))))
        assertEquals(3, out.utterances[0].speaker)
    }
}
