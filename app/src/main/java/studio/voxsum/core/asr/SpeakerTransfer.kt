package studio.voxsum.core.asr

import studio.voxsum.core.events.TranscriptEvent

/**
 * Moves speaker tags from a fresh engine pass onto an existing (possibly user-edited) transcript:
 * each utterance takes the speaker whose segments overlap its time span the most, and keeps its
 * text. Utterances no segment overlaps keep their old tag.
 */
object SpeakerTransfer {
    fun transfer(
        target: List<TranscriptEvent.Utterance>,
        tagged: List<TranscriptEvent.Utterance>,
    ): List<TranscriptEvent.Utterance> = target.map { u ->
        val overlap = HashMap<Int, Double>()
        for (s in tagged) {
            val spk = s.speaker ?: continue
            val o = minOf(u.endSec, s.endSec) - maxOf(u.startSec, s.startSec)
            if (o > 0) overlap.merge(spk, o, Double::plus)
        }
        overlap.maxByOrNull { it.value }?.let { u.copy(speaker = it.key) } ?: u
    }
}
