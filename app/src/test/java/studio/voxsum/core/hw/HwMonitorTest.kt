package studio.voxsum.core.hw

import org.junit.Assert.assertEquals
import org.junit.Test

class HwMonitorTest {
    @Test fun parsesUtimeStimeAfterTrickyComm() {
        // comm with a space and a ')' inside: fields must be counted after the LAST ')'.
        val stat = "1234 (voxsum) (x) S 1 1234 0 0 -1 4194560 100 0 0 0 250 50 0 0 20 0 40 0"
        assertEquals(300L, parseStatTicks(stat))
    }

    @Test fun cpuPercentIsShareOfAllCores() {
        // 400 ticks at 100 Hz = 4 s of CPU over 1 s on 8 cores = 50 %.
        assertEquals(50, cpuPercent(400, 100.0, 1000, 8))
        assertEquals(100, cpuPercent(10_000, 100.0, 1000, 8))
        assertEquals(0, cpuPercent(10, 100.0, 0, 8))
    }
}
