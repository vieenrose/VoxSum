package studio.voxsum.core.models

/**
 * A selectable on-device summarization model.
 *
 * The shape is [ModelManager]'s revision-pinned, multi-file artifact set (the same one the ASR
 * model sets use). A GGUF is a SINGLE self-contained file — weights, tokenizer and chat template
 * all live inside it — so a GGUF spec simply has one entry in [files] and leaves
 * [weightCacheFile] / [tokenizerFile] empty. The multi-file machinery is kept rather than
 * special-cased because it is what gives us per-file sha256 verification and resumable,
 * revision-pinned downloads for free.
 */
data class LlmSpec(
    val id: String,
    val displayName: String,
    /** ModelManager subdirectory holding this model's files. */
    val dirName: String,
    /** HF `resolve/<commit>` base URL — commit-pinned, never `main`. */
    val revision: String,
    /** relative path -> (sizeBytes, sha256). Downloaded and verified file by file. */
    val files: Map<String, Pair<Long, String>>,
    /** Relative path of the model inside [dirName]. */
    val mainFile: String,
    /** Relative path of a pre-packed weight cache, or "" — GGUF needs none. llama.cpp mmaps the
     *  file, so the weights are file-backed and evictable from the start; the ~800 MiB of
     *  UNRECLAIMABLE anonymous memory XNNPACK materialised (and the pre-packed cache built to
     *  avoid it) has no analogue here. */
    val weightCacheFile: String = "",
    /** Relative path of a separate tokenizer blob, or "" — a GGUF embeds its own. */
    val tokenizerFile: String = "",
    val chatTemplate: ChatTemplate,
    val shortName: String = "",
    val sampler: SamplerProfile = SamplerProfile.LEGACY,
    /**
     * Largest context this model may be asked for, in tokens.
     *
     * A CEILING, not an allocation, and — unlike the LiteRT export it replaces — a genuine
     * runtime knob. The `.litertlm`/`.tflite` bundles baked `cache_length` in at export time:
     * the graph allocated its KV from that value and rescanned the whole allocation every step,
     * so a 32k bundle decoded at 1.5 tok/s where the 16k one did 3.4, and serving two window
     * sizes meant shipping two multi-hundred-MB bundles. llama.cpp takes `n_ctx` at
     * `llama_init_from_model`, so one file serves every size and [Summarizer.contextFor] picks
     * the smallest that fits the transcript.
     */
    val maxCtx: Int,
    /** llama.cpp `swa_full`: false for Gemma's sliding-window layers in session mode (the reader
     *  only appends, so the SWA cache never rolls back). */
    val swaFull: Boolean = true,
) {
    val totalBytes: Long get() = files.values.sumOf { it.first }
}

/**
 * NONE = the runtime applies the model's own chat template. QWEN3 = ChatML with the empty
 * `<think></think>` block Qwen3.5 wants for non-thinking mode, applied app-side. MINICPM5 =
 * the same shape for MiniCPM5, but carrying a CALLER-SUPPLIED system prompt.
 *
 * That last difference is the point of the variant: [ChatTemplate.CHATML] and
 * [ChatTemplate.QWEN3] hardcode "You are a helpful assistant", which is right for a model
 * given its instructions in the user turn. The CURSOR protocol is not an instruction, it is
 * a SYSTEM contract the checkpoint was fine-tuned against, so it has to occupy the system
 * turn — see [studio.voxsum.core.agentic.CursorPrompts].
 *
 * No BOS literal in any of these: the JNI tokenizes with `addSpecial=true`, so llama.cpp
 * already prepends whatever the GGUF's metadata declares. Writing one here would double it.
 */
enum class ChatTemplate { CHATML, QWEN3, MINICPM5, GRANITE, GEMMA4, NONE }

/**
 * llama.cpp sampler settings, chosen per model. The chain itself is built in native code
 * (llm_jni.cpp); the values are picked here so each model family gets what it expects.
 */
data class SamplerProfile(
    val topK: Int,
    val topP: Float,
    val temp: Float,
    val repeatPenalty: Float,
    val presencePenalty: Float,
) {
    companion object {
        /** Legacy small-instruct chain: a heavy repeat penalty stops the "say the same sentence
         *  forever" loops older sub-2B instruct models fall into on summarization. */
        val LEGACY = SamplerProfile(topK = 40, topP = 0.9f, temp = 0.7f, repeatPenalty = 1.3f, presencePenalty = 0.0f)

        /** Qwen's own recommended non-thinking sampler. A high repeat penalty makes Qwen3.5 drop
         *  punctuation and structure into a run-on wall-of-text on long inputs, so repeat is OFF
         *  (1.0) and a flat presence penalty guards repetition instead. */
        val QWEN35 = SamplerProfile(topK = 20, topP = 0.8f, temp = 0.7f, repeatPenalty = 1.0f, presencePenalty = 1.0f)

        /** The ANCHORED checkpoint's measured setting: greedy, temperature 0. Every quality number
         *  in its integration note (faith 4.60 / 5% inversions, gemma-4-26B judge, n=20) was
         *  produced at temp 0 with thinking disabled. Greedy also makes the NOTES format
         *  reproducible, which matters because a parser downstream depends on the section keys.
         *  No repeat penalty: the note warns that penalties above ~1.15 eat the structural tokens
         *  that delimit the sections. */
        val QWEN35_ANCHORED = SamplerProfile(topK = 1, topP = 1.0f, temp = 0.0f, repeatPenalty = 1.0f, presencePenalty = 0.0f)

        /**
         * The CURSOR protocol's setting: greedy, temperature 0, no penalties.
         *
         * Every measured number for MiniCPM5-1B-CURSOR and the 350M verifier was produced at
         * `--temp 0` (upstream's serve flags, integration note §2). Greedy is not merely a
         * fidelity choice here — the student's output is a GRAMMAR, and sampling an op line is
         * sampling whether it parses. A repeat penalty is actively harmful for the same reason:
         * `ADD`, `UPD`, the section keys and the `[m:ss]` brackets are meant to recur on every
         * line, and penalising them is penalising the protocol itself.
         */
        val CURSOR = SamplerProfile(topK = 1, topP = 1.0f, temp = 0.0f, repeatPenalty = 1.0f, presencePenalty = 0.0f)

        /** The meeting reader's ONE-SHOT calls (title, speaker names): llama-server's defaults at
         *  the reference temperature. The reading turns themselves build their chain natively
         *  (top_k 40, top_p 0.95, min_p 0.05, T 0.2 — llm_jni.cpp nativeGenerateContinue). */
        val GEMMA_READER = SamplerProfile(topK = 40, topP = 0.95f, temp = 0.2f, repeatPenalty = 1.0f, presencePenalty = 0.0f)
    }
}

/**
 * The on-device summarizer: the Gemma-4-E2B meeting agent (QAT, Q4_0, Apache-2.0), fine-tuned as a
 * live READING AGENT (github.com/vieenrose/meeting-summarizer): it reads a meeting window by window
 * and writes short, typed, cited notes; the minutes are those notes grouped by type
 * ([studio.voxsum.core.reader]). The protocol lives in `system_prompt.txt`, shipped next to the
 * weights and used verbatim — the model was fine-tuned on it.
 *
 * Measured upstream on 38 held-out zh-TW meetings: coverage 0.91, 77 % of gold decisions recalled,
 * 18 % of statements contradicted by the transcript. Live on a Reno7 (Dimensity 900): 67 s median
 * lag after each ~4 min window.
 */
object LlmRegistry {
    const val DEFAULT_ID = "gemma4-e2b-meeting-agent-zh"

    // v5 (2026-09-30): adds the PROPOSAL type, strict DECISION/ACTION; trained on IVOD + AliMeeting.
    // Weights and prompt live under v5/ and must stay paired (integration note §9).
    private const val REV = "958a8f29a0143184418196c36a78b4899c0c8996"
    private const val GGUF = "v5/gemma-4-E2B-meeting-agent-zh-v5-Q4_0.gguf"
    const val SYSTEM_PROMPT_FILE = "v5/system_prompt.txt"

    val ALL: List<LlmSpec> = listOf(
        LlmSpec(
            id = DEFAULT_ID,
            displayName = "Gemma-4-E2B meeting agent (zh)",
            shortName = "Meeting agent",
            dirName = "gemma4-meeting-agent-v5-gguf",
            revision = "https://huggingface.co/Luigi/gemma-4-E2B-meeting-agent-zh-GGUF/resolve/$REV",
            files = mapOf(
                GGUF to
                    (3_349_515_904L to "c812c04c4c627c15847614873d187d72db793b4165ea32fd00f1cec451aa5344"),
                SYSTEM_PROMPT_FILE to
                    (1_686L to "406040c70270b5b9d47a4222138fcf2177f361dcbfb79fba164ca2559e0ffbf3"),
            ),
            mainFile = GGUF,
            chatTemplate = ChatTemplate.GEMMA4,
            sampler = SamplerProfile.GEMMA_READER,
            // The reader restarts its conversation at 8k (prefill slows sharply with depth on a
            // phone CPU); 12288 leaves room for the window and the output (integration note §3).
            maxCtx = 12288,
            swaFull = false,
        ),
    )

    fun byId(id: String): LlmSpec =
        ALL.firstOrNull { it.id == id } ?: ALL.first { it.id == DEFAULT_ID }
}
