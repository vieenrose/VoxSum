package studio.voxsum.core.hw


/**
 * A ~1 s benchmark of how well this phone scales across threads. Each worker streams its slice of a
 * buffer larger than the caches with a multiply-add, the same memory-bound shape as the engines'
 * matrix-vector products. Scores are float elements per millisecond, best of [REPS] runs.
 */
object ThreadBench {
    private const val ELEMENTS = 1 shl 22      // 16 MB of floats, beyond the L2 of a phone SoC
    private const val PASSES = 6
    private const val REPS = 2

    fun run(candidates: List<Int>): Map<Int, Double> {
        val a = FloatArray(ELEMENTS) { (it and 1023) * 1e-3f }
        val b = FloatArray(ELEMENTS) { 1f - (it and 511) * 1e-3f }
        measure(1, a, b)   // JIT warm-up, not scored
        return candidates.associateWith { n ->
            (0 until REPS).maxOf { measure(n, a, b) }
        }
    }

    private fun measure(n: Int, a: FloatArray, b: FloatArray): Double {
        val sinks = FloatArray(n)
        val t0 = System.nanoTime()
        val workers = (0 until n).map { w ->
            Thread {
                val from = (ELEMENTS.toLong() * w / n).toInt()
                val to = (ELEMENTS.toLong() * (w + 1) / n).toInt()
                var acc = 0f
                repeat(PASSES) { for (i in from until to) acc += a[i] * b[i] }
                sinks[w] = acc
            }.apply { start() }
        }
        workers.forEach { it.join() }
        val ms = (System.nanoTime() - t0) / 1e6
        return ELEMENTS.toDouble() * PASSES / ms.coerceAtLeast(0.001)
    }
}
