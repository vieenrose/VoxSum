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
 * labels near the live edge are provisional. Every emission is therefore a replace-all
 * [TranscriptEvent.UtteranceSnapshot]; the last one (after end of input) is final.
 */
class NemoStreamEngine(files: NemoModelFiles, threads: Int) : AutoCloseable {

    private var handle: Long = NemoNative.nativeCreate(files.xasr.path, files.diar.path, threads)
        .also { check(it != 0L) { "nemo engine failed to load ${files.xasr.name} / ${files.diar.name}" } }

    /** Distinct speakers in the final snapshot; null until the stream has finished. */
    var speakerCount: Int? = null
        private set

    /**
     * Feed [chunks] (16 kHz mono float) and emit transcript snapshots as they change. Snapshots are
     * spaced by at least [SNAPSHOT_MIN_SEC] of audio and by 1/[SNAPSHOT_FRACTION] of what has been
     * fed so far: re-attribution walks the whole timeline, so a fixed period would make a long
     * meeting quadratic.
     */
    fun transcribeLive(chunks: Flow<FloatArray>): Flow<TranscriptEvent> = flow {
        var lastSnapAt = 0.0
        var lastText: List<TranscriptEvent.Utterance> = emptyList()
        chunks.collect { c ->
            check(NemoNative.nativePush(handle, c, c.size)) { "nemo push failed" }
            val fed = NemoNative.nativeFedSec(handle)
            if (fed - lastSnapAt >= maxOf(SNAPSHOT_MIN_SEC, fed / SNAPSHOT_FRACTION)) {
                lastSnapAt = fed
                val snap = parseSegments(NemoNative.nativeSnapshot(handle))
                if (snap != lastText) { lastText = snap; emit(TranscriptEvent.UtteranceSnapshot(snap)) }
            }
        }
        val final = parseSegments(NemoNative.nativeFinish(handle) ?: error("nemo finish failed"))
        speakerCount = final.mapNotNull { it.speaker }.distinct().size.takeIf { it > 0 }
        emit(TranscriptEvent.UtteranceSnapshot(final))
    }

    override fun close() {
        if (handle != 0L) { NemoNative.nativeFree(handle); handle = 0L }
    }

    companion object {
        const val SNAPSHOT_MIN_SEC = 1.0
        const val SNAPSHOT_FRACTION = 60.0

        /** Decode the JNI segment encoding (see nemo_jni.cpp) into utterances. */
        fun parseSegments(raw: String): List<TranscriptEvent.Utterance> {
            val out = ArrayList<TranscriptEvent.Utterance>()
            for (rec in raw.split('\u001e')) {
                if (rec.isEmpty()) continue
                val f = rec.split('\u001f', limit = 4)
                if (f.size < 4) continue
                val text = AsrEngine.cleanTranscript(f[3]).trim()
                if (text.isEmpty()) continue
                out += TranscriptEvent.Utterance(
                    index = out.size,
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
    @JvmStatic external fun nativeSnapshot(handle: Long): String
    @JvmStatic external fun nativeFinish(handle: Long): String?
    @JvmStatic external fun nativeFedSec(handle: Long): Double
    @JvmStatic external fun nativeFree(handle: Long)
}
