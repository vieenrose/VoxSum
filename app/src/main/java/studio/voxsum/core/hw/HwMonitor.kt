package studio.voxsum.core.hw

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.SystemClock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import java.io.File

/** One reading of the hardware the pipeline is leaning on. Null = not readable on this device. */
data class HwSample(
    /** This process's share of the whole CPU: the ASR and the reader both run in it. */
    val cpuPct: Int,
    /** Only while the reader runs on the GPU (Adreno sysfs); null otherwise. */
    val gpuPct: Int?,
    /** The reader runs on the NPU: no app-readable load figure exists, so only its presence is shown. */
    val npuActive: Boolean,
    val ramPct: Int,
    val batteryPct: Int,
    val charging: Boolean,
    val tempC: Int?,
)

/**
 * Samples every [periodMs] while collected — cold, so nothing runs once the UI stops looking.
 * `/proc/stat` is closed to apps since Android 8, so CPU is our own process time (`/proc/self/stat`)
 * over wall time and cores; there is no GPU API, so it is read from Adreno's sysfs when readable.
 */
fun hwSamples(context: Context, periodMs: Long = 2000): Flow<HwSample> = flow {
    val app = context.applicationContext
    val am = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    val cores = Runtime.getRuntime().availableProcessors()
    val tickHz = 100.0   // USER_HZ: fixed at 100 on Android kernels
    var lastTicks = readSelfTicks()
    var lastAt = SystemClock.elapsedRealtime()
    while (true) {
        delay(periodMs)
        val ticks = readSelfTicks()
        val now = SystemClock.elapsedRealtime()
        val cpu = cpuPercent(ticks - lastTicks, tickHz, now - lastAt, cores)
        lastTicks = ticks; lastAt = now
        val mi = ActivityManager.MemoryInfo().also(am::getMemoryInfo)
        val bat = app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = bat?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = bat?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val status = bat?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val temp = bat?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE) ?: Int.MIN_VALUE
        emit(HwSample(
            cpuPct = cpu,
            gpuPct = if (HwInfo.activeBackend == Backend.GPU) readGpu() else null,
            npuActive = HwInfo.activeBackend == Backend.NPU,
            ramPct = (100 - mi.availMem * 100 / mi.totalMem).toInt(),
            batteryPct = if (level >= 0 && scale > 0) level * 100 / scale else -1,
            charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL,
            tempC = if (temp == Int.MIN_VALUE) null else temp / 10,
        ))
    }
}.flowOn(Dispatchers.IO)

private fun readSelfTicks(): Long = runCatching { parseStatTicks(File("/proc/self/stat").readText()) }.getOrDefault(0L)

/** utime + stime from a `/proc/<pid>/stat` line. `comm` may hold spaces and parens, so split after the LAST ')'. */
internal fun parseStatTicks(stat: String): Long {
    val f = stat.substring(stat.lastIndexOf(')') + 2).split(' ')
    // After comm: [0]=state … utime is field 14 overall → index 11 here, stime index 12.
    return f[11].toLong() + f[12].toLong()
}

internal fun cpuPercent(dTicks: Long, tickHz: Double, dMs: Long, cores: Int): Int =
    if (dMs <= 0 || cores <= 0) 0
    else (dTicks / tickHz * 1000.0 / dMs / cores * 100).toInt().coerceIn(0, 100)

private val GPU_BUSY = File("/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage")

private fun readGpu(): Int? = runCatching {
    GPU_BUSY.readText().trim().removeSuffix("%").trim().toInt().coerceIn(0, 100)
}.getOrNull()
