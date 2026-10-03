package studio.voxsum

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasAnySibling
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import studio.voxsum.core.asr.AsrBackend
import studio.voxsum.core.config.SummaryScript
import studio.voxsum.core.config.TranscriptionConfig
import studio.voxsum.core.models.LlmRegistry
import studio.voxsum.ui.SettingsContent

/**
 * Isolated tests for [SettingsContent]: every control reports via onChange(config.copy(...)), so we
 * host it (in a scroll container, since it overflows the viewport) with a config + spy and assert the
 * resulting config — proving the settings wiring that feeds ConfigStore persistence. Uses the x-asr
 * backend so the SenseVoice-only language chips/ITN switch are hidden, leaving each control unambiguous.
 */
@RunWith(AndroidJUnit4::class)
class SettingsContentTest {

    @get:Rule val compose = createComposeRule()

    private val baseCfg = TranscriptionConfig(asrBackend = AsrBackend.XASR.id)

    private fun host(cfg: TranscriptionConfig = baseCfg, enabled: Boolean = true, onChange: (TranscriptionConfig) -> Unit = {}) {
        compose.setContent {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                SettingsContent(cfg, readyLlm = setOf(cfg.llmModelId), enabled = enabled, onChange = onChange)
            }
        }
    }

    @Test fun selectingChineseScriptReportsIt() {
        var changed: TranscriptionConfig? = null
        host(onChange = { changed = it })
        compose.onNodeWithText(SummaryScript.SIMPLIFIED.autonym).performScrollTo().performClick()
        assertEquals(SummaryScript.SIMPLIFIED.id, changed?.summaryScript)
    }

    // While a run is going the sheet is read-only (there is no engine picker any more).
    @Test fun disabledStateDisablesTheSettings() {
        host(enabled = false)
        compose.onNodeWithText(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.getString(studio.voxsum.R.string.settings_show_actions)).performScrollTo().assertIsNotEnabled()
    }

    @Test fun aboutSectionShowsTheAppVersion() {
        host()
        compose.onNodeWithText("VoxSum v${BuildConfig.VERSION_NAME}").performScrollTo().assertIsDisplayed()
    }
}
