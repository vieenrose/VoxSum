package studio.voxsum

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import studio.voxsum.core.asr.NemoStreamEngine
import studio.voxsum.core.asr.SpeakerTransfer
import studio.voxsum.core.events.TranscriptEvent.Utterance

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
    fun transferPicksLargestOverlap() {
        val target = listOf(
            Utterance(0, "edited a", 0.0, 4.0, speaker = 5),
            Utterance(1, "edited b", 4.0, 6.0),
            Utterance(2, "no overlap", 10.0, 11.0, speaker = 7),
        )
        val tagged = listOf(
            Utterance(0, "x", 0.0, 1.0, speaker = 1),
            Utterance(1, "y", 1.0, 5.5, speaker = 0),
        )
        val out = SpeakerTransfer.transfer(target, tagged)
        assertEquals(listOf(0, 0, 7), out.map { it.speaker })
        assertEquals("edited a", out[0].text)
    }
}
