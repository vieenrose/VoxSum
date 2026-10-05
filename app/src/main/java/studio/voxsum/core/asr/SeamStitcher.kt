package studio.voxsum.core.asr

import studio.voxsum.core.events.TranscriptEvent.Utterance

/**
 * Joins a resumed ASR run onto the frozen transcript it continues. The resumed engine restarts its
 * diarizer (speaker ids start over) and is fed [PREROLL_SEC] of audio BEFORE the seam: those
 * re-recognised utterances overlap ones we already hold, so they tell us which new speaker id is
 * which old one. They are then dropped, leaving the new text to start exactly at the seam.
 */
object SeamStitcher {
    const val PREROLL_SEC = 30.0

    /** Returns the full transcript (prior + new) and how many of its leading utterances are stable. */
    fun stitch(prior: List<Utterance>, seamSec: Double, fresh: List<Utterance>, freshStable: Int): Pair<List<Utterance>, Int> {
        if (prior.isEmpty()) return fresh to freshStable
        val overlap = HashMap<Pair<Int, Int>, Double>()   // (fresh speaker, prior speaker) → seconds
        for (f in fresh) {
            val fs = f.speaker ?: continue
            if (f.startSec >= seamSec) continue
            for (p in prior) {
                val ps = p.speaker ?: continue
                val o = minOf(f.endSec, p.endSec) - maxOf(f.startSec, p.startSec)
                if (o > 0) overlap.merge(fs to ps, o, Double::plus)
            }
        }
        val map = HashMap<Int, Int>()
        val taken = HashSet<Int>()
        overlap.entries.sortedByDescending { it.value }.forEach { (k, _) ->
            if (k.first !in map && k.second !in taken) { map[k.first] = k.second; taken += k.second }
        }
        var nextId = (prior.mapNotNull { it.speaker }.maxOrNull() ?: -1) + 1
        fun speakerOf(s: Int?): Int? = s?.let { map.getOrPut(it) { nextId++ } }

        val kept = ArrayList<Utterance>()
        var keptStable = 0
        fresh.forEachIndexed { i, f ->
            if ((f.startSec + f.endSec) / 2 < seamSec) return@forEachIndexed
            kept += f.copy(speaker = speakerOf(f.speaker), index = prior.size + kept.size)
            if (i < freshStable) keptStable++
        }
        return (prior + kept) to (prior.size + keptStable)
    }
}
