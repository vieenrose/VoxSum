package studio.voxsum

import org.junit.Assert.assertEquals
import org.junit.Test
import studio.voxsum.core.events.TranscriptEvent
import studio.voxsum.data.SpeakerEdits
import studio.voxsum.data.SpeakerName

/** Pins the speaker-correction relabel + contiguous-renumber logic that merge/reassign rely on. */
class SpeakerEditsTest {

    private fun spk(vararg ids: Int?) = ids.mapIndexed { i, s ->
        TranscriptEvent.Utterance(index = i, text = "t$i", startSec = i.toDouble(), endSec = i + 1.0, speaker = s)
    }
    private fun name(n: String) = SpeakerName(n, "user", "")

    @Test fun mergeRelabels() {
        val utts = spk(0, 1, 2, 1)
        val names = mapOf(0 to name("A"), 1 to name("B"), 2 to name("C"))
        val (u2, n2) = SpeakerEdits.merge(utts, names, from = 2, into = 0)
        assertEquals(listOf(0, 1, 0, 1), u2.map { it.speaker })   // 2→0
        assertEquals(setOf(0, 1), n2.keys)                         // C dropped
        assertEquals("A", n2[0]?.name); assertEquals("B", n2[1]?.name)
    }

    @Test fun mergeKeepsTheOtherSpeakersIds() {
        val utts = spk(0, 1, 2)
        val names = mapOf(0 to name("A"), 1 to name("B"), 2 to name("C"))
        val (u2, n2) = SpeakerEdits.merge(utts, names, from = 0, into = 1)  // "merge 語者 1 into 語者 2"
        assertEquals(listOf(1, 1, 2), u2.map { it.speaker })                // stays 語者 2; 語者 3 stays 語者 3
        assertEquals(setOf(1, 2), n2.keys)
        assertEquals("B", n2[1]?.name); assertEquals("C", n2[2]?.name)
    }

    @Test fun reassignMovesOneLineAndDropsEmptiedSpeaker() {
        val utts = spk(0, 1)
        val names = mapOf(0 to name("A"), 1 to name("B"))
        val (u2, n2) = SpeakerEdits.reassign(utts, names, index = 1, target = 0)  // speaker 1 now empty
        assertEquals(listOf(0, 0), u2.map { it.speaker })
        assertEquals(setOf(0), n2.keys)
    }

    @Test fun reassignKeepsSpeakerStillInUse() {
        val utts = spk(0, 1, 1)
        val names = mapOf(1 to name("B"))
        val (u2, n2) = SpeakerEdits.reassign(utts, names, index = 2, target = 0)  // speaker 1 still has line 1
        assertEquals(listOf(0, 1, 0), u2.map { it.speaker })
        assertEquals(setOf(1), n2.keys)
    }

    @Test fun mergeIntoSelfIsNoOp() {
        val utts = spk(0, 1)
        val names = mapOf(0 to name("A"), 1 to name("B"))
        val (u2, n2) = SpeakerEdits.merge(utts, names, from = 0, into = 0)
        assertEquals(utts.map { it.speaker }, u2.map { it.speaker })
        assertEquals(names, n2)
    }
}
