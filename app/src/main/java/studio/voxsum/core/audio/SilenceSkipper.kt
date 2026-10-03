package studio.voxsum.core.audio

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * Shortens long silences before a FILE reaches the speech engine, which otherwise spends real time
 * on them (~1× real time on the emulator; a recording left running after the meeting, or a talk
 * with long pauses, paid for every silent second). Each pause keeps its first [keepSec] seconds,
 * so the recognizer and diarizer still see a gap; the rest is not fed. [toOriginal] maps a time
 * in the fed (shortened) stream back to the original audio, so timestamps stay tap-to-play.
 *
 * Only quiet chunks are skipped (peak below [threshold]); a noisy room simply skips nothing.
 */
class SilenceSkipper(
    private val sampleRate: Int = 16_000,
    // The engine needs several seconds of silence to emit a sentence's last characters and close the
    // turn (ASR latency + ~5 s diarization settle): with 1.5 or 3 s kept, the sentences on both
    // sides of a long pause came out joined, the second one stamped before the pause.
    private val keepSec: Double = 8.0,
    private val threshold: Float = 0.01f,
) {
    /** (fed time where a cut happened, total seconds skipped up to and including that cut). */
    private val cuts = ArrayList<Pair<Double, Double>>()
    private var fedSamples = 0L
    private var silentRun = 0L
    private var skipped = 0L
    private var cutOpen = false

    /** Seconds not fed so far. */
    val skippedSec: Double get() = skipped.toDouble() / sampleRate

    fun apply(chunks: Flow<FloatArray>): Flow<FloatArray> = flow {
        val keep = (keepSec * sampleRate).toLong()
        chunks.collect { c ->
            var peak = 0f
            for (v in c) { val a = if (v < 0f) -v else v; if (a > peak) peak = a }
            if (peak < threshold) {
                silentRun += c.size
                if (silentRun > keep) {
                    skipped += c.size
                    val at = fedSamples.toDouble() / sampleRate
                    synchronized(cuts) {
                        if (cutOpen) cuts[cuts.size - 1] = at to skippedSec else { cuts += at to skippedSec; cutOpen = true }
                    }
                    return@collect
                }
            } else {
                silentRun = 0
                cutOpen = false
            }
            fedSamples += c.size
            emit(c)
        }
    }

    /** The original-audio time of [fedSec], a time in the stream the engine was fed. */
    fun toOriginal(fedSec: Double): Double = synchronized(cuts) {
        var add = 0.0
        for ((at, total) in cuts) { if (at <= fedSec + 1e-6) add = total else break }
        fedSec + add
    }
}
