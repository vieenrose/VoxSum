package studio.voxsum.core.config

import android.content.Context

/**
 * Persists the chosen [ThemeMode] across restarts. Kept in its own SharedPreferences file (separate
 * from [ConfigStore]'s pipeline config) since appearance is a UI preference, not transcription state.
 */
object ThemeStore {
    private const val PREFS = "voxsum_theme"
    private const val KEY = "themeMode"

    fun load(context: Context): ThemeMode {
        val name = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, ThemeMode.AUTO.name) ?: ThemeMode.AUTO.name
        return runCatching { ThemeMode.valueOf(name) }.getOrDefault(ThemeMode.AUTO)
    }

    fun save(context: Context, mode: ThemeMode) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, mode.name).apply()
    }

    private const val KEY_FONT = "fontScale"
    const val FONT_MIN = 0.85f
    const val FONT_MAX = 1.5f

    /** The app-wide text scale, multiplied over the system font size. */
    fun loadFontScale(context: Context): Float =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getFloat(KEY_FONT, 1f).coerceIn(FONT_MIN, FONT_MAX)

    fun saveFontScale(context: Context, scale: Float) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putFloat(KEY_FONT, scale).apply()
    }

    private const val KEY_HW = "hwMonitor"

    /** The CPU / RAM / battery gauges shown while recording and while the agent reads. On by default. */
    fun loadHwMonitor(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_HW, true)

    fun saveHwMonitor(context: Context, on: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_HW, on).apply()
    }
}
