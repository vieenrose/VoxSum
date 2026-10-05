package studio.voxsum

import org.junit.Assert.assertEquals
import studio.voxsum.core.asr.SeamStitcher
import studio.voxsum.core.events.TranscriptEvent.Utterance
import org.junit.Test

class SeamStitcherTest {
    private fun u(i: Int, a: Double, b: Double, s: Int) = Utterance(i, "t$i", a, b, s)

    @Test fun speakersAreMatchedThroughThePreroll() {
        val prior = listOf(u(0, 40.0, 70.0, 0), u(1, 70.0, 90.0, 1))
        // Resumed run: ids swapped (its speaker 0 is the old 1), preroll covers 60–90, then new audio.
        val fresh = listOf(u(0, 60.0, 70.0, 1), u(1, 70.0, 90.0, 0), u(2, 90.0, 100.0, 0), u(3, 100.0, 110.0, 1))
        val (all, stable) = SeamStitcher.stitch(prior, 90.0, fresh, freshStable = 3)
        assertEquals(listOf(0, 1, 2, 3), all.map { it.index })
        assertEquals(listOf(0, 1, 1, 0), all.map { it.speaker!! })
        assertEquals(3, stable)   // prior 2 + the one stable fresh utterance after the seam
    }

    @Test fun aSpeakerUnseenBeforeGetsAFreshId() {
        val prior = listOf(u(0, 0.0, 90.0, 0))
        val fresh = listOf(u(0, 60.0, 90.0, 0), u(1, 90.0, 100.0, 1))
        val (all, _) = SeamStitcher.stitch(prior, 90.0, fresh, 2)
        assertEquals(listOf(0, 1), all.map { it.speaker!! })
    }

    @Test fun noPriorIsAPassThrough() {
        val fresh = listOf(u(0, 0.0, 5.0, 0))
        assertEquals(fresh to 1, SeamStitcher.stitch(emptyList(), 0.0, fresh, 1))
    }
}
