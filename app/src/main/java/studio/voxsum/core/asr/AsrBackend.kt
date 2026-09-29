package studio.voxsum.core.asr

/** ASR engine ids, recorded in each session as provenance. */
enum class AsrBackend(
    val id: String,
    val displayName: String,
    /** Compact name for the header status chip. */
    val shortName: String,
    /** One-word descriptor for the model-picker subtitle. */
    val tagline: String,
) {
    /** The only engine: streaming X-ASR + Nemotron-3 diarization in one pass. */
    NEMO("nemo", "X-ASR + Nemotron-3", "X-ASR", "streaming zh-en + speakers"),
    /** Retired LiteRT X-ASR — kept only so sessions it produced keep their provenance label. */
    XASR("x-asr", "Zipformer zh-en", "Zipformer", "zh-en transducer");

    companion object {
        fun fromId(id: String?): AsrBackend = entries.firstOrNull { it.id == id } ?: NEMO
    }
}
