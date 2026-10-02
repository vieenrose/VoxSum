package studio.voxsum.data

import android.net.Uri
import studio.voxsum.core.events.TranscriptEvent

/**
 * In-memory session — the Android equivalent of the single global `state` object in
 * frontend/app.js. Holds the current audio source, decoded utterances, diarization
 * result, and summary. Loading a new audio source resets it (same rule as the web app).
 */
data class Session(
    val audioUri: Uri? = null,
    val title: String? = null,
    val utterances: List<TranscriptEvent.Utterance> = emptyList(),
    val speakerCount: Int? = null,
    val summary: String? = null,
    val asrModelId: String? = null,
    val llmModelId: String? = null,
)

/**
 * Speaker-name override — keyed by speaker id, kept separate from the per-utterance `speaker`
 * field (mirrors the web app's `state.speakerNames`). Survives the Complete re-render and is
 * the single source for display labels. confidence: "user" (edited) | "high"/"medium" (LLM).
 */
data class SpeakerName(
    val name: String,
    val confidence: String = "user",
    val reason: String = "User edited",
)

typealias SpeakerNames = Map<Int, SpeakerName>

/** The one label resolver used by transcript rows, timeline, and stats. */
fun speakerLabel(speakerId: Int?, names: SpeakerNames): String? =
    speakerId?.let { names[it]?.name ?: "Speaker ${it + 1}" }

/**
 * Per-speaker color palette. The first 10 entries are the EXACT port of
 * src/diarization.py::SPEAKER_COLORS (get_speaker_color wraps speaker_id % 10); entries
 * 10–29 extend it so >10 speakers never collide (the web app reuses colors past 10 — this
 * is an intentional improvement). The first eight are ordered for maximum hue separation (coral,
 * teal, amber, violet, sky, pink, green, yellow): meetings rarely exceed eight speakers, and the old
 * order put three blue-greens at speakers 2–4. ARGB Long, opaque.
 */
private val SPEAKER_PALETTE = longArrayOf(
    // First eight: one per hue family (red, blue, orange, violet, green, magenta, cyan, yellow) —
    // teal/sky and coral/pink used to sit next to each other and read as the same speaker.
    0xFFFF6B6B, 0xFF64B5F6, 0xFFFFB347, 0xFFB39DDB, 0xFF81C784,
    0xFFF06292, 0xFF4DD0E1, 0xFFFFF176, 0xFF96CEB4, 0xFFDDA0DD,
    0xFF87CEEB, 0xFFF0E68C, 0xFF80CBC4, 0xFFFFAB91, 0xFF9FA8DA,
    0xFFFFCC80, 0xFF90CAF9, 0xFFCE93D8, 0xFFEF9A9A, 0xFFC5E1A5,
    0xFFFFE082, 0xFF80DEEA, 0xFFBCAAA4, 0xFFE6EE9C, 0xFFF48FB1,
    0xFF81D4FA, 0xFFDCE775, 0xFFFFD54F, 0xFF4DD0E1, 0xFFAED581,
)

/** Per-speaker color — mirrors src/diarization.py::get_speaker_color. Canonical palette; used as-is
 *  for the cover-art fingerprint so it stays stable across themes. UI should prefer [speakerColorOn]. */
fun speakerColor(speaker: Int?): Long {
    if (speaker == null) return 0xFF607D8B
    val n = SPEAKER_PALETTE.size
    return SPEAKER_PALETTE[((speaker % n) + n) % n]
}

/**
 * Speaker color adjusted for the current theme. The base palette is bright pastels tuned for the
 * DARK theme; on light or e-ink (white) grounds those wash out — pale-on-white is illegible. Darken
 * them to ~55% for the light themes; since e-ink renders color as grey levels, a darker color is a
 * darker, higher-contrast grey, so the same transform serves both non-dark cases.
 */
/** Light/e-ink colours for the first eight speakers: deep, saturated and hue-distinct on white
 *  (darkening the dark-theme pastels uniformly made orange/yellow and teal/sky collapse into twins). */
private val SPEAKER_LIGHT8 = longArrayOf(
    0xFFD32F2F, 0xFF1565C0, 0xFFE65100, 0xFF6A1B9A, 0xFF2E7D32, 0xFFC2185B, 0xFF00838F, 0xFF8D6E00,
)

fun speakerColorOn(speaker: Int?, darkTheme: Boolean): Long {
    val c = speakerColor(speaker)
    if (darkTheme) return c
    if (speaker != null) {
        val i = ((speaker % SPEAKER_PALETTE.size) + SPEAKER_PALETTE.size) % SPEAKER_PALETTE.size
        if (i < SPEAKER_LIGHT8.size) return SPEAKER_LIGHT8[i]
    }
    val r = (((c ushr 16) and 0xFF) * 55 / 100)
    val g = (((c ushr 8) and 0xFF) * 55 / 100)
    val b = ((c and 0xFF) * 55 / 100)
    return 0xFF000000L or (r shl 16) or (g shl 8) or b
}
