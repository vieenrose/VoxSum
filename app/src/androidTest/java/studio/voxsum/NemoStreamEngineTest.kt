package studio.voxsum

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import studio.voxsum.core.asr.NemoStreamEngine
import studio.voxsum.core.events.TranscriptEvent
import studio.voxsum.core.models.ModelManager
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * On-device check of the streaming ASR + diarization engine: a bundled two-speaker clip streamed in
 * mic-sized 2048-sample blocks (what AudioRecorder emits) must produce text, frequent live snapshots
 * whose stable prefix only grows, and two speakers. Also logs the real-time factor.
 */
@RunWith(AndroidJUnit4::class)
class NemoStreamEngineTest {

    @Test
    fun streamsTwoSpeakerClip() = runBlocking {
        val inst = InstrumentationRegistry.getInstrumentation()
        val models = ModelManager(inst.targetContext)
        if (!models.asrReady()) models.ensureAsrModels { }
        val pcm = readWav16kMono(inst.context.assets.open("two-speaker.wav").use { it.readBytes() })
        val chunks = flow {
            var i = 0
            while (i < pcm.size) { val e = minOf(i + 2048, pcm.size); emit(pcm.copyOfRange(i, e)); i = e }
        }
        var snapshots = 0
        var lastStable = 0
        var stableDecreased = false
        var last: List<TranscriptEvent.Utterance> = emptyList()
        val t0 = System.nanoTime()
        val engine = NemoStreamEngine(models.asrFiles(), threads = 4)
        engine.use {
            engine.transcribeLive(chunks).collect { e ->
                if (e is TranscriptEvent.UtteranceSnapshot) {
                    snapshots++
                    last = e.utterances
                    if (e.stable < lastStable) stableDecreased = true
                    lastStable = e.stable
                }
            }
        }
        val rtf = (System.nanoTime() - t0) / 1e9 / (pcm.size / 16000.0)
        Log.i("NemoStreamEngineTest", "rtf=%.3f snapshots=$snapshots speakers=${engine.speakerCount} text=%s"
            .format(rtf, last.joinToString(" | ") { "${it.speaker}: ${it.text}" }))
        assertTrue("expected text", last.any { it.text.isNotBlank() })
        val audioSec = pcm.size / 16000.0
        // Live view updates every 0.5 s of audio, skipped when nothing changed (silence): demand at
        // least one per 2 s of audio, which the old decaying cadence (fed/60) could not guarantee.
        assertTrue("expected >= 1 snapshot per 2 s of audio, got $snapshots for %.1fs".format(audioSec),
            snapshots >= audioSec.toInt() / 2)
        assertTrue("stable prefix must never shrink during the live view", !stableDecreased)
        assertTrue("final snapshot must be fully stable", lastStable == last.size)
        assertTrue("expected 2 speakers, got ${engine.speakerCount}", engine.speakerCount == 2)
    }

    private fun readWav16kMono(bytes: ByteArray): FloatArray {
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var pos = 12
        while (pos + 8 <= bytes.size) {
            val id = String(bytes, pos, 4, Charsets.US_ASCII)
            val size = bb.getInt(pos + 4)
            if (id == "data") {
                val n = minOf(size, bytes.size - pos - 8) / 2
                return FloatArray(n) { bb.getShort(pos + 8 + 2 * it) / 32768f }
            }
            pos += 8 + size + (size and 1)
        }
        error("no data chunk in wav")
    }
}
