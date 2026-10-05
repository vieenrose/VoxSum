package studio.voxsum.online

import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ResumableDownloadTest {
    @get:Rule val tmp = TemporaryFolder()
    private val body = ByteArray(300_000) { (it % 251).toByte() }

    /** Minimal one-shot-per-connection HTTP server (the JDK's HttpServer isn't on the Android test classpath). */
    private class Srv(val body: ByteArray, val honorRange: Boolean, val seen: MutableList<String?>) {
        val sock = ServerSocket(0, 5, InetAddress.getByName("127.0.0.1"))
        val port get() = sock.localPort
        private val t = thread(isDaemon = true) {
            while (!sock.isClosed) {
                val c = try { sock.accept() } catch (_: Exception) { break }
                c.use {
                    val r = it.getInputStream().bufferedReader()
                    var range: String? = null
                    while (true) {
                        val l = r.readLine() ?: break
                        if (l.isEmpty()) break
                        if (l.startsWith("Range:", true)) range = l.substringAfter(':').trim()
                    }
                    seen += range
                    val from = if (honorRange) range?.removePrefix("bytes=")?.removeSuffix("-")?.toIntOrNull() ?: 0 else 0
                    val part = body.copyOfRange(from, body.size)
                    val head = (if (from > 0) "HTTP/1.1 206 Partial Content" else "HTTP/1.1 200 OK") +
                        "\r\nContent-Length: ${part.size}\r\nConnection: close\r\n\r\n"
                    it.getOutputStream().apply { write(head.toByteArray()); write(part); flush() }
                }
            }
        }
        fun stop() = sock.close()
    }

    @Test fun resumesFromPartWithRange() = runBlocking {
        val seen = mutableListOf<String?>(); val s = Srv(body, true, seen)
        val out = File(tmp.root, "a.mp3"); File(tmp.root, "a.mp3.part").writeBytes(body.copyOfRange(0, 100_000))
        resumableDownload("http://127.0.0.1:${s.port}/a", out, "t") {}
        s.stop()
        assertEquals("bytes=100000-", seen.single()); assertArrayEquals(body, out.readBytes())
        assertFalse(File(tmp.root, "a.mp3.part").exists())
    }

    @Test fun restartsWhenServerIgnoresRange() = runBlocking {
        val seen = mutableListOf<String?>(); val s = Srv(body, false, seen)
        val out = File(tmp.root, "b.mp3"); File(tmp.root, "b.mp3.part").writeBytes(ByteArray(5_000) { 9 })
        resumableDownload("http://127.0.0.1:${s.port}/a", out, "t") {}
        s.stop()
        assertArrayEquals(body, out.readBytes())
    }
}
