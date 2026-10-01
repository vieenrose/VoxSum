package studio.voxsum

import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import studio.voxsum.core.config.ThemeMode
import studio.voxsum.core.events.TranscriptEvent
import studio.voxsum.core.reader.AgentEvent
import studio.voxsum.core.reader.AgentState
import studio.voxsum.core.reader.Note
import studio.voxsum.ui.AgentUiState
import studio.voxsum.ui.CaptureScreen
import studio.voxsum.ui.theme.VoxSumTheme

/**
 * Not a test: the recording booth fed a scripted live meeting (AISHELL-4 demo lines) and agent,
 * for review and screenshots without a microphone or models. Skipped unless `-e showcase true`.
 */
@RunWith(AndroidJUnit4::class)
class CaptureShowcase {
    @get:Rule val rule = createComposeRule()

    @Test
    fun replay() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("showcase") == "true")
        val lines = listOf(
            Triple(0, 0.0, "然後我們的車就平白無故就不用管了，也沒人管這什麼情況。你們保安這負責的是不是有點那什麼了，失誤了？"),
            Triple(1, 9.0, "哦，我們保護。然後"),
            Triple(0, 11.0, "那個去查監控，你們物業那邊一直不給調監控，說那邊監控壞了怎麼的，一有問題你們物業就推卸責任。"),
            Triple(2, 42.0, "法"),
            Triple(3, 45.0, "咱們那個停車位它不是樓下不是有停車庫嘛，家裡有停車庫的話，咱儘量是推薦停在停車庫裡。"),
            Triple(0, 77.0, "我們買的停車位是我們是露天的呀，不是地下車庫，地車庫因為沒有位子的呀我們只能停這。"),
            Triple(3, 96.0, "這個車位是屬於你的，我們是有一個那個保管，就是看護的權利。"),
            Triple(0, 112.0, "你說的很有道理，但是我們的車確實被刮得特別厲害。"),
        )
        val agent = AgentUiState()
        val utts = mutableStateListOf<TranscriptEvent.Utterance>()
        var stable by mutableIntStateOf(0)
        var secs by mutableIntStateOf(0)
        rule.setContent {
            VoxSumTheme(runCatching { ThemeMode.valueOf(args.getString("theme") ?: "LIGHT") }.getOrDefault(ThemeMode.LIGHT)) {
                CaptureScreen(
                    isRecording = true, recSeconds = secs, micLevel = 0.6f,
                    sessionName = "", onSessionName = {},
                    utterances = utts, stable = stable, agent = agent,
                    onNextTalk = {}, onStop = {}, onBack = {},
                )
            }
        }
        fun ui(f: () -> Unit) = rule.runOnIdle(f)
        ui {
            agent.apply(AgentEvent.State(AgentState.LISTENING, window = 1, ctxTokens = 431))
            agent.apply(AgentEvent.Fed(1, "segment", 900, 800, 1331))
        }
        lines.forEachIndexed { i, (spk, t, text) ->
            ui {
                utts += TranscriptEvent.Utterance(i, text, t, t + 8, spk)
                stable = (utts.size - 2).coerceAtLeast(0)
                secs = t.toInt() + 8
                agent.apply(AgentEvent.Fed(1, "segment", 120, 300, 1331 + 120 * (i + 1)))
            }
            Thread.sleep(1500)
            if (i == 4) {
                ui {
                    agent.apply(AgentEvent.State(AgentState.READING, window = 1, ctxTokens = 2400))
                    agent.apply(AgentEvent.TurnToken(1, "NOTE [0:11] (OPEN-ISSUE) 物業推卸監控責任"))
                    agent.apply(AgentEvent.NoteKept(Note(1, 1, "0:11", "OPEN-ISSUE", "物業推卸監控責任，住戶要求調閱監控")))
                    agent.apply(AgentEvent.TurnDone(1, "", 1, 30_000))
                    agent.apply(AgentEvent.State(AgentState.LISTENING, window = 2, ctxTokens = 2600, notes = 1))
                }
            }
        }
        Thread.sleep((args.getString("holdMs") ?: "20000").toLong())
    }
}
