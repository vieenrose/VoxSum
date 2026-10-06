package studio.voxsum.core.hw

import android.content.Context
import org.json.JSONObject
import studio.voxsum.core.llm.MfaEngine
import studio.voxsum.core.llm.SpTokenizer
import java.io.File

/** Where the reader's model runs. CPU is the default and the only backend the weight cache serves. */
enum class Backend(val id: Int) {
    CPU(0), GPU(1), NPU(2);

    companion object {
        /** NPU is plumbed through the engine but hidden: no dispatch library or NPU graph ships yet (docs/GPU_NPU.md). */
        val offered: List<Backend> = listOf(CPU, GPU)
    }
}

/** One backend's benchmark verdict. [passed] = the model loaded and generated on it. */
data class BackendResult(
    val backend: Backend,
    val passed: Boolean,
    val prefillTps: Double = 0.0,
    val decodeTps: Double = 0.0,
    /** Why it did not pass, as a code: no_runtime, crashed, unsupported, no_output. */
    val note: String = "",
)

/**
 * The reader on each backend, measured on a fixed prompt: the same model, the same 80-token prefill
 * and 16 generated tokens, so the numbers compare. GPU and NPU get a crash guard (a native abort
 * kills the process: the next launch finds the flag and records "crashed" for that backend), and the
 * NPU is only tried when its dispatch library ships with the app.
 */
object BackendBench {
    private const val PREFS = "voxsum_backend"
    private const val PROMPT = "會議討論新辦公室的搬遷時程，搬家公司報價有三種，發言者傾向中間價位，並要求合約註明損壞賠償條款。" +
        "資訊部自行搬運電腦與伺服器，三月七號搬家，三月十號正式上班。"

    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** NPU needs the vendor dispatch library next to libLiteRt.so; none ships today. */
    fun npuShipped(c: Context): Boolean =
        File(c.applicationInfo.nativeLibraryDir).listFiles()?.any { it.name.startsWith("libLiteRtDispatch_") } == true

    /** A crashed probe leaves its flag behind: turn it into a failed result. Call at startup. */
    fun settleCrash(c: Context, key: String) {
        val p = prefs(c)
        val crashed = p.getString("probing", null) ?: return
        val b = runCatching { Backend.valueOf(crashed) }.getOrNull()
        val e = p.edit().remove("probing")
        if (b != null) e.putString("r|$key|$crashed", encode(BackendResult(b, false, note = "crashed")))
        e.apply()
    }

    fun results(c: Context, key: String): Map<Backend, BackendResult> =
        Backend.offered.mapNotNull { b -> prefs(c).getString("r|$key|${b.name}", null)?.let { decode(b, it) }?.let { b to it } }.toMap()

    /** The user's choice, honoured only while that backend's last benchmark passed. */
    fun chosen(c: Context): Backend =
        runCatching { Backend.valueOf(prefs(c).getString("chosen", null) ?: "CPU") }.getOrDefault(Backend.CPU)

    fun choose(c: Context, b: Backend) = prefs(c).edit().putString("chosen", b.name).apply()

    /** [dir]: the reader model folder; [onStep] reports each backend as it starts. */
    fun run(c: Context, key: String, dir: String, tokenizer: String, ctx: Int, threads: Int, cache: String,
            onStep: (Backend) -> Unit = {}): Map<Backend, BackendResult> {
        val p = prefs(c)
        val out = linkedMapOf<Backend, BackendResult>()
        val tok = SpTokenizer.load(tokenizer)
        val ids = intArrayOf(MfaEngine.BOS) + tok.encode(PROMPT).take(80).toIntArray()
        tok.close()
        for (b in Backend.offered) {
            onStep(b)
            val r = when {
                b == Backend.NPU && !npuShipped(c) -> BackendResult(b, false, note = "no_runtime")
                else -> probe(c, b, dir, ids, ctx, threads, cache)
            }
            out[b] = r
            p.edit().putString("r|$key|${b.name}", encode(r)).apply()
        }
        if (out[chosen(c)]?.passed != true) choose(c, Backend.CPU)
        return out
    }

    private fun probe(c: Context, b: Backend, dir: String, ids: IntArray, ctx: Int, threads: Int, cache: String): BackendResult {
        val p = prefs(c)
        if (b != Backend.CPU) p.edit().putString("probing", b.name).commit()
        try {
            MfaEngine.load(dir, ctx, threads, if (b == Backend.CPU) cache else "", b.id).use { e ->
                e.generate(ids, 16, 0f, 1, 1f, 0)
                val s = e.lastStats ?: return BackendResult(b, false, note = "no_output")
                if (s.generated <= 0) return BackendResult(b, false, note = "no_output")
                return BackendResult(b, true, s.prefilled / s.prefillSec.coerceAtLeast(1e-3), s.generated / s.decodeSec.coerceAtLeast(1e-3))
            }
        } catch (t: Throwable) {
            android.util.Log.w("voxsum-backend", "$b probe failed", t)
            return BackendResult(b, false, note = "unsupported")
        } finally {
            p.edit().remove("probing").commit()
        }
    }

    private fun encode(r: BackendResult) = JSONObject().put("ok", r.passed).put("p", r.prefillTps).put("d", r.decodeTps).put("n", r.note).toString()
    private fun decode(b: Backend, s: String): BackendResult? = runCatching {
        val o = JSONObject(s); BackendResult(b, o.getBoolean("ok"), o.getDouble("p"), o.getDouble("d"), o.getString("n"))
    }.getOrNull()
}
