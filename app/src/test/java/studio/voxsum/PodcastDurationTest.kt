package studio.voxsum

import org.junit.Assert.assertEquals
import org.junit.Test
import studio.voxsum.online.formatDuration

class PodcastDurationTest {
    @Test fun plainSecondsBecomeClockTime() {
        assertEquals("51:20", formatDuration("3080"))
        assertEquals("1:02:05", formatDuration("3725"))
    }
    @Test fun clockTimeAndBlankAreKept() {
        assertEquals("01:02:03", formatDuration("01:02:03"))
        assertEquals("", formatDuration(""))
    }
}
