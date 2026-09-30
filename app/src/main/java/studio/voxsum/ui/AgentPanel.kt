package studio.voxsum.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import studio.voxsum.R
import studio.voxsum.core.reader.AgentEvent
import studio.voxsum.core.reader.AgentState
import studio.voxsum.core.reader.Note
import studio.voxsum.core.reader.ReaderProtocol
import studio.voxsum.ui.theme.LocalVoxSumPalette

/**
 * Live state of the meeting-reading agent, folded from [AgentEvent]s: what it is doing now, the
 * reply it is streaming for the current window, the notes it kept, and an activity log of every
 * prefill, turn, dropped note and restart. One instance per session view.
 */
@Stable
class AgentUiState {
    var state by mutableStateOf<AgentEvent.State?>(null)
        private set
    var reply by mutableStateOf("")
        private set
    val notes = mutableStateListOf<Note>()
    val log = mutableStateListOf<LogLine>()

    data class LogLine(val kind: Kind, val text: String)
    enum class Kind { FED, TURN, KEPT, DROPPED, RESTART, STATE }

    val active: Boolean get() = state != null

    fun reset() {
        state = null; reply = ""; notes.clear(); log.clear()
    }

    fun apply(e: AgentEvent) {
        when (e) {
            is AgentEvent.State -> {
                if (e.state == AgentState.READING) reply = ""
                state = e
            }
            is AgentEvent.Fed -> add(Kind.FED, "${e.what} · ${e.tokens} tok · %.1f s · ctx ${e.ctxTokens}".format(e.ms / 1000.0))
            is AgentEvent.TurnToken -> reply += e.piece
            is AgentEvent.TurnDone -> add(Kind.TURN, "window ${e.window} · %.1f s · +${e.kept} notes".format(e.ms / 1000.0))
            is AgentEvent.NoteKept -> {
                notes += e.note
                add(Kind.KEPT, ReaderProtocol.render(e.note))
            }
            is AgentEvent.NoteDropped -> add(Kind.DROPPED, "${e.reason.name.lowercase()} · ${e.line}")
            is AgentEvent.Restart -> add(Kind.RESTART, "#${e.count} · ctx ${e.ctxBefore} → ${e.ctxAfter}")
        }
    }

    private fun add(kind: Kind, text: String) {
        log += LogLine(kind, text)
        if (log.size > MAX_LOG) log.removeRange(0, log.size - MAX_LOG)
    }

    companion object { const val MAX_LOG = 200 }
}

/**
 * The Agent panel: status line, the reply being written for the current window, the live notes
 * (each timestamp seeks the player), and a collapsible activity log. Labelled as notes, not minutes
 * — about one statement in five is contradicted by the transcript (integration note §7).
 */
@Composable
fun AgentPanel(agent: AgentUiState, onSeek: ((Int) -> Unit)? = null, modifier: Modifier = Modifier) {
    val pal = LocalVoxSumPalette.current
    val st = agent.state ?: return
    var showLog by remember { mutableStateOf(false) }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            stringResource(R.string.agent_title),
            style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = pal.Slate200,
        )
        Text(statusLine(st), style = MaterialTheme.typography.bodyMedium, color = pal.Sky)
        if (st.state == AgentState.READING && agent.reply.isNotBlank()) {
            Text(
                agent.reply.trimEnd(),
                style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, color = pal.Slate400,
            )
        }
        if (agent.notes.isNotEmpty()) {
            Spacer(Modifier.height(4.dp))
            Text(stringResource(R.string.agent_notes, agent.notes.size), style = MaterialTheme.typography.labelMedium, color = pal.Slate400)
            agent.notes.forEach { n ->
                Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                    Text(
                        "[${n.ts}]",
                        style = MaterialTheme.typography.bodySmall, color = pal.Sky,
                        modifier = Modifier.clickable(enabled = onSeek != null) {
                            ReaderProtocol.parseTs(n.ts)?.let { onSeek?.invoke(it * 1000) }
                        },
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        (n.tag?.let { "${tagLabel(it)} · " } ?: "") + n.text,
                        style = MaterialTheme.typography.bodySmall, color = pal.Slate200,
                    )
                }
            }
            Text(stringResource(R.string.agent_notes_caution), style = MaterialTheme.typography.labelSmall, color = pal.Slate400)
        }
        Text(
            stringResource(if (showLog) R.string.agent_hide_log else R.string.agent_show_log, agent.log.size),
            style = MaterialTheme.typography.labelMedium, color = pal.Sky,
            modifier = Modifier.clickable { showLog = !showLog }.padding(vertical = 4.dp),
        )
        if (showLog) {
            agent.log.asReversed().take(60).forEach { l ->
                Text(
                    "${logPrefix(l.kind)} ${l.text}",
                    style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace,
                    color = if (l.kind == AgentUiState.Kind.DROPPED) pal.Slate400 else pal.Slate200,
                )
            }
        }
    }
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
private fun tagLabel(tag: String): String = when (tag.uppercase()) {
    "DECISION" -> stringResource(R.string.agent_tag_decision)
    "ACTION" -> stringResource(R.string.agent_tag_action)
    "OPEN-ISSUE" -> stringResource(R.string.agent_tag_open)
    "NUMBER" -> stringResource(R.string.agent_tag_number)
    else -> tag
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
 * Compact agent strip for the recording booth: status (or the reply being written) and the latest
 * note, pinned above the live transcript so it never scrolls away.
 */
@Composable
fun AgentStrip(agent: AgentUiState, modifier: Modifier = Modifier) {
    val pal = LocalVoxSumPalette.current
    val st = agent.state ?: return
    Column(modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            stringResource(R.string.agent_title) + " · " + statusLine(st),
            style = MaterialTheme.typography.labelMedium, color = pal.Sky, maxLines = 1,
        )
        val line = if (st.state == AgentState.READING && agent.reply.isNotBlank())
            agent.reply.trimEnd().lines().last()
        else agent.notes.lastOrNull()?.let { n -> "[${n.ts}] " + (n.tag?.let { "${tagLabel(it)} · " } ?: "") + n.text }
        line?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = pal.Slate200, maxLines = 2)
        }
    }
}
