package studio.voxsum.core.config

import studio.voxsum.core.models.LlmRegistry

/**
 * User-facing pipeline configuration — the Android equivalent of the original web app's
 * ASR / Diarization / LLM / Summarization settings sidebar. Held in a process-wide
 * [Holder] so the Activity can set it before starting the foreground service (same process).
 */
data class TranscriptionConfig(
    // --- ASR ---
    val asrBackend: String = "nemo",   // provenance id (AsrBackend); nemo is the only engine
    val asrModelId: String = "x-asr-zh-en-q8_0+nemotron-3-diarization-q8_0",
    val useItn: Boolean = true,               // inverse text normalization
    // Hotword / context biasing (names, jargon). Kept for stored configs; the streaming
    // transducer has no prompt, so the engine does not use it.
    val asrContext: String = "",

    // --- Diarization ---
    val diarizationEnabled: Boolean = true,

    // --- Summarization ---
    // The actually-used summary model. MUST track LlmRegistry.DEFAULT_ID — hardcoding it here (it was
    // pinned to gemma) silently kept new installs on the old default even after the registry's default
    // changed, so the "recommended" model in Settings and the model that actually ran disagreed.
    val llmModelId: String = LlmRegistry.DEFAULT_ID,
    /** Summarizer inference hardware: "cpu" (default) or "gpu" (LiteRT-LM models only —
     *  llama.cpp GGUFs and the MOSS/ASR engines always run on CPU). */
    val llmBackend: String = "auto",  // auto = GPU-first with CPU fallback
    val summaryPrompt: String = "Summarize the key points of this transcript.",
    // Target language for ALL out-coming text — summary, title, transcript, and detected speaker names
    // Han script every Chinese text is normalized to (a [SummaryScript] id). Summaries are always
    // in the RECORDING's language — the translate-as-you-summarize option was removed because it
    // degraded a 0.8B summarizer's output. This is a post-hoc OpenCC mapping, not a model task.
    val summaryScript: String = "zh-Hant",
    // Format of the summary (a [SummaryStyle] id): bullet (default) | executive | narrative.
    val summaryStyle: String = "executive",
) {
    object Holder {
        @Volatile var config: TranscriptionConfig = TranscriptionConfig()
    }

}
