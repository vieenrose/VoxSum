package studio.voxsum

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import studio.voxsum.core.asr.NemoStreamEngine
import studio.voxsum.core.events.TranscriptEvent
import studio.voxsum.core.llm.LlmEngine
import studio.voxsum.core.llm.TextGen
import studio.voxsum.core.models.LlmRegistry
import studio.voxsum.core.models.ModelManager
import studio.voxsum.core.reader.AgentEvent
import studio.voxsum.core.reader.ReaderLane
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The three concurrent lanes on a real phone: a meeting WAV is replayed into NemoStreamEngine at
 * real-time speed (mic-sized 2048-sample blocks, paced), and the reader reads its stable
 * utterances while ASR + diarization run. Logs per-window reading lag, ASR lag behind real time,
 * RSS, and the minutes. Models must be provisioned (seeded) in the app's files/models.
 *
 *   scripts/test-on-device.sh <serial> -- -e class studio.voxsum.LiveReaderDeviceTest \
 *       -e wav /data/local/tmp/meeting.wav -e speed 1
 */
@RunWith(AndroidJUnit4::class)
class LiveReaderDeviceTest {
    @Test
    fun threeLanesKeepUp() = runBlocking {
        val inst = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        val wavPath = args.getString("wav") ?: "/data/local/tmp/meeting.wav"
        val speed = (args.getString("speed") ?: "1").toDouble()
        val threads = (args.getString("threads") ?: "2").toInt()
        val models = ModelManager(inst.targetContext)
        check(models.asrReady()) { "seed files/models/nemo first" }
        val spec = LlmRegistry.byId(LlmRegistry.DEFAULT_ID)
        check(models.llmReady(spec)) { "seed files/models/${spec.dirName} first" }

        val pcm = readWav(File(wavPath).readBytes())
        val audioSec = pcm.size / 16000.0
        val t0 = System.nanoTime()
        fun now() = (System.nanoTime() - t0) / 1e9

        val windows = ArrayList<String>()
        var windowClosedAt = 0.0
        val engine = LlmEngine.load(
            models.llmFile(spec).absolutePath, nThreads = threads, nCtx = spec.maxCtx,
            sampler = spec.sampler, kvQ8 = TextGen.KV_Q8, swaFull = spec.swaFull,
        )
        val system = File(models.llmDir(spec), LlmRegistry.SYSTEM_PROMPT_FILE).readText()
        val loadS = now()
        val lane = ReaderLane(engine, system) { e ->
            when (e) {
                is AgentEvent.State -> if (e.state == studio.voxsum.core.reader.AgentState.READING) windowClosedAt = now()
                is AgentEvent.TurnDone -> {
                    val line = "window ${e.window}: turn %.1f s, lag %.1f s, +${e.kept} notes, at audio %.0f s"
                        .format(e.ms / 1000.0, now() - windowClosedAt, now() * speed)
                    windows += line
                    Log.i(TAG, line)
                }
                is AgentEvent.Restart -> Log.i(TAG, "restart #${e.count}: ctx ${e.ctxBefore} -> ${e.ctxAfter}")
                else -> Unit
            }
        }
        lane.start()

        var asrMaxBehind = 0.0
        var fed = 0
        val chunks = flow {
            var i = 0
            while (i < pcm.size) {
                val end = minOf(i + 2048, pcm.size)
                val due = i / 16000.0 / speed
                val wait = due - (now() - loadS)
                if (wait > 0) delay((wait * 1000).toLong())
                emit(pcm.copyOfRange(i, end))
                fed = end
                i = end
            }
        }
        var last: TranscriptEvent.UtteranceSnapshot? = null
        NemoStreamEngine(models.asrFiles(), threads).use { asr ->
            asr.transcribeLive(chunks).collect { e ->
                if (e is TranscriptEvent.UtteranceSnapshot) {
                    last = e
                    lane.feed(e)
                    val behind = (now() - loadS) - fed / 16000.0 / speed
                    if (behind > asrMaxBehind) asrMaxBehind = behind
                }
            }
        }
        val asrDoneS = now()
        val result = lane.finish(last?.utterances.orEmpty())
        val doneS = now()
        lane.close(); engine.close()
        val rss = File("/proc/self/status").readLines().firstOrNull { it.startsWith("VmHWM") }
        Log.i(TAG, "audio %.0f s at %.1fx, model load %.1f s, ASR done at %.1f s, minutes ready %.1f s after the end of audio, ASR max behind %.1f s, $rss"
            .format(audioSec, speed, loadS, asrDoneS - loadS, doneS - asrDoneS, asrMaxBehind))
        windows.forEach { Log.i(TAG, it) }
        Log.i(TAG, "MINUTES\n" + result.minutes)
        assertTrue("reader wrote no notes", result.journal.isNotEmpty())
    }

    private fun readWav(bytes: ByteArray): FloatArray {
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
        error("no data chunk")
    }

    private companion object { const val TAG = "LiveReaderDeviceTest" }
}
