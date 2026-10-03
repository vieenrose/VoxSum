package studio.voxsum.core.reader

/**
 * The meeting reader's protocol, ported from github.com/vieenrose/meeting-summarizer
 * (`eval/phone_live.py`, `eval/realtime_agent.py` harness v3, `summarizer/ingest.py`). The model was
 * fine-tuned on exactly this text: every string, regex and threshold here is a port, not a
 * design choice. Change one only against a re-measurement upstream.
 */
object ReaderProtocol {
    // phone_live.py
    const val WINDOW_TOKENS = 2000          // realtime_agent.WINDOW_TOKENS
    const val READ_MAX = 400
    const val RESTART_BUDGET = 2500         // compacted-journal budget on restart
    const val MAX_NOTES = 6
    const val SEGMENT_S = 20                // feed granularity (meeting seconds)
    const val CTX_BUDGET = 8192             // restart when the conversation would pass this (note §4.4)
    const val TEMP = 0.2f
    const val STOP = "\nNEXT"
    const val DUP_LOOKBACK = 30
    const val DUP_JACCARD = 0.6

    // Gemma 4 chat template pieces (thinking off), note §4.1 — what phone_live.py derives from the
    // GGUF's own template via /apply-template: before system, system->user, user->model,
    // model->next user.
    const val P0 = "<bos><|turn>system\n"
    const val P1 = "<turn|>\n<|turn>user\n"
    const val P2 = "<turn|>\n<|turn>model\n"
    const val P3 = "<turn|>\n<|turn>user\n"

    const val JOURNAL_HEADER = "## 筆記本（至今）\n"
    const val JOURNAL_EMPTY = "（尚無筆記）"
    fun windowHeader(k: Int) = "## 逐字稿片段 $k\n"
    fun omitted(n: Int) = "\n（另有 $n 則較早的筆記未列出）"

    // journal_agent.ACT, realtime_agent.NOTE
    val ACT = Regex("""^\s*(NOTE|REVISE|LOOKBACK|NEXT)\b(.*)$""")
    val NOTE = Regex("""^\s*\[?(\d+:\d{2}(?::\d{2})?)\]?\s*(?:\((\w[\w-]*)\)\s*)?(.+)$""")

    /** ingest.format_ts: `M:SS` under an hour, `H:MM:SS` from an hour on. */
    fun formatTs(seconds: Int): String {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }

    /** Inverse of [formatTs]; null when not a timestamp. */
    fun parseTs(ts: String): Int? {
        val p = ts.split(":").map { it.toIntOrNull() ?: return null }
        return when (p.size) {
            2 -> p[0] * 60 + p[1]
            3 -> p[0] * 3600 + p[1] * 60 + p[2]
            else -> null
        }
    }

    private val LINE = Regex("""^\[(\d+:\d{2}(?::\d{2})?)\]\s*(.*)$""")
    private val SPEAKER = Regex("""S\d+|[^\s:]{1,20}""")

    /** ingest.parse_line: `[ts] speaker: text`, speaker optional; null for a non-transcript line. */
    fun parseLine(raw: String): Line? {
        val m = LINE.find(raw.trim()) ?: return null
        val start = parseTs(m.groupValues[1]) ?: return null
        val rest = m.groupValues[2]
        val i = rest.indexOf(": ")
        return if (i > 0 && SPEAKER.matches(rest.substring(0, i))) Line(start, rest.substring(0, i), rest.substring(i + 2))
        else Line(start, null, rest)
    }

    private val NON_SPEECH_TAG = Regex("""\[[A-Za-z][A-Za-z _-]*\]""")
    private val FILLER = Regex("""(?:(?<=^)|(?<=[，。！？、\s]))[嗯啊呃]+[，。、]?""")
    private val WS = Regex("""\s+""")

    /** ingest.clean_text. */
    fun cleanText(text: String): String =
        WS.replace(FILLER.replace(NON_SPEECH_TAG.replace(text, ""), ""), " ").trim()

    /** realtime_agent.similar: character-bigram Jaccard. */
    fun similar(a: String, b: String): Double {
        fun bg(t: String): Set<String> = (0 until t.length - 1).map { t.substring(it, it + 2) }.toSet()
        val x = bg(a)
        val y = bg(b)
        return (x intersect y).size.toDouble() / maxOf(1, (x union y).size)
    }

    /** conversion_prompts.compact_notes: the notes a small context can take for the title and prose
     *  calls — decisions, then open issues, then actions, newest first within each, then the rest
     *  newest first, each costing its text length + 24 characters, kept in chronological order. */
    fun compactNotes(notes: List<Note>, budgetChars: Int): List<Note> {
        val key = mapOf("DECISION" to 0, "OPEN-ISSUE" to 1, "ACTION" to 2)
        val order = notes.indices.sortedWith(compareBy<Int>({ key[notes[it].tag?.uppercase()] ?: 3 }, { -it }))
        val chosen = HashSet<Int>()
        var used = 0
        for (i in order) {
            val t = notes[i].text.length + 24
            if (used + t <= budgetChars) { chosen += i; used += t }
        }
        return chosen.sorted().map { notes[it] }
    }

    /** realtime_agent.render. */
    fun render(n: Note): String = "#${n.id} [${n.ts}] " + (n.tag?.let { "($it) " } ?: "") + n.text

    /** phone_live.compact: DECISION, then OPEN-ISSUE, then ACTION, newest first within each, then
     *  the rest newest first, within [RESTART_BUDGET] tokens; kept in chronological order. */
    fun compact(journal: List<Note>, count: (String) -> Int, budget: Int = RESTART_BUDGET): String {
        val key = mapOf("DECISION" to 0, "OPEN-ISSUE" to 1, "ACTION" to 2)
        val order = journal.indices.sortedWith(
            compareBy<Int>({ key[journal[it].tag?.uppercase()] ?: 3 }, { -it }),
        )
        val chosen = HashSet<Int>()
        var used = 0
        for (i in order) {
            val t = count(render(journal[i]))
            if (used + t <= budget) { chosen += i; used += t }
        }
        val rest = journal.size - chosen.size
        val text = chosen.sorted().joinToString("\n") { render(journal[it]) } + (if (rest > 0) omitted(rest) else "")
        return text.ifEmpty { JOURNAL_EMPTY }
    }

    // v5 order (integration note §4.5): 討論要點 (PROPOSAL) sits before 重要數字.
    private val SECTIONS = listOf(
        "決議事項" to "DECISION", "待辦與負責人" to "ACTION", "保留與未決" to "OPEN-ISSUE",
        "討論要點" to "PROPOSAL", "重要數字" to "NUMBER",
    )

    // realtime_agent.PROPOSAL_CUE and the "really decided" words (v5 proposal guard, note §4.8).
    private val PROPOSAL_CUE = Regex("""^(建議|提議|可以|可考慮|考慮|希望|應該|應|或許|是否|討論|研議)|建議|提議|可考慮""")
    private val DECIDED = Regex("""通過|決定|決議|同意|定案""")

    /** realtime_agent.reclassify_proposals: a DECISION or ACTION worded as a suggestion, with no
     *  word saying it was decided, is a PROPOSAL. Applied when the minutes are assembled. */
    fun reclassify(n: Note): Note {
        val tag = n.tag?.uppercase()
        return if ((tag == "DECISION" || tag == "ACTION") && PROPOSAL_CUE.containsMatchIn(n.text) && !DECIDED.containsMatchIn(n.text))
            n.copy(tag = "PROPOSAL") else n
    }

    /** realtime_agent v5 minutes: the checked notes (proposal guard applied) grouped by type;
     *  every item keeps its `[ts]`. */
    fun minutes(journal: List<Note>): String {
        val notes = journal.map(::reclassify)
        val out = ArrayList<String>()
        for ((title, tag) in SECTIONS) {
            val items = notes.filter { it.tag?.uppercase() == tag }
            out += "【$title】"
            out += if (items.isEmpty()) listOf("- 無") else items.map { "- ${it.text.trimEnd('。')} [${it.ts}]" }
        }
        return out.joinToString("\n")
    }
}

/** One transcript line as the model reads it (ingest.Line). [speaker] is "S1", "S2", … or null. */
data class Line(val startS: Int, val speaker: String?, val text: String) {
    fun render(): String = "[${ReaderProtocol.formatTs(startS)}] " + (speaker?.let { "$it: " } ?: "") + text
}

/** A journal entry. [tag] is DECISION / ACTION / NUMBER / OPEN-ISSUE / "-" or null. */
data class Note(val id: Int, val window: Int, val ts: String, val tag: String?, val text: String)

/**
 * Window size, context budget and the journal budget on restart. [STANDARD] is the upstream
 * 8k protocol (§4, the parity golden). [MOBILE] is the LiteRT mobile graphs'
 * 4k protocol (§12.3): a 1,500-token window and a 1,200-token compacted journal — with 4k of
 * context the restart check fires before every window, so each window is read from a fresh
 * prompt (system, compacted journal, window), exactly the per-window protocol.
 */
data class ReaderBudget(val windowTokens: Int, val ctxBudget: Int, val restartBudget: Int) {
    companion object {
        val STANDARD = ReaderBudget(ReaderProtocol.WINDOW_TOKENS, ReaderProtocol.CTX_BUDGET, ReaderProtocol.RESTART_BUDGET)
        val MOBILE = ReaderBudget(windowTokens = 1500, ctxBudget = 4096, restartBudget = 1200)
    }
}
