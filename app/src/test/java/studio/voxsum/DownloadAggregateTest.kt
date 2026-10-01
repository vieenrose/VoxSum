package studio.voxsum

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.voxsum.core.models.DownloadAggregate

class DownloadAggregateTest {
    @Test fun aloneItReportsItsOwnFraction() {
        val d = DownloadAggregate()
        d.begin("llm", 3_000)
        val (f, shared) = d.update("llm", 0.4f)
        assertEquals(0.4f, f, 1e-6f)
        assertFalse(shared)
    }

    @Test fun overlappingDownloadsShareOneBarWeightedByBytes() {
        val d = DownloadAggregate()
        d.begin("asr", 275); d.begin("llm", 3_300)
        var last = 0f
        // the small speech model races ahead, then the big one carries the bar
        for (a in listOf(0.2f, 0.6f, 1.0f)) { val (f, s) = d.update("asr", a); assertTrue(s); assertTrue(f >= last); last = f }
        assertTrue("speech alone is only ~8 % of the bytes", last < 0.1f)
        for (l in listOf(0.1f, 0.5f, 0.9f, 1.0f)) { val (f, _) = d.update("llm", l); assertTrue("never goes back", f >= last); last = f }
        assertEquals(1f, last, 1e-6f)
    }

    @Test fun aFinishedDownloadKeepsCountingUntilTheBurstEnds() {
        val d = DownloadAggregate()
        d.begin("asr", 100); d.begin("llm", 100)
        d.update("asr", 1f); d.end("asr")
        val (f, shared) = d.update("llm", 0f)
        assertEquals(0.5f, f, 1e-6f)          // not back to 0
        assertFalse(shared)                   // only the reader is still running
        d.end("llm")
        d.begin("llm", 100)                   // a new burst starts from zero
        assertEquals(0f, d.update("llm", 0f).first, 1e-6f)
    }

    @Test fun idleOnlyWhenEveryDownloadOfTheBurstHasEnded() {
        val d = DownloadAggregate()
        assertTrue(d.isIdle())
        d.begin("asr", 10); d.begin("llm", 10)
        assertFalse(d.isIdle())
        d.end("asr"); assertFalse(d.isIdle())
        d.end("llm"); assertTrue(d.isIdle())
    }
}
