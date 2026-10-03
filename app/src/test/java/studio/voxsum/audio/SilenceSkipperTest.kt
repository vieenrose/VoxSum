package studio.voxsum.audio

import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import studio.voxsum.core.audio.SilenceSkipper

class SilenceSkipperTest {

    private fun chunk(loud: Boolean) = FloatArray(1600) { if (loud) 0.5f else 0f }   // 0.1 s at 16 kHz

    @Test
    fun longSilenceIsShortenedAndTimesMapBack() = runBlocking {
        // 2 s speech, 10 s silence, 2 s speech.
        val input = List(20) { chunk(true) } + List(100) { chunk(false) } + List(20) { chunk(true) }
        val s = SilenceSkipper(keepSec = 1.5)
        val fed = s.apply(input.asFlow()).toList()

        assertEquals(20 + 15 + 20, fed.size)             // the pause keeps its first 1.5 s
        assertEquals(8.5, s.skippedSec, 1e-9)
        assertEquals(1.0, s.toOriginal(1.0), 1e-9)       // before the pause: unchanged
        assertEquals(3.0, s.toOriginal(3.0), 1e-9)       // inside the kept part of the pause
        assertEquals(12.0, s.toOriginal(3.5), 1e-9)      // second speech starts at 12 s in the original
        assertEquals(13.0, s.toOriginal(4.5), 1e-9)
    }

    @Test
    fun noisyAudioIsNotTouched() = runBlocking {
        val input = List(50) { FloatArray(1600) { 0.05f } }
        val s = SilenceSkipper()
        assertEquals(50, s.apply(input.asFlow()).toList().size)
        assertEquals(7.0, s.toOriginal(7.0), 1e-9)
    }
}
