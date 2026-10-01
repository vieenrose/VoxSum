package studio.voxsum.core.models

/**
 * One progress bar for downloads that overlap. The speech engine's files and the reader's start
 * together on 8 GB phones; each reporting on its own bar made it jump (90 % speech, 2 % reader, ...).
 * The combined fraction is bytes received over bytes wanted across the whole burst, so it only goes
 * forward, and a finished download keeps counting until every download of the burst is done.
 */
class DownloadAggregate {
    private val parts = LinkedHashMap<String, Pair<Long, Float>>()   // key -> (total bytes, fraction)
    private var active = 0

    @Synchronized fun begin(key: String, totalBytes: Long) {
        if (active == 0) parts.clear()
        active++
        parts[key] = totalBytes.coerceAtLeast(1L) to 0f
    }

    @Synchronized fun end(key: String) {
        parts[key]?.let { parts[key] = it.first to 1f }
        active--
    }

    /** Record [fraction] for [key]; the combined fraction and whether several downloads are running. */
    @Synchronized fun update(key: String, fraction: Float): Pair<Float, Boolean> {
        parts[key]?.let { parts[key] = it.first to fraction.coerceIn(0f, 1f) }
        val total = parts.values.sumOf { it.first }.toDouble()
        val got = parts.values.sumOf { it.first * it.second.toDouble() }
        val overall = if (total > 0) (got / total).toFloat() else fraction
        return overall.coerceIn(0f, 1f) to (active > 1)
    }
}
