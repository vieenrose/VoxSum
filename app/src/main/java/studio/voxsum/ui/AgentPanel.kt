package studio.voxsum.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import studio.voxsum.R
import studio.voxsum.core.reader.AgentEvent
import studio.voxsum.core.reader.AgentState
import studio.voxsum.core.reader.Note
import studio.voxsum.core.reader.ReaderProtocol
import studio.voxsum.ui.theme.LocalVoxSumPalette
import studio.voxsum.ui.theme.VoxSumPalette

/**
 * Live state of the meeting-reading agent, folded from [AgentEvent]s: what it is doing now, one
 * [Step] per window it read (and per restart), the reply it is streaming, the notes it kept, and a
 * raw activity log. One instance per session view.
 */
@Stable
class AgentUiState {
    var state by mutableStateOf<AgentEvent.State?>(null)
        private set
    var reply by mutableStateOf("")
        private set
    /** Tokens in the model's context now (moves with every prefill). */
    var ctxTokens by mutableIntStateOf(0)
        private set
    val notes = mutableStateListOf<Note>()
    val steps = mutableStateListOf<Step>()
    val log = mutableStateListOf<LogLine>()

    /** A window the agent listened to and read, or a context restart between windows. */
    data class Step(
        val window: Int,
        val restart: Boolean = false,
        /** Transcript tokens fed into this window so far. */
        val tokens: Int = 0,
        val reading: Boolean = false,
        val done: Boolean = false,
        val ms: Long = 0,
        val kept: Int = 0,
        val dropped: Int = 0,
        /** Restart only: context before → after. */
        val ctxBefore: Int = 0,
        val ctxAfter: Int = 0,
    )

    data class LogLine(val kind: Kind, val text: String)
    enum class Kind { FED, TURN, KEPT, DROPPED, RESTART, STATE }

    val active: Boolean get() = state != null
    val working: Boolean get() = state?.state.let { it != null && it != AgentState.DONE }
    val windowsRead: Int get() = steps.count { !it.restart && it.done }

    fun reset() {
        state = null; reply = ""; ctxTokens = 0; notes.clear(); steps.clear(); log.clear()
    }

    fun apply(e: AgentEvent) {
        when (e) {
            is AgentEvent.State -> {
                if (e.ctxTokens > 0) ctxTokens = e.ctxTokens
                if (e.window > 0 && steps.none { !it.restart && it.window == e.window }) steps += Step(e.window)
                if (e.state == AgentState.READING) {
                    reply = ""
                    edit { it.copy(reading = true) }
                }
                state = e
            }
            is AgentEvent.Fed -> {
                // Joined mid-run (the STARTING event came before anyone listened): show it anyway.
                if (state == null) state = AgentEvent.State(AgentState.LISTENING, window = e.window, ctxTokens = e.ctxTokens)
                if (e.window > 0 && steps.none { !it.restart && it.window == e.window }) steps += Step(e.window)
                ctxTokens = e.ctxTokens
                if (e.what == "segment") edit { it.copy(tokens = it.tokens + e.tokens) }
                add(Kind.FED, "${e.what} · ${e.tokens} tok · %.1f s · ctx ${e.ctxTokens}".format(e.ms / 1000.0))
            }
            is AgentEvent.TurnToken -> reply += e.piece
            is AgentEvent.TurnDone -> {
                edit { it.copy(reading = false, done = true, ms = e.ms) }
                add(Kind.TURN, "window ${e.window} · %.1f s · +${e.kept} notes".format(e.ms / 1000.0))
            }
            is AgentEvent.NoteKept -> {
                notes += e.note
                edit { it.copy(kept = it.kept + 1) }
                add(Kind.KEPT, ReaderProtocol.render(e.note))
            }
            is AgentEvent.NoteDropped -> {
                edit { it.copy(dropped = it.dropped + 1) }
                add(Kind.DROPPED, "${e.reason.name.lowercase()} · ${e.line}")
            }
            is AgentEvent.Restart -> {
                ctxTokens = e.ctxAfter
                steps += Step(window = 0, restart = true, done = true, ctxBefore = e.ctxBefore, ctxAfter = e.ctxAfter)
                add(Kind.RESTART, "#${e.count} · ctx ${e.ctxBefore} → ${e.ctxAfter}")
            }
        }
    }

    /** Update the current (latest) window step. */
    private fun edit(f: (Step) -> Step) {
        val i = steps.indexOfLast { !it.restart }
        if (i >= 0) steps[i] = f(steps[i])
    }

    private fun add(kind: Kind, text: String) {
        log += LogLine(kind, text)
        if (log.size > MAX_LOG) log.removeRange(0, log.size - MAX_LOG)
    }

    companion object { const val MAX_LOG = 200 }
}

/**
 * The Agent panel, laid out like an agent trace: a header with a live status dot and state chip,
 * two gauges (how full the current window is before the next reading turn, and the context budget
 * before a restart), a step timeline — one node per window, the active one streaming the reply it
 * is writing — and the notes as cards (each time seeks the player). Collapses to its header once
 * the agent is done. Labelled as notes, not minutes — about one statement in five is contradicted
 * by the transcript (integration note §7).
 */
@Composable
fun AgentPanel(agent: AgentUiState, onSeek: ((Int) -> Unit)? = null, modifier: Modifier = Modifier) {
    val pal = LocalVoxSumPalette.current
    val st = agent.state ?: return
    val done = st.state == AgentState.DONE
    var expanded by remember(done) { mutableStateOf(!done) }
    var showLog by remember { mutableStateOf(false) }
    Column(modifier.fillMaxWidth().animateContentSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            Modifier.fillMaxWidth().clickable { expanded = !expanded },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            StatusDot(stateColor(st.state), pulsing = agent.working)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.agent_title),
                    style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = pal.Slate200,
                )
                Text(
                    pluralStringResource(R.plurals.agent_outcome, agent.windowsRead, agent.windowsRead, agent.notes.size),
                    style = MaterialTheme.typography.labelMedium, color = pal.Slate400,
                )
            }
            StateChip(st.state)
        }
        if (!expanded) {
            Text(
                stringResource(R.string.agent_show_process),
                style = MaterialTheme.typography.labelLarge, color = pal.Sky,
                modifier = Modifier.clickable { expanded = true }.padding(vertical = 2.dp),
            )
            return@Column
        }
        if (!done) Gauges(agent, st)
        Timeline(agent, st, onSeek)
        if (agent.notes.isNotEmpty()) {
            Text(stringResource(R.string.agent_notes_caution), style = MaterialTheme.typography.labelSmall, color = pal.Slate400)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            if (done) Text(
                stringResource(R.string.agent_hide_process),
                style = MaterialTheme.typography.labelLarge, color = pal.Sky,
                modifier = Modifier.clickable { expanded = false }.padding(vertical = 4.dp),
            )
            Text(
                stringResource(if (showLog) R.string.agent_hide_log else R.string.agent_show_log, agent.log.size),
                style = MaterialTheme.typography.labelLarge, color = pal.Slate400,
                modifier = Modifier.clickable { showLog = !showLog }.padding(vertical = 4.dp),
            )
        }
        if (showLog) {
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(pal.InsetSurface).padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                agent.log.asReversed().take(60).forEach { l ->
                    Text(
                        "${logPrefix(l.kind)} ${l.text}",
                        style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace,
                        color = if (l.kind == AgentUiState.Kind.DROPPED) pal.Slate400 else pal.Slate200,
                        maxLines = 2, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

/** Window fill (the next reading turn fires at [ReaderProtocol.WINDOW_TOKENS]) and context budget. */
@Composable
private fun Gauges(agent: AgentUiState, st: AgentEvent.State) {
    val cur = agent.steps.lastOrNull { !it.restart }
    // Stacked, not side by side: at large font scales two half-width labels were cut ("Conte…").
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Gauge(
            label = stringResource(R.string.agent_gauge_window),
            value = cur?.tokens ?: 0, max = ReaderProtocol.WINDOW_TOKENS,
            active = st.state == AgentState.LISTENING, modifier = Modifier.fillMaxWidth(),
        )
        Gauge(
            label = stringResource(R.string.agent_gauge_context),
            value = agent.ctxTokens, max = ReaderProtocol.CTX_BUDGET,
            active = false, modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun Gauge(label: String, value: Int, max: Int, active: Boolean, modifier: Modifier) {
    val pal = LocalVoxSumPalette.current
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(label, style = MaterialTheme.typography.labelMedium, color = pal.Slate400, modifier = Modifier.weight(1f), maxLines = 1)
            Spacer(Modifier.width(8.dp))
            Text(
                "%,d / %,d".format(value.coerceAtMost(max), max),
                style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace, color = pal.Slate400,
            )
        }
        LinearProgressIndicator(
            progress = { (value.toFloat() / max).coerceIn(0f, 1f) },
            modifier = Modifier.fillMaxWidth().height(6.dp).clip(CircleShape),
            color = if (active) pal.Sky else pal.Slate600,
            trackColor = pal.Slate700,
            strokeCap = StrokeCap.Round,
            drawStopIndicator = {},
        )
    }
}

/**
 * One node per window (and restart), NEWEST ON TOP. The active window streams the reply it is
 * writing; each window's notes sit under it, but only the latest window with notes shows them —
 * older windows fold to "+n notes" (tap to open), so the panel stays short all meeting long.
 */
@Composable
private fun Timeline(agent: AgentUiState, st: AgentEvent.State, onSeek: ((Int) -> Unit)?) {
    val pal = LocalVoxSumPalette.current
    val steps = agent.steps
    if (steps.isEmpty()) {
        TimelineRow(color = stateColor(st.state), pulsing = agent.working, last = true) {
            Text(statusLine(st), style = MaterialTheme.typography.bodyMedium, color = pal.Slate200)
        }
        return
    }
    val opened = remember { androidx.compose.runtime.mutableStateMapOf<Int, Boolean>() }
    // While a new window is being written its notes are in the live reply, so every older window
    // folds; otherwise the latest window with notes stays open.
    val writing = steps.lastOrNull { !it.restart }?.reading == true
    val latestWithNotes = if (writing) null else agent.notes.maxOfOrNull { it.window }
    Column {
        val newestFirst = steps.asReversed()
        newestFirst.forEachIndexed { i, s ->
            val newest = i == 0
            val last = i == newestFirst.lastIndex
            val color = when {
                s.restart -> VoxSumPalette.Warning
                s.done -> VoxSumPalette.Success
                s.reading -> VoxSumPalette.Warning
                else -> pal.Sky
            }
            TimelineRow(color = color, pulsing = newest && agent.working && !s.done, last = last) {
                if (s.restart) {
                    Text(
                        stringResource(R.string.agent_step_restart, s.ctxBefore, s.ctxAfter),
                        style = MaterialTheme.typography.bodyMedium, color = pal.Slate200,
                    )
                    return@TimelineRow
                }
                Text(
                    stringResource(
                        when {
                            s.done -> R.string.agent_step_done
                            s.reading -> R.string.agent_step_reading
                            else -> R.string.agent_step_listening
                        },
                        s.window,
                    ),
                    style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, color = pal.Slate200,
                )
                val parts = mutableListOf(stringResource(R.string.agent_step_tokens, s.tokens))
                if (s.done) {
                    parts += "%.0f s".format(s.ms / 1000.0)
                    if (s.dropped > 0) parts += stringResource(R.string.agent_step_dropped, s.dropped)
                }
                val notes = agent.notes.filter { it.window == s.window }
                val showNotes = notes.isNotEmpty() && (s.window == latestWithNotes || opened[s.window] == true)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(parts.joinToString(" · "), style = MaterialTheme.typography.labelMedium, color = pal.Slate400)
                    if (s.done) {
                        Text(" · ", style = MaterialTheme.typography.labelMedium, color = pal.Slate400)
                        Text(
                            stringResource(R.string.agent_step_kept, s.kept),
                            style = MaterialTheme.typography.labelMedium,
                            color = if (notes.isNotEmpty() && s.window != latestWithNotes) pal.Sky else pal.Slate400,
                            modifier = Modifier.clickable(enabled = notes.isNotEmpty() && s.window != latestWithNotes) {
                                opened[s.window] = !(opened[s.window] ?: false)
                            },
                        )
                    }
                }
                if (s.reading && newest && agent.reply.isNotBlank()) {
                    Spacer(Modifier.height(6.dp))
                    ReplyPreview(agent.reply)
                }
                if (showNotes) {
                    Spacer(Modifier.height(4.dp))
                    notes.asReversed().forEach { NoteCard(it, onSeek) }
                }
            }
        }
    }
}

@Composable
private fun TimelineRow(color: Color, pulsing: Boolean, last: Boolean, content: @Composable () -> Unit) {
    val pal = LocalVoxSumPalette.current
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
        Column(Modifier.width(20.dp).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(5.dp))
            StatusDot(color, pulsing)
            if (!last) Box(Modifier.padding(top = 4.dp).width(2.dp).weight(1f).background(pal.Hairline))
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f).padding(bottom = if (last) 0.dp else 14.dp)) { content() }
    }
}

/** One note as a compact row: time chip (seeks) · type chip · text, at most two lines. */
@Composable
private fun NoteCard(n: Note, onSeek: ((Int) -> Unit)?) {
    val pal = LocalVoxSumPalette.current
    Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), verticalAlignment = Alignment.Top) {
        Text(
            n.ts,
            style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold, color = pal.Sky,
            modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(pal.ActiveTint)
                .clickable(enabled = onSeek != null) { ReaderProtocol.parseTs(n.ts)?.let { onSeek?.invoke(it * 1000) } }
                .padding(horizontal = 5.dp, vertical = 1.dp),
        )
        Spacer(Modifier.width(6.dp))
        n.tag?.takeIf { it != "-" }?.let { TagChip(it); Spacer(Modifier.width(6.dp)) }
        Text(
            n.text,
            style = MaterialTheme.typography.bodySmall, color = pal.Slate200,
            maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun TagChip(tag: String) {
    val c = tagColor(tag)
    Text(
        tagLabel(tag),
        style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = c,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(c.copy(alpha = 0.14f))
            .padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

@Composable
private fun StateChip(s: AgentState) {
    val c = stateColor(s)
    Text(
        stringResource(
            when (s) {
                AgentState.STARTING -> R.string.agent_state_starting
                AgentState.LISTENING -> R.string.agent_state_listening
                AgentState.READING -> R.string.agent_state_reading
                AgentState.RESTARTING -> R.string.agent_state_restarting
                AgentState.DONE -> R.string.agent_state_done
            },
        ),
        style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = c,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(c.copy(alpha = 0.14f))
            .padding(horizontal = 10.dp, vertical = 4.dp),
    )
}

/** A status dot; pulses while the agent works (never on e-ink, where animation ghosts). */
@Composable
private fun StatusDot(color: Color, pulsing: Boolean, size: Int = 10) {
    val pal = LocalVoxSumPalette.current
    val a = if (pulsing && !pal.isEink) {
        val t = rememberInfiniteTransition(label = "agent-dot")
        t.animateFloat(1f, 0.3f, infiniteRepeatable(tween(800), RepeatMode.Reverse), label = "agent-dot-alpha").value
    } else 1f
    Box(Modifier.size(size.dp).alpha(a).clip(CircleShape).background(color))
}

@Composable
private fun stateColor(s: AgentState): Color {
    val pal = LocalVoxSumPalette.current
    return when (s) {
        AgentState.STARTING -> pal.Slate400
        AgentState.LISTENING -> pal.Sky
        AgentState.READING -> VoxSumPalette.Warning
        AgentState.RESTARTING -> VoxSumPalette.Neutral
        AgentState.DONE -> VoxSumPalette.Success
    }
}

private fun tagColor(tag: String): Color = when (fullTag(tag)) {
    "DECISION" -> VoxSumPalette.Success
    "ACTION" -> VoxSumPalette.Info
    "OPEN-ISSUE" -> VoxSumPalette.Warning
    "NUMBER" -> Color(0xFF8B6CF0)
    else -> VoxSumPalette.Neutral
}

@Composable
private fun statusLine(s: AgentEvent.State): String = when (s.state) {
    AgentState.STARTING -> stringResource(R.string.agent_starting)
    AgentState.LISTENING -> stringResource(R.string.agent_listening, s.window, s.ctxTokens, s.notes)
    AgentState.READING -> stringResource(R.string.agent_reading, s.window)
    AgentState.RESTARTING -> stringResource(R.string.agent_restarting, s.ctxTokens)
    AgentState.DONE -> stringResource(R.string.agent_done, s.notes)
}

@Composable
private fun tagLabel(tag: String): String = when (fullTag(tag)) {
    "DECISION" -> stringResource(R.string.agent_tag_decision)
    "ACTION" -> stringResource(R.string.agent_tag_action)
    "OPEN-ISSUE" -> stringResource(R.string.agent_tag_open)
    "NUMBER" -> stringResource(R.string.agent_tag_number)
    else -> tag
}

/**
 * One line of the reply being written, parsed for DISPLAY only (the model's protocol text is never
 * rewritten): `NOTE [5:14] (ACTION) text` → time, tag, text. Tolerates the half-written last line
 * ("NOTE [0", "NOTE [5:14] (ACT"); other verbs (REVISE/LOOKBACK) keep their raw text.
 */
private data class ReplyLine(val ts: String?, val tag: String?, val text: String, val note: Boolean)

private val REPLY_NOTE = Regex("""^\s*NOTE\b\s*\[?(\d+(?::\d{0,2}){0,2})?\]?\s*(?:\(([A-Za-z-]*)\)?)?\s*(.*)$""")

private fun replyLines(reply: String): List<ReplyLine> =
    reply.lines().map { it.trim() }.filter { it.isNotEmpty() && it != "NEXT" }.map { l ->
        REPLY_NOTE.find(l)?.let { m ->
            ReplyLine(m.groupValues[1].ifEmpty { null }, m.groupValues[2].ifEmpty { null }, m.groupValues[3], note = true)
        } ?: ReplyLine(null, null, l, note = false)
    }

/** The reply being written, as note rows (last 5), the newest one with a typing caret. */
@Composable
private fun ReplyPreview(reply: String) {
    val pal = LocalVoxSumPalette.current
    val lines = replyLines(reply).takeLast(5)
    if (lines.isEmpty()) return
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(pal.InsetSurface)
            .border(1.dp, pal.Hairline, RoundedCornerShape(10.dp)).padding(horizontal = 10.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        // Newest (the line being written) on top, like the notes list.
        lines.asReversed().forEachIndexed { i, l -> ReplyLineRow(l, typing = i == 0) }
    }
}

@Composable
private fun ReplyLineRow(l: ReplyLine, typing: Boolean) {
    val pal = LocalVoxSumPalette.current
    val caret = if (typing) " ▍" else ""
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (l.note) {
            if (l.ts != null) Text(
                l.ts,
                style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold, color = pal.Sky,
                modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(pal.ActiveTint)
                    .padding(horizontal = 5.dp, vertical = 1.dp),
            )
            Spacer(Modifier.width(6.dp))
            l.tag?.takeIf { it.length >= 3 && it != "-" }?.let { TagChip(it); Spacer(Modifier.width(6.dp)) }
        }
        Text(
            l.text + caret,
            style = MaterialTheme.typography.bodySmall,
            color = if (l.note) pal.Slate200 else pal.Slate400,
            maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
        )
    }
}

/** A tag, completed from its prefix while it is still being written ("ACT" → ACTION). */
private fun fullTag(tag: String): String {
    val t = tag.uppercase()
    return listOf("DECISION", "ACTION", "OPEN-ISSUE", "NUMBER").firstOrNull { it.startsWith(t) } ?: t
}

private fun logPrefix(k: AgentUiState.Kind) = when (k) {
    AgentUiState.Kind.FED -> "▸"
    AgentUiState.Kind.TURN -> "✎"
    AgentUiState.Kind.KEPT -> "+"
    AgentUiState.Kind.DROPPED -> "×"
    AgentUiState.Kind.RESTART -> "↺"
    AgentUiState.Kind.STATE -> "·"
}

/**
 * Compact agent strip for the recording booth, pinned above the live transcript: status dot +
 * state chip, a thin window-fill bar (how close the next reading turn is), and the reply being
 * written or the latest note.
 */
@Composable
fun AgentStrip(agent: AgentUiState, modifier: Modifier = Modifier) {
    val pal = LocalVoxSumPalette.current
    val st = agent.state ?: return
    val cur = agent.steps.lastOrNull { !it.restart }
    Column(
        modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp).clip(RoundedCornerShape(12.dp))
            .background(pal.InsetSurface).border(1.dp, pal.Hairline, RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusDot(stateColor(st.state), pulsing = agent.working, size = 8)
            Spacer(Modifier.width(8.dp))
            Text(
                stringResource(R.string.agent_title),
                style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = pal.Slate200,
                modifier = Modifier.weight(1f),
            )
            if (agent.notes.isNotEmpty()) {
                Text(
                    stringResource(R.string.agent_notes_count, agent.notes.size),
                    style = MaterialTheme.typography.labelMedium, color = pal.Slate400,
                )
                Spacer(Modifier.width(8.dp))
            }
            StateChip(st.state)
        }
        if (st.state == AgentState.LISTENING && cur != null) {
            LinearProgressIndicator(
                progress = { (cur.tokens.toFloat() / ReaderProtocol.WINDOW_TOKENS).coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().height(3.dp).clip(CircleShape),
                color = pal.Sky, trackColor = pal.Slate700, strokeCap = StrokeCap.Round, drawStopIndicator = {},
            )
        }
        val note = agent.notes.lastOrNull()
        when {
            // Friendlier than the raw protocol line: drop the "NOTE" keyword and the brackets.
            st.state == AgentState.READING && replyLines(agent.reply).isNotEmpty() ->
                ReplyLineRow(replyLines(agent.reply).last(), typing = true)
            note != null -> Row(verticalAlignment = Alignment.CenterVertically) {
                Text(note.ts, style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace, color = pal.Sky)
                Spacer(Modifier.width(8.dp))
                note.tag?.takeIf { it != "-" }?.let { TagChip(it); Spacer(Modifier.width(6.dp)) }
                Text(
                    note.text,
                    style = MaterialTheme.typography.bodySmall, color = pal.Slate200,
                    maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                )
            }
            else -> Text(statusLine(st), style = MaterialTheme.typography.labelMedium, color = pal.Slate400, maxLines = 1)
        }
    }
}
