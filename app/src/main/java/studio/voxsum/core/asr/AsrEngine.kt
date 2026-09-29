package studio.voxsum.core.asr

/** Text utilities for the ASR output (the X-ASR transducer's zh-en spacing), plus the sample rate. */
object AsrEngine {
    const val SAMPLE_RATE = 16_000

    // Compiled once. zh-en decode-output normalization (see cleanTranscript).
    private val reRepeatCjk = Regex("([\\u4e00-\\u9fa5])\\1{2,}")
    private val reSpaceBetweenCjk = Regex("(?<=[\\u4e00-\\u9fa5])\\s+(?=[\\u4e00-\\u9fa5])")
    private val reSpaceBeforePunct = Regex("\\s+([，。、？！；：,.?!;:%])")
    private val reSpaceAfterCjkPunct = Regex("([，。、？！；：])\\s+(?=[\\u4e00-\\u9fa5])")

    /**
     * Mirror of src/asr.py::clean_transcript, extended with the X-ASR deployment's spacing rules.
     * The zh-en transducer emits each CJK token with a `▁`-derived leading space and keeps
     * spaces around punctuation, so raw text reads "礼拜二 ， 第二种". Strip U+FFFD, collapse a
     * CJK char repeated 3+ times (ASR stutter), drop spaces between Chinese characters, and tighten
     * CJK/ASCII punctuation. English word spacing ("today is") is preserved; no-op for pure-English
     * output.
     */
    fun cleanTranscript(text: String): String {
        var t = text.replace("�", "")
        t = reRepeatCjk.replace(t) { it.groupValues[1] }
        t = reSpaceBetweenCjk.replace(t, "")
        t = reSpaceBeforePunct.replace(t, "$1")
        t = reSpaceAfterCjkPunct.replace(t, "$1")
        return t
    }
}
