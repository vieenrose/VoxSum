package studio.voxsum

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import studio.voxsum.core.config.ThemeMode
import studio.voxsum.core.reader.AgentEvent
import studio.voxsum.core.reader.AgentState
import studio.voxsum.core.reader.DropReason
import studio.voxsum.core.reader.Note
import studio.voxsum.ui.AgentPanel
import studio.voxsum.ui.AgentStrip
import studio.voxsum.ui.AgentUiState
import studio.voxsum.ui.theme.LocalVoxSumPalette
import studio.voxsum.ui.theme.VoxSumTheme

/**
 * Not a test: replays a scripted meeting-agent run (the AISHELL-4 property-meeting demo) in the
 * real AgentStrip + AgentPanel, slowly, so the UI can be reviewed and screenshotted on an emulator
 * without the models. Skipped unless run with `-e showcase true`:
 *
 *   adb shell am instrument -w -e showcase true -e theme LIGHT \
 *     -e class studio.voxsum.AgentPanelShowcase studio.voxsum.androidtest.test/androidx.test.runner.AndroidJUnitRunner
 */
@RunWith(AndroidJUnit4::class)
class AgentPanelShowcase {
    @get:Rule val rule = createComposeRule()

    @Test
    fun replay() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("showcase") == "true")
        val theme = runCatching { ThemeMode.valueOf(args.getString("theme") ?: "LIGHT") }.getOrDefault(ThemeMode.LIGHT)
        val agent = AgentUiState()
        rule.setContent {
            VoxSumTheme(theme) {
                val pal = LocalVoxSumPalette.current
                Column(
                    Modifier.fillMaxSize().background(pal.Slate900).statusBarsPadding()
                        .verticalScroll(rememberScrollState()).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    AgentStrip(agent)
                    Card(
                        colors = CardDefaults.cardColors(containerColor = pal.PanelSurface),
                        shape = RoundedCornerShape(16.dp),
                    ) { AgentPanel(agent, onSeek = {}, modifier = Modifier.padding(16.dp)) }
                }
            }
        }
        fun emit(e: AgentEvent, pauseMs: Long = 0) {
            rule.runOnIdle { agent.apply(e) }
            if (pauseMs > 0) Thread.sleep(pauseMs)
        }
        val notes = listOf(
            listOf(Note(1, 1, "0:07", "OPEN-ISSUE", "物業推卸監控責任，住戶要求後續調查"),
                Note(2, 1, "0:41", "DECISION", "建議有車庫的住戶優先停在車庫內"),
                Note(3, 1, "1:51", "ACTION", "物業調查保安是否失職")),
            listOf(Note(4, 2, "4:38", "ACTION", "住戶提供車輛在小區受損的證據與保險材料"),
                Note(5, 2, "5:14", "ACTION", "物業調閱監控記錄並向保險公司報備")),
            listOf(Note(6, 3, "5:40", "NUMBER", "處理時限為四到五天"),
                Note(7, 3, "9:12", "ACTION", "物業協調外包公司加快水電維修")),
        )
        val replies = listOf(
            "NOTE [0:07] (OPEN-ISSUE) 物業推卸監控責任…\nNOTE [0:41] (DECISION) 建議有車庫的住戶…\nNOTE [1:51] (ACTION) 物業調查保安…",
            "NOTE [4:38] (ACTION) 住戶提供車輛受損證據…\nNOTE [5:14] (ACTION) 物業調閱監控記錄…",
            "NOTE [5:40] (NUMBER) 處理時限為四到五天\nNOTE [9:12] (ACTION) 物業協調外包公司…",
        )
        emit(AgentEvent.State(AgentState.STARTING), 1500)
        emit(AgentEvent.Fed(0, "prefix", 431, 2100, 431))
        var ctx = 431
        for (w in 1..3) {
            emit(AgentEvent.State(AgentState.LISTENING, window = w, ctxTokens = ctx, notes = (w - 1) * 2))
            repeat(8) {
                ctx += 245
                emit(AgentEvent.Fed(w, "segment", 245, 900, ctx), 700)
            }
            emit(AgentEvent.State(AgentState.READING, window = w, ctxTokens = ctx), 300)
            replies[w - 1].chunked(6).forEach { emit(AgentEvent.TurnToken(w, it), 120) }
            notes[w - 1].forEach { emit(AgentEvent.NoteKept(it), 250) }
            if (w == 2) emit(AgentEvent.NoteDropped(w, "NOTE [3:02] (ACTION) 物業幫忙找肇事車輛", DropReason.DUPLICATE))
            emit(AgentEvent.TurnDone(w, replies[w - 1], notes[w - 1].size, 31_000L + w * 4_000L), 400)
        }
        emit(AgentEvent.State(AgentState.LISTENING, window = 4, ctxTokens = ctx, notes = 7))
        repeat(4) { ctx += 245; emit(AgentEvent.Fed(4, "segment", 245, 900, ctx), 700) }
        // Hold the live state for screenshots, then finish.
        Thread.sleep((args.getString("holdLiveMs") ?: "20000").toLong())
        emit(AgentEvent.State(AgentState.READING, window = 4, ctxTokens = ctx), 300)
        emit(AgentEvent.TurnDone(4, "", 0, 18_000L))
        emit(AgentEvent.State(AgentState.DONE, ctxTokens = ctx, notes = 7))
        Thread.sleep((args.getString("holdDoneMs") ?: "20000").toLong())
    }
}
