package studio.voxsum.core.config

import android.content.Context

/**
 * Persists [TranscriptionConfig] across app restarts via SharedPreferences, so the user's
 * chosen ASR backend / LLM / language / diarization / prompt sticks instead of resetting to
 * defaults each launch. Field-by-field (the config is all primitives) — no extra dependency.
 */
object ConfigStore {
    private const val PREFS = "voxsum_config"

    fun load(context: Context): TranscriptionConfig {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val d = TranscriptionConfig()
        // Han script for Chinese output. A NEW key: the old "summaryLanguage" / "traditionalChinese"
        // values chose an output LANGUAGE, and that feature is gone (see [SummaryScript]), so they are
        // deliberately not migrated — reading them would carry a translation preference into a build
        // that cannot honour it. A fresh read falls back to the device locale.
        val summaryScript = p.getString("summaryScript", null)
            ?: SummaryScript.defaultFor(java.util.Locale.getDefault()).id
        return TranscriptionConfig(
            asrBackend = p.getString("asrBackend", d.asrBackend) ?: d.asrBackend,
            asrModelId = p.getString("asrModelId", d.asrModelId) ?: d.asrModelId,
            useItn = p.getBoolean("useItn", d.useItn),
            diarizationEnabled = p.getBoolean("diarizationEnabled", d.diarizationEnabled),
            speakerDelaySec = p.getInt("speakerDelaySec", d.speakerDelaySec)
                .coerceIn(TranscriptionConfig.SPEAKER_DELAY_MIN, TranscriptionConfig.SPEAKER_DELAY_MAX),
            llmModelId = p.getString("llmModelId", d.llmModelId) ?: d.llmModelId,
            llmBackend = p.getString("llmBackend", d.llmBackend) ?: d.llmBackend,
            summaryPrompt = p.getString("summaryPrompt", d.summaryPrompt) ?: d.summaryPrompt,
            summaryScript = summaryScript,
            summaryStyle = p.getString("summaryStyle", d.summaryStyle) ?: d.summaryStyle,
        )
    }

    fun save(context: Context, c: TranscriptionConfig) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().apply {
            putString("asrBackend", c.asrBackend)
            putString("asrModelId", c.asrModelId)
            putBoolean("useItn", c.useItn)
            putBoolean("diarizationEnabled", c.diarizationEnabled)
            putInt("speakerDelaySec", c.speakerDelaySec)
            putString("llmModelId", c.llmModelId)
            putString("llmBackend", c.llmBackend)
            putString("summaryPrompt", c.summaryPrompt)
            putString("summaryScript", c.summaryScript)
            putString("summaryStyle", c.summaryStyle)
            // Settings of retired engines (hotwords, VAD, speaker-count hint, precise diarization, ASR
            // hardware) — nothing reads them any more.
            RETIRED_KEYS.forEach(::remove)
            apply()
        }
    }

    private val RETIRED_KEYS = listOf(
        "asrContext", "vadThreshold", "numSpeakers", "preciseDiarization", "asrHardware",
    )
}
