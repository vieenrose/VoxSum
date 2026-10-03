package studio.voxsum.core.reader

/**
 * The reader model names speakers S1, S2, … — the labels it reads in the transcript lines
 * ([ReaderLane] writes speaker id n as "S{n+1}"; it was fine-tuned on them, so they stay in what it
 * writes and in what is saved). Everything SHOWN or exported names them as the transcript does:
 * "語者 2" / "说话人 2" / "Speaker 2", or the name the user gave. Applied at display time only, so a
 * later rename reaches the summary too.
 */
object SpeakerRefs {
    // An isolated S + number: not inside an ASCII word or code ("S20X", "AS2", "S2B" stay).
    private val REF = Regex("(?<![A-Za-z0-9_])S(\\d{1,2})(?![A-Za-z0-9_])")

    /** [known]: speaker ids present in the transcript, or null to accept any. An S-number with no
     *  such speaker (a model slip) is left as written rather than given an invented name. */
    fun resolve(
        text: String, label: (Int) -> String, known: Set<Int>? = null,
        /** Dresses the name, e.g. `**name**` for the Markdown cards. */
        wrap: (String) -> String = { it },
    ): String =
        REF.replace(text) { m ->
            val id = m.groupValues[1].toInt() - 1
            if (id < 0 || (known != null && id !in known)) return@replace m.value
            val name = label(id)
            // Chinese takes no space before a Chinese name: "而 S1 則" → "而語者 1 則".
            val glued = m.range.first >= 2 && text[m.range.first - 1] == ' ' &&
                isHan(text[m.range.first - 2]) && name.isNotEmpty() && isHan(name[0])
            // A name ending in a digit or a Latin letter ("語者 1", "Speaker 1", "Mary") runs into the
            // Chinese after it: "語者 1將…" → "語者 1 將…", as the spacing of the name itself reads.
            val end = m.range.last + 1
            val spaced = name.isNotEmpty() && name.last().isLetterOrDigit() && !isHan(name.last()) && end < text.length && isHan(text[end])
            (if (glued) "\u0000" else "") + wrap(name) + (if (spaced) " " else "")
        }.replace(" \u0000", "")

    private fun isHan(c: Char) = Character.UnicodeScript.of(c.code) == Character.UnicodeScript.HAN
}
