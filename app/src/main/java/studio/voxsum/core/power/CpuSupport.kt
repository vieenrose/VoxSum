package studio.voxsum.core.power

import java.io.File

/**
 * The native engines are built for ARMv8.2-A with the int8 dot-product extension (CMakeLists.txt,
 * VOXSUM_ARM_ARCH). On a CPU without it (ARMv8.0 cores such as the Cortex-A53/A72/A73) the first
 * model load dies with SIGILL, so the app checks up front and says so instead of crashing.
 */
object CpuSupport {
    /** True when every core advertises `asimddp` (dotprod) in /proc/cpuinfo — or when it cannot
     *  be read (never refuse a device on a failed probe). */
    val hasDotProd: Boolean by lazy {
        runCatching {
            val features = File("/proc/cpuinfo").readLines().filter { it.startsWith("Features") }
            features.isEmpty() || features.all { " asimddp" in "$it " || "asimddp " in it }
        }.getOrDefault(true)
    }
}
