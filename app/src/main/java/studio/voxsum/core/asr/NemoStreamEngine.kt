package studio.voxsum.core.asr

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import studio.voxsum.core.events.TranscriptEvent
import java.io.File

/** On-disk paths of the two GGUFs the engine loads (see ModelManager.asrFiles). */
data class NemoModelFiles(val xasr: File, val diar: File)

/**
 * Streaming ASR + diarization in one pass — nemo-x-asr-diarizer (app/src/main/cpp/nemo): X-ASR
 * (streaming Zipformer2 transducer, zh + en) and Nemotron-3 diarization (streaming Sortformer) on
 * one audio timeline, each word tagged with the speaker whose turn covers it.
 *
 * Words appear ~0.4 s after they are spoken; speaker turns are committed ~5 s behind the audio, so
 * labels near the live edge are provisional. Every emission is a replace-all
 * [TranscriptEvent.UtteranceSnapshot] whose `stable` prefix will not change until the final one.
 */
class NemoStreamEngine(files: NemoModelFiles, threads: Int) : AutoCloseable {

    private var handle: Long = NemoNative.nativeCreate(files.xasr.path, files.diar.path, threads)
        .also { check(it != 0L) { "nemo engine failed to load ${files.xasr.name} / ${files.diar.name}" } }

    /** Distinct speakers in the final snapshot; null until the stream has finished. */
    var speakerCount: Int? = null
        private set

    /**
     * Feed [chunks] (16 kHz mono float) and emit a transcript snapshot every [LIVE_EVERY_SEC] of audio.
     * Each update re-attributes only the unsettled tail (native `Engine::live`), so its cost stays flat
     * however long the recording runs; segments that can no longer change are frozen once and reused.
     * The last snapshot, after end of input, is the full final attribution.
     */
    fun transcribeLive(chunks: Flow<FloatArray>): Flow<TranscriptEvent> = flow {
        val frozen = ArrayList<TranscriptEvent.Utterance>()
        var lastTail: List<TranscriptEvent.Utterance> = emptyList()
        var nextAt = LIVE_EVERY_SEC
        chunks.collect { c ->
            check(NemoNative.nativePush(handle, c, c.size)) { "nemo push failed" }
            val fed = NemoNative.nativeFedSec(handle)
            if (fed >= nextAt) {
                nextAt = fed + LIVE_EVERY_SEC
                val (newlyFrozen, tail) = parseLive(NemoNative.nativeLive(handle), firstIndex = frozen.size)
                frozen += newlyFrozen
                val reTail = tail.mapIndexed { i, u -> u.copy(index = frozen.size + i) }
                if (newlyFrozen.isNotEmpty() || reTail != lastTail) {
                    lastTail = reTail
                    emit(TranscriptEvent.UtteranceSnapshot(frozen + reTail, stable = frozen.size))
                }
            }
        }
        val final = parseSegments(NemoNative.nativeFinish(handle) ?: error("nemo finish failed"))
        speakerCount = final.mapNotNull { it.speaker }.distinct().size.takeIf { it > 0 }
        emit(TranscriptEvent.UtteranceSnapshot(final, stable = final.size))
    }

    override fun close() {
        if (handle != 0L) { NemoNative.nativeFree(handle); handle = 0L }
    }

    companion object {
        /** Audio between live updates. */
        const val LIVE_EVERY_SEC = 0.5

        /** Split a `nativeLive` result (newly frozen segments, GS, tail) and parse both halves;
         *  indices of the frozen ones continue from [firstIndex]. */
        fun parseLive(raw: String, firstIndex: Int): Pair<List<TranscriptEvent.Utterance>, List<TranscriptEvent.Utterance>> {
            val gs = raw.indexOf('\u001d')
            val frozen = parseSegments(if (gs < 0) raw else raw.substring(0, gs), firstIndex)
            val tail = if (gs < 0) emptyList() else parseSegments(raw.substring(gs + 1))
            return frozen to tail
        }

        /** Decode the JNI segment encoding (see nemo_jni.cpp) into utterances. */
        fun parseSegments(raw: String, firstIndex: Int = 0): List<TranscriptEvent.Utterance> {
            val out = ArrayList<TranscriptEvent.Utterance>()
            for (rec in raw.split('\u001e')) {
                if (rec.isEmpty()) continue
                val f = rec.split('\u001f', limit = 4)
                if (f.size < 4) continue
                val text = AsrEngine.cleanTranscript(f[3]).trim()
                if (text.isEmpty()) continue
                out += TranscriptEvent.Utterance(
                    index = firstIndex + out.size,
                    text = text,
                    startSec = f[1].toDouble(),
                    endSec = f[2].toDouble(),
                    speaker = f[0].toInt().takeIf { it >= 0 },
                )
            }
            return out
        }
    }
}

/** JNI surface of libvoxsum-nemo.so. */
internal object NemoNative {
    init { System.loadLibrary("voxsum-nemo") }

    @JvmStatic external fun nativeCreate(xasr: String, diar: String, threads: Int): Long
    @JvmStatic external fun nativePush(handle: Long, pcm: FloatArray, n: Int): Boolean
    @JvmStatic external fun nativeLive(handle: Long): String
    @JvmStatic external fun nativeFinish(handle: Long): String?
    @JvmStatic external fun nativeFedSec(handle: Long): Double
    @JvmStatic external fun nativeFree(handle: Long)
}
