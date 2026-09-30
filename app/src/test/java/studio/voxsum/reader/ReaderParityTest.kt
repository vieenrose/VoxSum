package studio.voxsum.reader

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import studio.voxsum.core.reader.AgentEvent
import studio.voxsum.core.reader.Line
import studio.voxsum.core.reader.MeetingReader
import studio.voxsum.core.reader.ReaderLlm

/**
 * Parity with upstream: tools/reader-parity/make_golden.py ran the REAL eval/phone_live.py on 205
 * transcript lines against a fake server (one token per codepoint, deterministic replies). The
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
    fun matchesPhoneLiveTurnByTurn() {
        val g = JSONObject(javaClass.getResource("/reader_parity.json")!!.readText())
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
        assertEquals(g.getString("minutes"), minutes)
        assertEquals(g.getInt("restarts"), restarts)
    }
}
