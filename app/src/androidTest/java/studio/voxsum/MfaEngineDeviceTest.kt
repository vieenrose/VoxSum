package studio.voxsum

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import studio.voxsum.core.hw.Backend
import studio.voxsum.core.hw.BackendBench
import studio.voxsum.core.llm.MfaEngine
import studio.voxsum.core.llm.SpTokenizer
import java.io.File

/**
 * Smoke test of the mobile reader engine on a real model. Needs the E2B `mfa/` files pushed to
 * `files/mfa-e2b/` of the app under test (skipped otherwise):
 *   adb push … /data/local/tmp/mfa-e2b && adb shell run-as <pkg> cp -r /data/local/tmp/mfa-e2b files/
 */
@RunWith(AndroidJUnit4::class)
class MfaEngineDeviceTest {
    @Test fun loadsTokenizesAndWritesNotes() = writesNotes(Backend.CPU)

    /** The same reading on the GPU graph in `files/mfa-e2b-gpu/` (skipped when it is not pushed). */
    @Test fun writesNotesOnTheGpu() = writesNotes(Backend.GPU)

    private fun writesNotes(b: Backend) {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val dir = File(ctx.filesDir, "mfa-e2b")
        val main = if (b == Backend.GPU) File(ctx.filesDir, "mfa-e2b-gpu/prefill_decode_fused.tflite") else File(dir, "prefill_decode_fused.tflite")
        assumeTrue("model not pushed", File(dir, "prefill_decode_fused.tflite").exists() && main.exists())
        val tok = SpTokenizer.load(File(dir, "Section1_SP_Tokenizer.spiece").path)
        val system = File(dir, "system_prompt.txt").readText()
        val prompt = "<|turn>system\n$system<turn|>\n<|turn>user\n（尚無筆記）<turn|>\n<|turn>model\nNEXT<turn|>\n" +
            "<|turn>user\n## 逐字稿片段 1\n[0:00] S1: 好，那流程就這樣決定，六點半入場，七點開始，十點前結束。\n" +
            "[0:12] S2: 表演就請外面的樂團，報價八萬，我明天回覆他們。<turn|>\n<|turn>model\n"
        val ids = intArrayOf(MfaEngine.BOS) + tok.encode(prompt)
        assertTrue("special tokens parsed", 105 in ids && 106 in ids)
        val t0 = System.nanoTime()
        MfaEngine.load(dir.path, ctx = 4096, threads = Runtime.getRuntime().availableProcessors().coerceAtMost(8),
            weightCache = if (b == Backend.CPU) File(ctx.cacheDir, "mfa-e2b.wcache").path else "", backend = b.id, main = main.path).use { e ->
            val loadS = (System.nanoTime() - t0) / 1e9
            val out = e.generate(ids, maxNew = 200, temp = 0.2f, topK = 40, topP = 0.95f, seed = 0)
            val text = tok.decode(out)
            val st = e.lastStats!!
            android.util.Log.i("MfaEngineDeviceTest", "$b load %.1fs prompt %d prefill %.1fs decode %d in %.1fs\n%s"
                .format(loadS, ids.size, st.prefillSec, st.generated, st.decodeSec, text))
            assertTrue("wrote notes: $text", text.contains("NOTE"))
            // Prefix reuse: the same prompt again prefills nothing new.
            e.generate(ids, maxNew = 1, temp = 0f, topK = 1, topP = 1f, seed = 0)
            assertTrue("prefix reused", e.lastStats!!.reused >= ids.size - 1)
        }
        tok.close()
    }

    /**
     * The backend test on the real model: the CPU passes and sets the reference; the GPU, given its
     * graph in `files/mfa-e2b-gpu/` (skipped otherwise), passes or fails with a reason, never
     * silently. Its verdict and agreement are in the log (tag voxsum-backend).
     */
    @Test fun backendBenchJudgesTheGpu() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val dir = File(ctx.filesDir, "mfa-e2b")
        val gpu = File(ctx.filesDir, "mfa-e2b-gpu/prefill_decode_fused.tflite")
        assumeTrue("models not pushed", File(dir, "prefill_decode_fused.tflite").exists() && gpu.exists())
        val r = BackendBench.run(ctx, "device-test", dir.path, File(dir, "Section1_SP_Tokenizer.spiece").path, 4096,
            4, File(ctx.cacheDir, "mfa-e2b.wcache").path, gpu.path)
        android.util.Log.i("MfaEngineDeviceTest", "backends: $r")
        assertTrue("CPU passes: ${r[Backend.CPU]}", r[Backend.CPU]?.passed == true)
        val g = r[Backend.GPU]!!
        assertTrue("GPU judged: $g", g.passed || g.note.isNotEmpty())
    }
}
