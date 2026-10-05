package studio.voxsum.online

import java.io.File
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

/**
 * HTTP GET into [out] through a kept `<name>.part`: a cancelled or interrupted download leaves the
 * partial file so the next attempt continues with a `Range` request (206) and restarts from zero
 * only when the server ignores it (200). The `.part` is renamed to [out] on success.
 */
internal suspend fun resumableDownload(
    url: String,
    out: File,
    userAgent: String,
    maxBytes: Long = Long.MAX_VALUE,
    onProgress: (Float) -> Unit,
) {
    val tmp = File(out.parentFile, "${out.name}.part")
    val have = if (tmp.isFile) tmp.length() else 0L
    val conn = (URL(url).openConnection() as HttpURLConnection).apply {
        connectTimeout = 30_000; readTimeout = 30_000; instanceFollowRedirects = true
        setRequestProperty("User-Agent", userAgent)
        if (have > 0) setRequestProperty("Range", "bytes=$have-")
    }
    try {
        val code = conn.responseCode
        // 416 = the .part already holds the whole file (or is stale): start over.
        if (code == 416) { tmp.delete(); return resumableDownload(url, out, userAgent, maxBytes, onProgress) }
        // Fail on a non-2xx response instead of saving an error page's HTML as "audio".
        check(code in 200..299) { "Download failed (HTTP $code)" }
        val resumed = code == 206 && have > 0
        val start = if (resumed) have else 0L
        val total = conn.contentLengthLong.takeIf { it > 0 }?.let { it + start }
        conn.inputStream.use { input ->
            RandomAccessFile(tmp, "rw").use { f ->
                if (resumed) f.seek(start) else f.setLength(0)
                val buf = ByteArray(1 shl 16); var read = start
                while (true) {
                    coroutineContext.ensureActive()          // cancellation keeps the .part for resume
                    val n = input.read(buf); if (n < 0) break
                    f.write(buf, 0, n); read += n
                    check(read <= maxBytes) { "Download too large (over ${maxBytes / (1024 * 1024)} MB)" }
                    if (total != null) onProgress((read.toFloat() / total).coerceIn(0f, 1f))
                }
            }
        }
    } finally { conn.disconnect() }
    // Replace any stale prior download; surface a real move failure instead of a Uri to a missing file.
    if (!tmp.renameTo(out)) { out.delete(); check(tmp.renameTo(out)) { "Could not save the download" } }
}

/** Drop `.part` leftovers nobody resumed within [maxAgeMs]. */
internal fun sweepStaleParts(dir: File, maxAgeMs: Long = 24L * 3600_000) {
    val now = System.currentTimeMillis()
    dir.listFiles()?.filter { it.isFile && it.name.endsWith(".part") && now - it.lastModified() > maxAgeMs }
        ?.forEach { it.delete() }
}
