package studio.voxsum.core.reader

import studio.voxsum.core.reader.ReaderProtocol as P

/**
 * The live meeting reader (port of `eval/phone_live.py`): transcript lines are fed into ONE
 * growing conversation as they are spoken — prefill only, while people talk — and every ~2,000
 * tokens a reading turn writes up to [ReaderProtocol.MAX_NOTES] typed, cited notes into the journal. The minutes are the
 * journal grouped by type ([ReaderProtocol.minutes]).
 *
 * Windowing reproduces `windows_of` + the segment loop of `phone_live.py` exactly, even though
 * lines arrive one by one: a window closes when the NEXT line would push it past
 * [ReaderProtocol.WINDOW_TOKENS] (or at [finish]); a segment's trailing newline is only decided
 * once the next line shows whether it was the window's last. The same class drives the post-hoc
 * path (a finished transcript fed as fast as it goes).
 *
 * Not thread-safe: call everything from one thread (the reader lane owns it).
 */
class MeetingReader(
    private val llm: ReaderLlm,
    private val systemPrompt: String,
    /** Window/budget sizing. Upstream counts with a Qwen tokenizer; the model's own is close enough
     *  (integration note §4.2). Tests inject a stub. */
    private val count: (String) -> Int = { llm.tokenize(it, false).size },
    private val events: (AgentEvent) -> Unit = {},
    private val clock: () -> Long = System::nanoTime,
) {
    val journal = ArrayList<Note>()
    private val lines = ArrayList<Line>()          // every line fed so far (citation resolution)
    private var k = 0                              // windows opened
    private var windowLines = 0
    private var windowTok = 0
    private var segEnd = 0
    private val segLines = ArrayList<String>()     // open segment
    private var closedSeg: String? = null          // closed segment, trailing "\n" still undecided
    private var restarts = 0
    private var started = false
    private var pieces: Map<String, IntArray> = emptyMap()

    /** Prefill the fresh prefix (system + empty journal). */
    fun start() {
        pieces = mapOf("p0" to P.P0, "p1" to P.P1, "p2" to P.P2, "p3" to P.P3)
            .mapValues { llm.tokenize(it.value, true) }
        events(AgentEvent.State(AgentState.STARTING))
        prefillFresh(P.JOURNAL_EMPTY)
        started = true
        events(AgentEvent.State(AgentState.LISTENING, ctxTokens = llm.seqLength()))
    }

    /** Feed one stable transcript line (in order). May run a reading turn. */
    fun offer(line: Line) {
        check(started) { "start() first" }
        val t = count(line.render())
        if (windowLines > 0 && windowTok + t > P.WINDOW_TOKENS) closeWindow()
        if (windowLines == 0) openWindow(line)
        // The previous segment was not the window's last: it takes its newline and is prefilled now.
        closedSeg?.let { append(it + "\n", special = false, what = "segment"); closedSeg = null }
        lines += line
        windowLines++
        windowTok += t
        segLines += line.render()
        if (line.startS >= segEnd) {
            closedSeg = segLines.joinToString("\n")
            segLines.clear()
            segEnd = line.startS + P.SEGMENT_S
        }
    }

    /** End of meeting: read the last partial window. Returns the minutes. */
    fun finish(): String {
        if (windowLines > 0) closeWindow()
        // Reading is over; the summary and title calls follow (the caller reports DONE after them).
        events(AgentEvent.State(AgentState.SUMMARIZING, ctxTokens = llm.seqLength(), notes = journal.size))
        return P.minutes(journal)
    }

    private fun openWindow(first: Line) {
        if (llm.seqLength() + 2 * P.WINDOW_TOKENS + P.READ_MAX + 600 > P.CTX_BUDGET) restart()
        k++
        windowTok = 0
        segEnd = first.startS + P.SEGMENT_S
        append(P.windowHeader(k), special = false, what = "window header")
        events(AgentEvent.State(AgentState.LISTENING, window = k, ctxTokens = llm.seqLength(), notes = journal.size))
    }

    private fun closeWindow() {
        // The last segment of the window goes in without a trailing newline.
        val last = closedSeg ?: segLines.joinToString("\n")
        closedSeg = null
        segLines.clear()
        if (last.isNotEmpty()) append(last, special = false, what = "segment")
        events(AgentEvent.State(AgentState.READING, window = k, ctxTokens = llm.seqLength(), notes = journal.size))
        val t0 = clock()
        llm.append(pieces.getValue("p2"))
        val reply = llm.generateContinue(P.READ_MAX, P.STOP, P.TEMP) { events(AgentEvent.TurnToken(k, it)) }
        val kept = parse(reply)
        llm.append(pieces.getValue("p3"))
        events(AgentEvent.TurnDone(k, reply, kept, (clock() - t0) / 1_000_000))
        windowLines = 0
        windowTok = 0
        events(AgentEvent.State(AgentState.LISTENING, window = k, ctxTokens = llm.seqLength(), notes = journal.size))
    }

    /**
     * phone_live.py's reply parsing + the deployed guards. Returns the notes kept.
     *
     * Deviation from upstream: when a window yields more than [ReaderProtocol.MAX_NOTES] notes,
     * upstream keeps the first ones in reply order — so a meeting's closing to-do round-up, read
     * last, lost every ACTION. Here the cap keeps decisions and actions first, then numbers, open
     * issues and the rest. Surplus decisions/actions keep the newest (the round-up comes last); other
     * types keep upstream's reply order. Kept notes stay in reply order.
     */
    private fun parse(reply: String): Int {
        val cands = ArrayList<Pair<String, Note>>()   // raw line → note, past parse/citation/dup checks
        for (raw in reply.lines()) {
            val m = P.ACT.find(raw) ?: continue
            if (m.groupValues[1] != "NOTE") continue
            val n = P.NOTE.find(m.groupValues[2].trim())
            if (n == null) { events(AgentEvent.NoteDropped(k, raw.trim(), DropReason.PARSE)); continue }
            val (ts, tagRaw, text) = n.destructured
            val tag = tagRaw.ifEmpty { null }
            val seen = journal.takeLast(P.DUP_LOOKBACK).map { it.text } + cands.map { it.second.text }
            val reason = when {
                resolve(ts) == null -> DropReason.CITATION
                seen.takeLast(P.DUP_LOOKBACK).any { P.similar(text, it) > P.DUP_JACCARD } -> DropReason.DUPLICATE
                else -> null
            }
            if (reason != null) { events(AgentEvent.NoteDropped(k, raw.trim(), reason)); continue }
            cands += raw.trim() to Note(0, k, ts, tag, text)
        }
        val keep = cands.indices
            .sortedWith(compareBy<Int>({ capRank(cands[it].second.tag) }, { if (capRank(cands[it].second.tag) == 0) -it else it }))
            .take(P.MAX_NOTES).toSet()
        var kept = 0
        for ((i, c) in cands.withIndex()) {
            if (i !in keep) { events(AgentEvent.NoteDropped(k, c.first, DropReason.CAP)); continue }
            val note = c.second.copy(id = journal.size + 1)
            journal += note
            kept++
            events(AgentEvent.NoteKept(note))
        }
        return kept
    }

    private fun capRank(tag: String?): Int = when (tag?.uppercase()) {
        "DECISION", "ACTION" -> 0
        "NUMBER" -> 1
        "OPEN-ISSUE" -> 2
        else -> 3
    }

    /** ingest.resolve_citation: the earliest fed line starting at [ts], or null (invented). */
    private fun resolve(ts: String): Int? {
        val target = P.parseTs(ts) ?: return null
        return lines.indexOfFirst { it.startS == target }.takeIf { it >= 0 }
    }

    private fun restart() {
        val before = llm.seqLength()
        events(AgentEvent.State(AgentState.RESTARTING, window = k, ctxTokens = before, notes = journal.size))
        llm.reset()
        val compacted = P.compact(journal, count)
        prefillFresh(compacted)
        restarts++
        events(AgentEvent.Restart(restarts, before, llm.seqLength()))
    }

    private fun prefillFresh(journalText: String) {
        val toks = pieces.getValue("p0") + llm.tokenize(systemPrompt, false) + pieces.getValue("p1") +
            llm.tokenize(P.JOURNAL_HEADER + journalText, false) + pieces.getValue("p2") +
            llm.tokenize("NEXT", false) + pieces.getValue("p3")
        timedAppend(toks, "prefix")
    }

    private fun append(text: String, special: Boolean, what: String) =
        timedAppend(llm.tokenize(text, special), what)

    private fun timedAppend(toks: IntArray, what: String) {
        val t0 = clock()
        check(llm.append(toks) >= 0) { "reader: prefill failed ($what)" }
        events(AgentEvent.Fed(k, what, toks.size, (clock() - t0) / 1_000_000, llm.seqLength()))
    }
}

/** The same event with every piece of model-written text passed through [f] (script conversion). */
fun AgentEvent.mapText(f: (String) -> String): AgentEvent = when (this) {
    is AgentEvent.TurnToken -> copy(piece = f(piece))
    is AgentEvent.TurnDone -> copy(reply = f(reply))
    is AgentEvent.NoteKept -> copy(note = note.copy(text = f(note.text)))
    is AgentEvent.NoteDropped -> copy(line = f(line))
    else -> this
}

enum class AgentState { STARTING, LISTENING, READING, RESTARTING, SUMMARIZING, DONE }

enum class DropReason { PARSE, CITATION, CAP, DUPLICATE }

/** What the agent is doing, for the live Agent panel. */
sealed interface AgentEvent {
    data class State(
        val state: AgentState, val window: Int = 0, val ctxTokens: Int = 0, val notes: Int = 0,
    ) : AgentEvent
    /** A prefill: [what] = prefix / window header / segment. */
    data class Fed(val window: Int, val what: String, val tokens: Int, val ms: Long, val ctxTokens: Int) : AgentEvent
    data class TurnToken(val window: Int, val piece: String) : AgentEvent
    data class TurnDone(val window: Int, val reply: String, val kept: Int, val ms: Long) : AgentEvent
    data class NoteKept(val note: Note) : AgentEvent
    data class NoteDropped(val window: Int, val line: String, val reason: DropReason) : AgentEvent
    data class Restart(val count: Int, val ctxBefore: Int, val ctxAfter: Int) : AgentEvent
}
