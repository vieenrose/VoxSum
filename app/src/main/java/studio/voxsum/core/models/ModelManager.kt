package studio.voxsum.core.models

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import studio.voxsum.core.asr.NemoModelFiles
import java.io.File
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Lazy, first-run model provisioning — Android counterpart of the "download on first use"
 * behaviour in src/utils.py. Models are NOT bundled in the APK (F-Droid: keeps the build
 * lean and the APK FOSS); they download once into app-private storage, or can be
 * side-loaded (adb push / file copy) so the app works fully network-free.
 *
 * Phase 1 provisions the ASR models only (ASR + Silero VAD). The LLM (Phase 2) and
 * diarization models (Phase 3) extend this with the same pattern.
 */
class ModelManager(context: Context) {

    val modelsDir: File = File(context.filesDir, "models").apply { mkdirs() }

    init {
        // Reclaim long-dropped backends' models on construction. The engines retired by the
        // nemo switch (LITERT_RETIRED) are reclaimed only once the new models verify, in
        // ensureAsrModels, so a failed download never leaves the device without an engine.
        DROPPED_BACKEND_DIRS.filterNot { it in LITERT_RETIRED }
            .forEach { File(modelsDir, it).takeIf(File::exists)?.deleteRecursively() }
        DROPPED_FILES.filterNot { it in LITERT_RETIRED }
            .forEach { File(modelsDir, it).takeIf(File::exists)?.delete() }
    }

    // --- ASR + diarization: nemo-x-asr-diarizer, two revision-pinned GGUFs. -----------------------
    //   x-asr-zh-en q8_0     — streaming Zipformer2 transducer, zh + en (Apache-2.0)
    //   Nemotron-3 diar q8_0 — streaming Sortformer diarization, up to 8 speakers (OpenMDW-1.1)
    val nemoDir: File get() = File(modelsDir, NEMO_DIR)

    fun asrFiles(): NemoModelFiles =
        NemoModelFiles(xasr = File(nemoDir, XASR_FILE), diar = File(nemoDir, DIAR_FILE))

    /** Both GGUFs present at their pinned size and stamped with the pinned revision set. Cheap (no
     *  hashing): the SHA-256 check happens once, at download. */
    /** Bytes the speech engine's two files weigh — the weight of its share in a combined progress bar. */
    fun asrDownloadBytes(): Long = NEMO_FILES.values.sumOf { it.bytes }

    fun asrReady(): Boolean =
        NEMO_FILES.all { (name, meta) -> File(nemoDir, name).length() == meta.bytes } &&
            runCatching { File(nemoDir, REVISION_MARKER).readText().trim() }.getOrNull() == NEMO_REVISION

    /** Remove the model directory so the next run re-downloads a clean copy (load failure recovery). */
    fun deleteAsr() {
        nemoDir.takeIf(File::exists)?.deleteRecursively()
    }

    /** Download both GGUFs if missing or from a different pinned revision. */
    suspend fun ensureAsrModels(onProgress: (Float) -> Unit) = withContext(Dispatchers.IO) {
        if (asrReady()) { reclaimRetired(); onProgress(1f); return@withContext }
        nemoDir.mkdirs()
        val marked = runCatching { File(nemoDir, REVISION_MARKER).readText().trim() }.getOrNull() == NEMO_REVISION
        val total = NEMO_FILES.values.sumOf { it.bytes }
        var done = 0L
        NEMO_FILES.forEach { (name, meta) ->
            val dest = File(nemoDir, name)
            if (dest.length() != meta.bytes || !marked) {
                dest.delete()
                download(meta.url, dest, meta.sha256) { frac ->
                    onProgress((done + (frac * meta.bytes).toLong()).toFloat() / total)
                }
            }
            done += meta.bytes
            onProgress(done.toFloat() / total)
        }
        runCatching { File(nemoDir, REVISION_MARKER).writeText(NEMO_REVISION) }
        check(asrReady()) { "ASR model files missing after provisioning" }
        reclaimRetired()
    }

    /** Only once the new models verify (also when they were already present — seeded or from an
     *  earlier run): reclaim every retired engine's files. */
    private fun reclaimRetired() {
        DROPPED_BACKEND_DIRS.forEach { File(modelsDir, it).takeIf(File::exists)?.deleteRecursively() }
        DROPPED_FILES.forEach { File(modelsDir, it).takeIf(File::exists)?.delete() }
    }

    /** Superseded reader models, deleted only once the current one verifies (a failed download
     *  never leaves the device without a summarizer). */
    private fun reclaimRetiredLlm() {
        RETIRED_LLM_DIRS.forEach { File(modelsDir, it).takeIf(File::exists)?.deleteRecursively() }
    }

    // --- LLM: a revision-pinned, multi-file artifact set under its own directory. --------------
    // The summarizer is no longer a single `.litertlm` bundle: it is a LiteRT graph + a PRE-PACKED
    // XNNPACK weight cache + a tokenizer blob. The weight cache is the load-bearing part — without
    // it XNNPACK materialises ~800 MiB of UNRECLAIMABLE anonymous memory at load and the
    // lowmemorykiller takes the app; with it those pages are file-backed and evictable. It is bound
    // to the exact app-shipped libLiteRt.so build (app/src/main/jniLibs/arm64-v8a), so repack and
    // re-pin it whenever that library is upgraded — a stale cache is rejected loudly (the header
    // carries a version) and the engine then falls back to a multi-minute on-device pack.
    fun llmDir(spec: LlmSpec): File = File(modelsDir, spec.dirName)
    fun llmFile(spec: LlmSpec): File = File(llmDir(spec), spec.mainFile)
    fun llmWeightCache(spec: LlmSpec): File? =
        spec.weightCacheFile.takeIf { it.isNotBlank() }?.let { File(llmDir(spec), it) }
    fun llmTokenizer(spec: LlmSpec): File = File(llmDir(spec), spec.tokenizerFile)

    fun llmReady(spec: LlmSpec): Boolean =
        spec.files.all { (rel, meta) -> File(llmDir(spec), rel).length() == meta.first } &&
            runCatching { File(llmDir(spec), REVISION_MARKER).readText().trim() }.getOrNull() == spec.revision

    // No-arg convenience over the default model (used by tests / the device push flow).
    val llmModel: File get() = llmFile(LlmRegistry.byId(LlmRegistry.DEFAULT_ID))
    fun llmReady(): Boolean = llmReady(LlmRegistry.byId(LlmRegistry.DEFAULT_ID))

    // --- Storage manager: enumerate + delete downloaded models (each re-downloads on next use). ---

    enum class ModelKind { ASR, LLM, OTHER }

    /** A model artifact (file or folder) on disk. [delete] reclaims it; it re-downloads on next use. */
    data class StoredModel(val name: String, val kind: ModelKind, val bytes: Long, private val path: File) {
        fun delete(): Boolean = if (path.isDirectory) path.deleteRecursively() else path.delete()
    }

    /** Every model currently on disk under [modelsDir], largest first, with a coarse kind for labels.
     *  Note: a model in use is memory-mapped, so deleting it just unlinks the name — the running
     *  inference keeps its open handle and finishes fine; the space frees once it's released. */
    fun storedModels(): List<StoredModel> =
        (modelsDir.listFiles()?.toList() ?: emptyList())
            .filterNot { it.isFile && (it.name.endsWith(PART_SUFFIX) || it.name.endsWith("$PART_SUFFIX.vld")) }   // hide in-flight/stale temp files
            .map { f -> StoredModel(f.name, kindOf(f.name), dirSize(f), f) }
            .filter { it.bytes > 0L }
            .sortedByDescending { it.bytes }

    /**
     * Delete leftover "<name>.part" temp files from downloads that were interrupted (the app was
     * killed mid-fetch, so [download]'s own cleanup never ran). Safe to call at startup — no download
     * is in flight yet, so every ".part" is stale — and it reclaims space a partial download stranded.
     */
    fun sweepStalePartFiles() {
        runCatching {
            modelsDir.walkTopDown()
                .filter { it.isFile && (it.name.endsWith(PART_SUFFIX) || it.name.endsWith("$PART_SUFFIX.vld")) }
                .forEach { it.delete() }
        }
    }

    private fun dirSize(f: File): Long =
        if (f.isDirectory) (f.listFiles()?.sumOf { dirSize(it) } ?: 0L) else f.length()

    private fun kindOf(name: String): ModelKind {
        val n = name.lowercase()
        return when {
            n == NEMO_DIR -> ModelKind.ASR
            LlmRegistry.ALL.any { it.dirName == n } -> ModelKind.LLM
            // MOSS-TD is an ASR model that happens to ship as a .gguf — classify it before the
            // generic gguf→LLM rule below, or Settings lists it as a summary model.
            n.startsWith("moss-td") || n.startsWith("moss-transcribe") || n.startsWith("moss_td") -> ModelKind.ASR
            n.endsWith(".gguf") || n.endsWith(".litertlm") || n.startsWith("qwen35-") -> ModelKind.LLM
            n.contains("asr") || n.contains("sense-voice") || n.contains("sensevoice") || n.contains("qwen") || n.startsWith("sherpa") -> ModelKind.ASR
            else -> ModelKind.OTHER
        }
    }

    /**
     * Ensure every file of the summarizer artifact set for [spec] is present, the right size and
     * the right sha256, downloading what is missing. Revision-pinned: a directory left over from a
     * different pinned revision is re-fetched rather than half-trusted, because the weight cache
     * and the graph must come from the same export (a cache from another build is rejected at load
     * and costs the user a silent multi-minute on-device repack).
     */
    suspend fun ensureLlmModel(spec: LlmSpec, onProgress: (Float) -> Unit) = withContext(Dispatchers.IO) {
        if (llmReady(spec)) { reclaimRetiredLlm(); onProgress(1f); return@withContext }
        val dir = llmDir(spec).apply { mkdirs() }
        val marked = runCatching { File(dir, REVISION_MARKER).readText().trim() }.getOrNull() == spec.revision
        val total = spec.totalBytes
        var done = 0L
        spec.files.forEach { (rel, meta) ->
            val (bytes, sha) = meta
            val dest = File(dir, rel).apply { parentFile?.mkdirs() }
            if (dest.length() != bytes || !marked) {
                download("${spec.revision}/$rel", dest, sha) { frac ->
                    onProgress((done + (frac * bytes).toLong()).toFloat() / total)
                }
            }
            done += bytes
            onProgress(done.toFloat() / total)
        }
        runCatching { File(dir, REVISION_MARKER).writeText(spec.revision) }
        check(llmReady(spec)) { "${spec.displayName} files missing after provisioning" }
        reclaimRetiredLlm()
    }

    /** No-arg convenience over the default model. */
    suspend fun ensureLlmModel(onProgress: (Float) -> Unit) =
        ensureLlmModel(LlmRegistry.byId(LlmRegistry.DEFAULT_ID), onProgress)

    /**
     * Download to a temp file, verify its SHA-256 (when pinned), then atomically rename into
     * place. A checksum mismatch deletes the temp file and throws — no half-trusted model is
     * ever used. The pins are the FOSS release artifacts' real hashes (see manifest / below).
     */
    private suspend fun download(url: String, dest: File, sha256: String? = null, onProgress: (Float) -> Unit) {
        // Serialize downloads that target the SAME destination. Two coroutines can race to provision
        // the same model — e.g. the pipeline's summarize() and a user-triggered "re-detect names" both
        // call ensureLlmModel for the same GGUF, both see it absent, and both open the shared
        // "<name>.part" temp file (outputStream() truncates on open), interleaving writes into a corrupt
        // model that is then committed and crashes llama.cpp on mmap on every load until app data is
        // cleared. One Mutex per destination + an existence re-check inside it make the loser a no-op.
        val mutex = downloadLocks.computeIfAbsent(dest.absolutePath) { Mutex() }
        mutex.withLock {
            if (dest.exists()) return@withLock
            val tmp = File(dest.parentFile, "${dest.name}$PART_SUFFIX")
            fun clearPartial() { tmp.delete(); File(tmp.parentFile, "${tmp.name}.vld").delete() }
            // Retry transient failures (flaky mobile network, a 5xx, a body that fails the checksum)
            // with linear backoff. A transient failure KEEPS the .part so the next attempt RESUMES
            // from where the stream died (Range request in fetchToFile) — on weak Wi-Fi a large
            // model whose connection keeps dropping would otherwise restart from zero every retry
            // and never complete (observed on-device: a 14 MB file dying "unexpected end of stream"
            // three times in a row). Only a checksum mismatch — corrupt bytes — restarts clean.
            // Abort immediately on user-cancel and on permanent errors (404 / out-of-disk).
            var attempt = 0
            while (true) {
                attempt++
                try {
                    fetchToFile(url, tmp, onProgress)
                    if (sha256 != null) {
                        val actual = sha256Of(tmp)
                        if (!actual.equals(sha256, ignoreCase = true))
                            throw ChecksumMismatch("expected ${sha256.take(12)}..., got ${actual.take(12)}...")
                    }
                    File(tmp.parentFile, "${tmp.name}.vld").delete()   // done — drop the resume validator
                    check(tmp.renameTo(dest)) { "Could not move ${tmp.name} into place" }
                    return@withLock
                } catch (ce: kotlinx.coroutines.CancellationException) {
                    clearPartial(); throw ce
                } catch (e: Exception) {
                    if (e is ChecksumMismatch) clearPartial()   // corrupt bytes — resume can't fix them
                    if (e is ModelNotFound || isOutOfSpace(e) || attempt >= MAX_DOWNLOAD_ATTEMPTS) {
                        clearPartial()
                        throw java.io.IOException(downloadErrorMessage(e, dest.name, attempt), e)
                    }
                    delay(RETRY_BACKOFF_MS * attempt)
                }
            }
        }
    }

    /** One attempt: HTTP GET [url] → [tmp], checking the status code and cooperating with cancellation
     *  (a blocking read() never self-checks, so the loop must, or Stop can't abort a multi-GB fetch).
     *  A non-empty [tmp] is RESUMED with a Range request (HF/CDNs support it); a server that ignores
     *  the range (plain 200) truncates and starts over, and 416 (our offset is past the end — a
     *  stale .part from a changed upstream file) clears the partial so the retry starts clean. */
    private suspend fun fetchToFile(url: String, tmp: File, onProgress: (Float) -> Unit) {
        val offset = tmp.length()
        // Integrity for unpinned (no-checksum) resumes: a plain Range resume assumes the upstream
        // file is byte-identical to the partial — but a CDN/mirror could serve a changed file,
        // committing head(old)+tail(new). If-Range makes the server honour the range ONLY when the
        // validator (ETag/Last-Modified, captured on the first fetch into a .vld sidecar) still
        // matches; otherwise it returns a full 200 and we truncate + restart clean below.
        val vld = File(tmp.parentFile, "${tmp.name}.vld")
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30_000; readTimeout = 30_000; instanceFollowRedirects = true
            if (offset > 0) {
                setRequestProperty("Range", "bytes=$offset-")
                vld.takeIf { it.exists() }?.let { setRequestProperty("If-Range", it.readText()) }
            }
        }
        try {
            val code = conn.responseCode
            val resumed = code == 206 && offset > 0
            // Remember the validator for the NEXT resume (only useful when the server supports it).
            (conn.getHeaderField("ETag") ?: conn.getHeaderField("Last-Modified"))
                ?.let { runCatching { vld.writeText(it) } }
                ?: runCatching { vld.delete() }
            when {
                code == 206 || code in 200..299 -> {}
                code == 404 -> throw ModelNotFound("HTTP 404")
                code == 416 -> { tmp.delete(); vld.delete(); throw java.io.IOException("server returned HTTP 416 (stale partial cleared)") }
                else -> throw java.io.IOException("server returned HTTP $code")
            }
            conn.inputStream.use { input ->
                val body = conn.contentLengthLong.takeIf { it > 0 }
                val total = if (resumed) body?.plus(offset) else body
                java.io.FileOutputStream(tmp, /* append = */ resumed).use { out ->
                    val buf = ByteArray(1 shl 16)
                    var read = if (resumed) offset else 0L
                    while (true) {
                        coroutineContext.ensureActive()
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        read += n
                        if (total != null) onProgress((read.toFloat() / total).coerceIn(0f, 1f))
                    }
                }
            }
        } finally {
            conn.disconnect()
        }
    }

    private class ModelNotFound(msg: String) : java.io.IOException(msg)
    private class ChecksumMismatch(msg: String) : java.io.IOException(msg)

    /** True if [e] (or a cause) is an out-of-disk-space failure — retrying the download can't help. */
    private fun isOutOfSpace(e: Throwable): Boolean {
        var t: Throwable? = e
        while (t != null) {
            val m = t.message ?: ""
            if (m.contains("ENOSPC", ignoreCase = true) || m.contains("No space", ignoreCase = true)) return true
            t = t.cause
        }
        return false
    }

    /** A clear, actionable message for the failure surfaced to the user (TranscriptEvent.Failed). */
    private fun downloadErrorMessage(e: Throwable, name: String, attempts: Int): String {
        val tries = if (attempts > 1) " after $attempts attempts" else ""
        return when {
            e is ChecksumMismatch -> "$name download was corrupted (checksum mismatch)$tries. Please try again."
            e is ModelNotFound -> "$name isn't available on the server (404) — try updating the app."
            isOutOfSpace(e) -> "Not enough storage to download $name. Free up space and try again."
            e is UnknownHostException -> "No internet connection while downloading $name. Reconnect and try again."
            e is SocketTimeoutException -> "Download of $name timed out$tries. Check your connection and try again."
            else -> "Couldn't download $name$tries: ${e.message ?: e.javaClass.simpleName}."
        }
    }

    private fun sha256Of(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { ins ->
            val buf = ByteArray(1 shl 16)
            while (true) { val n = ins.read(buf); if (n < 0) break; md.update(buf, 0, n) }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    companion object {
        /** Written next to a spec's files, recording the pinned revision they came from. */
        const val REVISION_MARKER = ".revision"

        // Per-destination download locks, shared across ALL ModelManager instances (the UI's
        // detect-names path constructs its own ModelManager), so concurrent first-run downloads of the
        // same file can't interleave-corrupt the shared ".part" temp. See download().
        private val downloadLocks = ConcurrentHashMap<String, Mutex>()

        // Retry transient download failures (flaky network, a 5xx, a body that fails the checksum)
        // with linear backoff before giving up; permanent errors (404 / out-of-disk) abort at once.
        // Attempts are cheap now that retries RESUME the partial file — each one makes forward
        // progress, so more attempts = strictly better odds on a flaky link.
        private const val MAX_DOWNLOAD_ATTEMPTS = 6
        private const val RETRY_BACKOFF_MS = 1500L

        /** True if [f] looks like a complete GGUF: starts with the "GGUF" magic and is at least 90% of
         *  [expectedBytes] — catches truncated/corrupt downloads without pinning an exact (upstream-
         *  mutable) hash. Exposed for unit tests; see ensureLlmModel(). */
        internal fun isValidGguf(f: File, expectedBytes: Long): Boolean {
            if (expectedBytes > 0 && f.length() < expectedBytes / 10 * 9) return false
            return runCatching {
                f.inputStream().use { ins ->
                    val magic = ByteArray(4)
                    ins.read(magic) == 4 &&
                        magic[0] == 'G'.code.toByte() && magic[1] == 'G'.code.toByte() &&
                        magic[2] == 'U'.code.toByte() && magic[3] == 'F'.code.toByte()
                }
            }.getOrDefault(false)
        }

        /** Integrity check dispatching on artifact type: `.litertlm` bundles start with the
         *  ASCII magic "LITERTLM"; everything else is a GGUF. */
        internal fun isValidLlmFile(f: File, expectedBytes: Long): Boolean {
            if (!f.name.endsWith(".litertlm")) return isValidGguf(f, expectedBytes)
            if (expectedBytes > 0 && f.length() < expectedBytes / 10 * 9) return false
            return runCatching {
                f.inputStream().use { ins ->
                    val magic = ByteArray(8)
                    ins.read(magic) == 8 && magic.toString(Charsets.US_ASCII) == "LITERTLM"
                }
            }.getOrDefault(false)
        }

        // Mirrors models/manifest.json. All FOSS-licensed. LLM specs live in LlmRegistry.
        /** Suffix of the temp file a download streams into before it's verified and renamed into place. */
        private const val PART_SUFFIX = ".part"

        /** Dirs of backends dropped in 2026-07 (SenseVoice LiteRT + sherpa, Qwen3) and 2026-08
         *  (Nemotron — a held-out zh-TW bench showed it ~2x worse CER than X-ASR, and the app
         *  targets zh-TW meetings only, not the 25-language coverage Nemotron traded accuracy
         *  for), reclaimed on upgrade. */
        private val DROPPED_BACKEND_DIRS = listOf(
            "nemotron-litert",
            "sensevoice-litert",
            "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
            "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
            // TurboQuant TQ3 summarizer, retired with Gemma 4: the engine existed ONLY to run
            // Gemma 4 E2B on low-RAM devices, and Qwen3.5-0.8B now does that job strictly better
            // (3.4 vs ~1 tok/s, 874 MB of artifacts vs 6.9 GB, and it is not LMK-killed). This is
            // the single biggest reclaim in the app's history — existing installs that ever opted
            // in are carrying ~6.9 GiB of dead weight.
            "tq3-litert",
            // LiteRT summarizer artifact set (graph + pre-packed XNNPACK weight cache +
            // tokenizer, ~874 MB), retired when the summarizer moved back to llama.cpp/GGUF.
            // Gemma 4 was the only reason LiteRT-LM was worth its costs and Gemma 4 is gone;
            // with it go the baked-in context length, the hand-written NEON int8-KV kernel and
            // the weight cache that had to exist because XNNPACK materialised ~800 MiB of
            // unreclaimable anonymous memory. llama.cpp mmaps a single 533 MB GGUF instead.
            "qwen35-litert",
            // LiteRT X-ASR + Silero VAD + pyannote + CAM++, replaced 2026-09 by the streaming
            // nemo-x-asr-diarizer (same X-ASR model family, now on ggml, plus Nemotron-3 diarization).
            "xasr-litert",
            // MiniCPM5 CURSOR summarizer + Granite verifier, replaced 2026-09 by the Gemma-4-E2B
            // meeting agent (core/reader).
            "minicpm5-cursor-gguf", "granite-verifier-gguf",
        )

        /** Earlier meeting-agent versions (v3 root GGUF, v5), replaced by v11; reclaimed after v11 verifies. */
        private val RETIRED_LLM_DIRS = listOf("gemma4-meeting-agent-gguf", "gemma4-meeting-agent", "gemma4-meeting-agent-v5-gguf", "gemma4-meeting-agent-v11-gguf")

        /** Retired by the nemo switch; reclaimed only after the new models verify. */
        private val LITERT_RETIRED = setOf(
            "xasr-litert", "silero-vad.tflite", "pyannote-segmentation.tflite",
            "campplus_cn_common_500f.tflite",
        )

        /** Single files from removed engines, reclaimed at construction — the whole
         *  ggml/GGUF-era stack plus retired ONNX models (old installs carry up to
         *  ~1.5 GB of these; seen live on the Boox). The silero .onnx served sherpa
         *  only; the .tflite VAD is NOT listed (X-ASR/SenseVoice use it). */
        private val DROPPED_FILES = listOf(
            "silero_vad.onnx",
            // Retired summarizer bundles. Gemma 4 E2B/E4B were removed outright (E2B could not
            // load at all on a 3.7 GB device, at any nCtx — WEIGHTS, not KV, set that floor), and
            // the Qwen3-0.6B fine-tune went with them when Qwen3.5-0.8B became the sole
            // summarizer. Together up to ~6.9 GB on an install that tried all three.
            "gemma-4-e2b-it.litertlm", "gemma-4-e4b-it.litertlm",
            "voxsum-qwen3-0.6b_q8_ekv32768.litertlm",
            "qwen3.5-0.8b.gguf", "qwen3-0.6b.gguf", "gemma-3-1b.gguf",
            // MOSS-TD dropped from this ANDROID app 2026-08 (kept on desktop, where it is
            // fast and the most accurate backend — this is a phone-specific call): RTF ~4.4x on
            // the OPPO reference device made a 60-min meeting a ~4.4-hour transcription, and its
            // accuracy edge (7.74 vs X-ASR's 12.25 CER) didn't justify that on this hardware.
            // Root cause is memory-bandwidth-bound decode on a 2-big-core mobile SoC — already
            // running every available core, so no thread/scheduling fix was possible.
            // Diarization survives via the separate pyannote+CAM++ pipeline (still X-ASR's).
            "moss-td-zhtw-v7-q4_k_m.gguf", "moss-td-zhtw-v61-q4_k_m.gguf",
            "moss-transcribe-base-q4mix.gguf", "moss_td_decoder_q4b32_ekv2560.tflite",
            "moss_td_encoder_q8.tflite", "moss_td_embedder_q8.tflite",
            "moss_td_decoder_v2_q4b32_ekv2560.tflite", "moss_td_vocab.json", "moss_td_merges.txt",
            "campplus-cn-common.gguf", "campplus_zh_en.onnx", "campplus_zh_en_fp16.onnx",
            "pyannote_segmentation_3_0.onnx", "wespeaker_emb_fp16.tflite",
            "speaker_embedding.onnx",
            // Base Qwen3.5-0.8B, superseded by the VoxSum meeting fine-tune. Same dirName and the
            // same Q4_K_M recipe, but a different FILENAME, so provisioning writes the new GGUF
            // beside the old one instead of over it — 508 MB stranded on every existing install.
            "qwen35-gguf/Qwen3.5-0.8B-Q4_K_M.gguf",
            "silero-vad.tflite", "pyannote-segmentation.tflite", "campplus_cn_common_500f.tflite",
            "sherpa-onnx-zipformer-zh-en-2023-11-22",
            "sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03",
        )

        private data class Pinned(val url: String, val bytes: Long, val sha256: String)

        private const val NEMO_DIR = "nemo"
        private const val XASR_FILE = "x-asr-zh-en-q8_0.gguf"
        private const val DIAR_FILE = "nemotron-3-diarization-q8_0.gguf"
        private const val XASR_REV = "acb1a95eac809719a2c86d1048471f96fc6444ad"
        private const val DIAR_REV = "647d39feaa0e91dca5ce355a95403837b76dff56"
        /** Stamped into [REVISION_MARKER]: a re-pin of either file forces a fresh fetch. */
        private const val NEMO_REVISION = "$XASR_REV+$DIAR_REV"
        private val NEMO_FILES = linkedMapOf(
            XASR_FILE to Pinned(
                "https://huggingface.co/cstr/x-asr-zh-en-GGUF/resolve/$XASR_REV/$XASR_FILE",
                168_189_920L, "1ca120084a1517cf02d96e44cdd9a9544f0c887f6d0149c9f85d151be6833a61",
            ),
            DIAR_FILE to Pinned(
                "https://huggingface.co/audio-cpp/Nemotron-3-Diarization-GGUF/resolve/$DIAR_REV/$DIAR_FILE",
                106_675_136L, "9a737455bd10123bcf1e036d9a0b07b6e8c42e7d0dd1a5ee4141dc386db46d0b",
            ),
        )
    }
}
