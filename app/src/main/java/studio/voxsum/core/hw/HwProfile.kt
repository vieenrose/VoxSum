package studio.voxsum.core.hw

import android.content.Context
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/** The user's thread choice: Auto follows the benchmark, the others force a count. */
enum class ThreadMode(val fixed: Int?) { AUTO(null), T2(2), T3(3), T4(4), T5(5), T6(6) }

/**
 * Pure rules turning the CPU layout and the benchmark into a thread count for the native engines
 * (ASR + diarization, the reader). No Android types, so they are unit-tested on the JVM.
 */
object ThreadPolicy {
    /** Cores above the efficiency cluster (all of them when the SoC reports a single frequency). */
    fun upperCores(freqs: List<Long>, cores: Int): Int {
        if (freqs.isEmpty()) return cores
        val low = freqs.min()
        return freqs.count { it > low }.takeIf { it > 0 } ?: freqs.size
    }

    /** The most threads ever used: past 6 the extra cores are efficiency cores or contend with the rest of the app. */
    const val MAX_THREADS = 6

    /** Without a benchmark: the upper cores, 2..4 (the benchmark is what earns 5 or 6), never more than the phone has. */
    fun heuristic(freqs: List<Long>, cores: Int): Int = clamp(minOf(upperCores(freqs, cores), 4), cores)

    /** Counts worth measuring: up to 4, and up to the fast cores (at most 6) on phones that have more of them. */
    fun candidates(cores: Int, upper: Int = 4): List<Int> =
        (2..minOf(maxOf(4, minOf(upper, MAX_THREADS)), cores)).toList().ifEmpty { listOf(1) }

    /** The fewest threads within [slack] of the best throughput: extra threads that buy nothing only compete with the rest of the app. */
    fun pick(scores: Map<Int, Double>, slack: Double = 0.05): Int? {
        val best = scores.values.maxOrNull() ?: return null
        return scores.filterValues { it >= best * (1 - slack) }.keys.min()
    }

    /** [capped]: a reading failed at a higher count on this phone — stay at 2 until the next benchmark. */
    fun resolve(mode: ThreadMode, benched: Int?, heuristic: Int, capped: Boolean, cores: Int): Int {
        mode.fixed?.let { return clamp(it, cores) }
        val base = benched ?: heuristic
        return clamp(if (capped) minOf(base, 2) else base, cores)
    }

    /** The floor of 2 stops a misread topology from handing XNNPACK one thread (roughly half the throughput). */
    private fun clamp(n: Int, cores: Int): Int = n.coerceIn(2, MAX_THREADS).coerceAtMost(cores.coerceAtLeast(1))
}

/** What the hardware check found, and what the engines will use. */
data class HwProfile(
    val cores: Int,
    val upperCores: Int,
    val totalRamMb: Long,
    val soc: String,
    val mode: ThreadMode,
    val benchThreads: Int?,
    val benchScores: Map<Int, Double>,
    val capped: Boolean,
    val threads: Int,
)

/**
 * Detects the phone (cores per frequency tier, RAM, SoC), keeps a tiny benchmark's verdict and
 * hands the engines their thread count. The benchmark runs once per SoC + app version, on first
 * launch, and on demand from Settings; until it has run, the topology heuristic applies.
 */
object HwInfo {
    private const val PREFS = "voxsum_hw"
    private val cores = Runtime.getRuntime().availableProcessors()
    private val freqs: List<Long> by lazy {
        runCatching {
            (0 until cores).mapNotNull { c ->
                File("/sys/devices/system/cpu/cpu$c/cpufreq/cpuinfo_max_freq")
                    .takeIf { it.exists() }?.readText()?.trim()?.toLongOrNull()
            }
        }.getOrDefault(emptyList())
    }
    private val soc: String = if (Build.VERSION.SDK_INT >= 31 && Build.SOC_MODEL.isNotBlank() && Build.SOC_MODEL != "unknown")
        Build.SOC_MODEL else "${Build.HARDWARE}/${Build.BOARD}"
    private val benchRunning = AtomicInteger(0)

    /** Re-measure when the phone's SoC, core count or the app's native code changes. */
    private fun key(context: Context): String {
        val v = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull()
        return "$soc|$cores|$v"
    }

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun mode(context: Context): ThreadMode =
        runCatching { ThreadMode.valueOf(prefs(context).getString("mode", null) ?: "AUTO") }.getOrDefault(ThreadMode.AUTO)

    fun setMode(context: Context, mode: ThreadMode) = prefs(context).edit().putString("mode", mode.name).apply()

    fun profile(context: Context): HwProfile {
        val p = prefs(context)
        val fresh = p.getString("benchKey", null) == key(context)
        val scores = if (fresh) parseScores(p.getString("scores", null)) else emptyMap()
        val benched = if (fresh) p.getInt("benchThreads", 0).takeIf { it > 0 } else null
        val capped = fresh && p.getBoolean("capped", false)
        val m = mode(context)
        val mi = android.app.ActivityManager.MemoryInfo()
        (context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager).getMemoryInfo(mi)
        return HwProfile(
            cores = cores, upperCores = ThreadPolicy.upperCores(freqs, cores), totalRamMb = mi.totalMem shr 20,
            soc = soc, mode = m, benchThreads = benched, benchScores = scores, capped = capped,
            threads = ThreadPolicy.resolve(m, benched, ThreadPolicy.heuristic(freqs, cores), capped, cores),
        )
    }

    /** The thread count for the native engines. */
    fun threads(context: Context): Int = profile(context).threads

    /** Key of the stored benchmark results: SoC, cores and app version. */
    fun benchKey(context: Context): String = key(context)

    /** What the engines were last loaded on; the status line shows a GPU / NPU gauge only for these. */
    @Volatile var activeBackend: Backend = Backend.CPU

    /** The backend to load the reader on: the user's choice while its last benchmark passed, else CPU. */
    fun backend(context: Context): Backend {
        val b = BackendBench.chosen(context)
        return if (b !in Backend.offered) Backend.CPU else if (b == Backend.CPU || BackendBench.results(context, key(context))[b]?.passed == true) b else Backend.CPU
    }

    fun benchDone(context: Context): Boolean = prefs(context).getString("benchKey", null) == key(context)

    /** Live ASR + reader at once also needs cores for both: below six they would fight over them. */
    fun liveCapable(): Boolean = cores >= 6

    /** A reading failed with more than 2 threads: stay at 2 on this phone (the queue retries the recording). */
    fun reportReadFailure(context: Context) {
        if (mode(context) != ThreadMode.AUTO || threads(context) <= 2) return
        prefs(context).edit().putString("benchKey", key(context)).putBoolean("capped", true).apply()
    }

    /** Runs the benchmark unless it already ran for this phone and app version ([force] re-runs it). Returns the profile. */
    suspend fun ensureBench(context: Context, force: Boolean = false): HwProfile {
        if ((force || !benchDone(context)) && benchRunning.compareAndSet(0, 1)) {
            try {
                val scores = withContext(Dispatchers.Default) { ThreadBench.run(ThreadPolicy.candidates(cores, ThreadPolicy.upperCores(freqs, cores))) }
                val best = ThreadPolicy.pick(scores)
                prefs(context).edit().putString("benchKey", key(context)).putString("scores", JSONObject(scores.mapKeys { it.key.toString() }).toString())
                    .putInt("benchThreads", best ?: 0).putBoolean("capped", false).apply()
            } finally { benchRunning.set(0) }
        }
        return profile(context)
    }

    private fun parseScores(s: String?): Map<Int, Double> = runCatching {
        val o = JSONObject(s ?: return emptyMap())
        o.keys().asSequence().associate { it.toInt() to o.getDouble(it) }
    }.getOrDefault(emptyMap())
}
