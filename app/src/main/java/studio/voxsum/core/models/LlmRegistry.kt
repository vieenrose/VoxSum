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
    /** Which engine runs it: llama.cpp (a GGUF) or the mobile LiteRT engine (a `mfa/` folder). */
    val backend: LlmBackend = LlmBackend.LLAMA_CPP,
    /** The reader's system prompt, shipped next to the weights (they must stay paired). */
    val systemPromptFile: String = "",
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
enum class LlmBackend { LLAMA_CPP, MOBILE }

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
 * Measured upstream (v11) on 38 held-out zh-TW meetings: coverage 0.89, 72 % of gold decisions
 * recalled, 71 % of listed decisions really decided, 17 % of statements contradicted by the transcript. Live on a Reno7 (Dimensity 900): 67 s median
 * lag after each ~4 min window.
 */
object LlmRegistry {
    const val DEFAULT_ID = "gemma4-e2b-meeting-agent-zh"

    // v11 (2026-10-02): v8 (title and prose calls fine-tuned on ReaderLane's prompts) + a
    // contrastive DPO — the most precise decisions (71 % really decided vs v5's 61 %) and the best
    // titles; same protocol, and its prompt is byte-identical to v5's. Weights and prompt live
    // under v11/ and must stay paired (integration note §11).
    private const val REV = "a862b705f3aaf7edee2018f4e3abae286826f11d"
    private const val GGUF = "v11/gemma-4-E2B-meeting-agent-zh-v11-Q4_0.gguf"
    const val SYSTEM_PROMPT_FILE = "v11/system_prompt.txt"

    val ALL: List<LlmSpec> = listOf(
        LlmSpec(
            id = DEFAULT_ID,
            displayName = "Gemma-4-E2B meeting agent (zh)",
            shortName = "Meeting agent",
            dirName = "gemma4-meeting-agent-v11-gguf",
            revision = "https://huggingface.co/Luigi/gemma-4-E2B-meeting-agent-zh-GGUF/resolve/$REV",
            files = mapOf(
                GGUF to
                    (3_349_515_904L to "16c69abb76e09821bdd08a022091dbb9b84620cc589491f36d294e6ee92f73f0"),
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
            systemPromptFile = SYSTEM_PROMPT_FILE,
        ),
        // The mobile graphs (integration note §12, §13): Google's Gemma-4 mobile weights carrying our
        // fine-tune, run by the forked LiteRT engine on the CPU at 4k (cpp/mfa). The same system
        // prompt as v11, byte for byte.
        mobile(
            id = E2B_MOBILE_ID, displayName = "Gemma-4-E2B meeting agent mobile-v1 (zh)", shortName = "E2B",
            dirName = "gemma4-meeting-agent-e2b-mobile-v1",
            repo = "Luigi/gemma-4-E2B-meeting-agent-zh-GGUF", rev = "f47086170552f9b8e8719e9884af9fb9b56156d1",
            dir = "mobile-v1/mfa", prompt = "mobile-v1/system_prompt.txt",
            sizes = listOf(
                103_811_720L to "280327ee5720663acd2268c2e5d42caad33f70ba7931eef8c8b3018b4e2a4980",
                1_284_518_392L to "dca1e5553b4159558b17073c94fcc7ff16646e99a56a0614728435ac4b571720",
                818_394_320L to "6a7555ccc349be490fca4ed63ebf7fdafd8e4a4510012f3ae9c38f8009b5fcae",
            ),
        ),
        mobile(
            id = E4B_MOBILE_ID, displayName = "Gemma-4-E4B meeting agent (zh)", shortName = "E4B",
            dirName = "gemma4-meeting-agent-e4b-mobile",
            repo = "Luigi/gemma-4-E4B-meeting-agent-zh-LiteRT", rev = "70e095dc5db8d4edac901578a6e0f04d994ad95e",
            dir = "mfa", prompt = "system_prompt.txt",
            sizes = listOf(
                170_920_584L to "94cf45ffd3d0dd7040d27b22e70845cf1054db90613bf31d8ffc1623d23d4a40",
                836_778_512L to "d35fe41db89fa0128f5da9530886a12581cee715369e1b9ed9a3644e43d16a6a",
                2_260_210_576L to "34858194f4f596fae132470a2e0f2f0f276e540c7af8502e4ef7cca99e871424",
            ),
        ),
    )

    const val E2B_MOBILE_ID = "gemma4-e2b-meeting-agent-zh-mobile-v1"
    const val E4B_MOBILE_ID = "gemma4-e4b-meeting-agent-zh-mobile"

    /** embedder, per-layer embedder and the fused graph, in that order; plus the shared tokenizer. */
    private fun mobile(
        id: String, displayName: String, shortName: String, dirName: String, repo: String, rev: String,
        dir: String, prompt: String, sizes: List<Pair<Long, String>>,
    ) = LlmSpec(
        id = id, displayName = displayName, shortName = shortName, dirName = dirName,
        revision = "https://huggingface.co/$repo/resolve/$rev",
        files = mapOf(
            "$dir/Section1_SP_Tokenizer.spiece" to (4_689_013L to "e594c8a90eb08d8bda498ff4747977dc827ae0c3c56b5c0d41a605a22d02ef03"),
            "$dir/Section2_TFLiteModel_tf_lite_embedder.tflite" to sizes[0],
            "$dir/Section3_TFLiteModel_tf_lite_per_layer_embedder.tflite" to sizes[1],
            "$dir/prefill_decode_fused.tflite" to sizes[2],
            prompt to (1_686L to "406040c70270b5b9d47a4222138fcf2177f361dcbfb79fba164ca2559e0ffbf3"),
        ),
        mainFile = "$dir/prefill_decode_fused.tflite",
        tokenizerFile = "$dir/Section1_SP_Tokenizer.spiece",
        chatTemplate = ChatTemplate.GEMMA4,
        sampler = SamplerProfile.GEMMA_READER,
        maxCtx = 4096,
        backend = LlmBackend.MOBILE,
        systemPromptFile = prompt,
    )

    fun byId(id: String): LlmSpec =
        ALL.firstOrNull { it.id == id } ?: ALL.first { it.id == DEFAULT_ID }
}
