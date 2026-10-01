package studio.voxsum.core.config

import android.content.Context
import android.content.ContextWrapper
import android.content.res.Configuration
import android.content.res.Resources
import java.util.Locale

/**
 * The language of the interface AND of the Chinese text the app produces, chosen in one place.
 *
 * "auto" follows the device. The explicit choices force the string resources (`values/`,
 * `values-zh-rTW/`, `values-zh-rCN/`) without touching the system setting, and decide the Han
 * script every Chinese text is normalized to (see [scriptFor]) — so a zh-CN interface never shows
 * Traditional characters and a zh-TW one never shows Simplified ones.
 */
object AppLanguage {
    const val AUTO = "auto"
    const val EN = "en"
    const val ZH_TW = "zh-TW"
    const val ZH_CN = "zh-CN"
    val ALL = listOf(AUTO, EN, ZH_TW, ZH_CN)

    private const val PREFS = "voxsum_config"
    private const val KEY = "uiLanguage"

    fun load(context: Context): String {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        p.getString(KEY, null)?.takeIf { it in ALL }?.let { return it }
        // First run of a build that has this setting: an earlier explicit Traditional/Simplified
        // choice (the old "Chinese script" chips) that differs from what the device would give is
        // kept, now as the language; otherwise the device decides.
        val stored = p.getString("summaryScript", null)
        val code = when {
            stored == null -> AUTO
            stored == SummaryScript.defaultFor(systemLocale()).id -> AUTO
            stored == SummaryScript.SIMPLIFIED.id -> ZH_CN
            else -> ZH_TW
        }
        save(context, code)
        return code
    }

    fun save(context: Context, code: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, code).apply()
    }

    fun localeFor(code: String): Locale? = when (code) {
        EN -> Locale.ENGLISH
        ZH_TW -> Locale.TAIWAN
        ZH_CN -> Locale.SIMPLIFIED_CHINESE
        else -> null
    }

    /**
     * Chinese script that goes with a language choice. The Chinese choices are explicit; "auto"
     * follows the device region; English keeps whatever script was in use (an English interface
     * says nothing about Traditional versus Simplified).
     */
    fun scriptFor(code: String, current: SummaryScript, system: Locale = systemLocale()): SummaryScript =
        when (code) {
            ZH_CN -> SummaryScript.SIMPLIFIED
            ZH_TW -> SummaryScript.TRADITIONAL
            EN -> current
            else -> SummaryScript.defaultFor(system)
        }

    /** The device's own language, whatever this app has been told to show. */
    fun systemLocale(): Locale = Resources.getSystem().configuration.locales[0]

    /**
     * Switch the strings of an already running [activity] (and of every window it opens: menus,
     * sheets and dialogs build their own Compose roots from the activity's resources).
     */
    @Suppress("DEPRECATION")
    fun applyTo(activity: Context, code: String) {
        val res = activity.resources
        val cfg = Configuration(res.configuration).apply { setLocale(localeFor(code) ?: systemLocale()) }
        res.updateConfiguration(cfg, res.displayMetrics)
    }

    /** The resources for [code]; [base] untouched when it is "auto". */
    fun resourcesFor(base: Context, code: String): Resources {
        val locale = localeFor(code) ?: return base.resources
        val cfg = Configuration(base.resources.configuration).apply { setLocale(locale) }
        return base.createConfigurationContext(cfg).resources
    }

    /** [base] with the strings of [code]: still the same Activity/Service for everything else. */
    fun wrap(base: Context, code: String = load(base)): Context {
        if (localeFor(code) == null) return base
        val res = resourcesFor(base, code)
        return object : ContextWrapper(base) {
            override fun getResources(): Resources = res
        }
    }
}
