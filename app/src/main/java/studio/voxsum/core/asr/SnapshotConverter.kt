package studio.voxsum.core.asr

import studio.voxsum.core.events.TranscriptEvent

/**
 * Applies the transcript script conversion (OpenCC s2tw) to live snapshots at O(changed) cost: an
 * utterance identical to the one at the same position in the previous snapshot reuses its converted
 * copy, so a long recording only converts the provisional tail each update. One instance per
 * streaming run.
 */
class SnapshotConverter(
    private val convert: ((String) -> String)?,
) {
    private var lastRaw: List<TranscriptEvent.Utterance> = emptyList()
    private var lastOut: List<TranscriptEvent.Utterance> = emptyList()

    fun apply(e: TranscriptEvent.UtteranceSnapshot): TranscriptEvent.UtteranceSnapshot {
        val out = e.utterances.mapIndexed { i, u ->
            if (i < lastRaw.size && lastRaw[i] == u) lastOut[i]
            else u.copy(
                text = convert?.invoke(u.text) ?: u.text,
            )
        }
        lastRaw = e.utterances
        lastOut = out
        return TranscriptEvent.UtteranceSnapshot(out, e.stable)
    }
}
