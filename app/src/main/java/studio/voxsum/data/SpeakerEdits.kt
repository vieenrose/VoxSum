package studio.voxsum.data

import studio.voxsum.core.events.TranscriptEvent

/**
 * Pure speaker-correction ops for fixing diarization mistakes: move one line to another speaker, or
 * merge a whole speaker into another. Both are plain relabels of [TranscriptEvent.Utterance.speaker]
 * (no embeddings needed — nothing downstream consumes centroids after diarization). Ids are NOT
 * renumbered: the labels and colours the user is looking at must not change under them ("merge
 * into 語者 2" used to yield "語者 1", and 語者 3 became "語者 2"). The `.ogg` round-trips the
 * corrected ints losslessly. Returns new (utterances, speakerNames); callers apply to their state.
 */
object SpeakerEdits {

    fun reassign(
        utts: List<TranscriptEvent.Utterance>,
        names: Map<Int, SpeakerName>,
        index: Int,
        target: Int,
    ): Pair<List<TranscriptEvent.Utterance>, Map<Int, SpeakerName>> {
        if (index !in utts.indices) return utts to names
        val old = utts[index].speaker
        if (old == target) return utts to names
        val moved = utts.toMutableList().also { it[index] = it[index].copy(speaker = target) }
        // If the source speaker has no lines left, drop its name too.
        val names2 = if (old != null && moved.none { it.speaker == old }) names - old else names
        return moved to names2
    }

    fun merge(
        utts: List<TranscriptEvent.Utterance>,
        names: Map<Int, SpeakerName>,
        from: Int,
        into: Int,
    ): Pair<List<TranscriptEvent.Utterance>, Map<Int, SpeakerName>> {
        if (from == into) return utts to names
        val merged = utts.map { if (it.speaker == from) it.copy(speaker = into) else it }
        return merged to (names - from)
    }
}
