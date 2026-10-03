package studio.voxsum.reader

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import studio.voxsum.core.reader.AgentEvent
import studio.voxsum.core.reader.Line
import studio.voxsum.core.reader.MeetingReader
import studio.voxsum.core.reader.Note
import studio.voxsum.core.reader.ReaderBudget
import studio.voxsum.core.reader.ReaderProtocol
import studio.voxsum.core.reader.ReaderLlm

/**
 * Parity with upstream: tools/reader-parity/make_golden.py ran the REAL eval/phone_live.py on 205
 * transcript lines (v5 minutes: upstream realtime_agent.reclassify_proposals + sections) against a fake server (one token per codepoint, deterministic replies). The
 * Kotlin reader, fed the same lines with the same tokenizer and replies, must build the SAME
 * conversation at every reading turn and end with the same notes, minutes and restart count.
 */
class ReaderParityTest {

    /** One token per codepoint, like the golden's fake server; replays the recorded replies. */
    private class FakeLlm(private val replies: List<Pair<String, Boolean>>) : ReaderLlm {
        val seq = StringBuilder()
        val prompts = ArrayList<String>()
        override fun tokenize(text: String, special: Boolean) = text.codePoints().toArray()
        override fun append(tokens: IntArray): Int {
            tokens.forEach { seq.appendCodePoint(it) }
            return seqLength()
        }
        override fun generateContinue(maxTokens: Int, stop: String, temp: Float, onToken: (String) -> Unit): String {
            prompts += seq.toString()
            val (content, stopped) = replies[prompts.size - 1]
            val reply = content + if (stopped) stop else ""
            seq.append(reply)
            onToken(reply)
            return reply
        }
        override fun seqLength() = seq.codePointCount(0, seq.length)
        override fun reset() { seq.setLength(0) }
    }

    @Test
    fun matchesPhoneLiveTurnByTurn() { replay("/reader_parity.json", ReaderBudget.STANDARD) }

    /** The mobile graphs' 4k protocol: make_golden.py --mobile (window 1500, ctx 4096, journal 1200). */
    @Test
    fun matchesPhoneLiveAt4k() {
        val (g, reader) = replay("/reader_parity_mobile.json", ReaderBudget.MOBILE)
        assertEquals(g.getInt("window_tokens"), ReaderBudget.MOBILE.windowTokens)
        assertEquals(g.getInt("ctx"), ReaderBudget.MOBILE.ctxBudget)
        assertEquals(g.getInt("restart_budget"), ReaderBudget.MOBILE.restartBudget)
        // conversion_prompts.compact_notes: the title/prose input at several budgets.
        val compact = g.getJSONObject("compact_notes")
        for (b in compact.keys()) {
            val want = compact.getJSONArray(b).let { a -> (0 until a.length()).map(a::getInt) }
            assertEquals("compact_notes at $b chars", want, ReaderProtocol.compactNotes(reader.journal, b.toInt()).map(Note::id))
        }
    }

    private fun replay(golden: String, budget: ReaderBudget): Pair<JSONObject, MeetingReader> {
        val g = JSONObject(javaClass.getResource(golden)!!.readText())
        val turns = g.getJSONArray("turns")
        val replies = (0 until turns.length()).map {
            turns.getJSONObject(it).let { t -> t.getString("content") to t.getBoolean("stopped") }
        }
        val llm = FakeLlm(replies)
        var restarts = 0
        val reader = MeetingReader(
            llm, g.getString("system_prompt"),
            count = { it.codePointCount(0, it.length) },
            events = { if (it is AgentEvent.Restart) restarts++ },
            budget = budget,
        )
        reader.start()
        val lines = g.getJSONArray("lines")
        for (i in 0 until lines.length()) {
            val l = lines.getJSONObject(i)
            reader.offer(Line(l.getInt("start"), if (l.isNull("speaker")) null else l.getString("speaker"), l.getString("text")))
        }
        val minutes = reader.finish()

        assertEquals("turn count", turns.length(), llm.prompts.size)
        for (i in 0 until turns.length()) {
            assertEquals("conversation at turn ${i + 1}", turns.getJSONObject(i).getString("prompt"), llm.prompts[i])
        }
        val notes = g.getJSONArray("notes")
        assertEquals(notes.length(), reader.journal.size)
        for (i in 0 until notes.length()) {
            val n = notes.getJSONObject(i)
            val k = reader.journal[i]
            assertEquals(n.getInt("id"), k.id)
            assertEquals(n.getInt("window"), k.window)
            assertEquals(n.getString("ts"), k.ts)
            assertEquals(if (n.isNull("tag")) null else n.getString("tag"), k.tag)
            assertEquals(n.getString("text"), k.text)
        }
        assertEquals(g.getString("minutes_v5"), minutes)   // v5 assembly (proposal guard + 討論要點)
        assertEquals(g.getInt("restarts"), restarts)
        return g to reader
    }
}
