package studio.voxsum.core.library

import android.content.Context
import android.net.Uri
import android.util.Log
import org.json.JSONObject
import studio.voxsum.core.events.TranscriptEvent
import studio.voxsum.core.session.RecentSessions
import studio.voxsum.core.session.VoxsumSession
import studio.voxsum.data.SpeakerName
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The app-owned session library: every finished recording is auto-saved here the moment the mic
 * stops — clean stop, "Stop" cancellation, or crash recovery — so a capture can never be lost by
 * a stray tap or a process kill. Deletion is the only explicit act; saving never is.
 *
 * Layout: one directory per entry under `filesDir/library/<id>/`:
 *  - `recording.wav` — the raw finalized capture (present until the entry is embedded + pruned)
 *  - `session.m4a`   — the self-describing [VoxsumSession] file (audio + transcript + summary +
 *                      title), written by [attachResults] when the pipeline finishes
 *  - `meta.json`     — tiny sidecar (`{id,title,createdAt,durationSec,status}`) so a future
 *                      library list renders without parsing audio tags
 *
 * Entries surface through [RecentSessions] for now (a `file://` row on the home screen): a
 * RECORDED entry opens as plain audio (→ transcribe), a DONE one recovers the full session. A
 * dedicated library screen replaces that surfacing later; this store is already its source of truth.
 */
object SessionLibrary {
    private const val TAG = "SessionLibrary"
    private const val META = "meta.json"

    // meta.json is written from BOTH the UI (rename, on Dispatchers.IO) and the service pipeline
    // (attachResults/promoteRecording, on Default) in read-modify-write sequences — without
    // exclusion a rename during attachResults is lost, or a concurrent reader sees torn JSON
    // (readMeta then returns null and the caller treats the entry as corrupt). One process-wide
    // reentrant lock over every meta read/write and each read-modify-write pair.
    private val metaLock = Any()
    const val WAV_NAME = "recording.wav"
    const val SESSION_NAME = "session.m4a"

    enum class Status { RECORDED, DONE }

    data class Entry(
        val id: String,
        val dir: File,
        val title: String?,
        val createdAt: Long,
        val durationSec: Int,
        val status: Status,
    ) {
        val wavFile: File get() = File(dir, WAV_NAME)
        val sessionFile: File get() = File(dir, SESSION_NAME)

        /** Best playable audio: the embedded session when built, else the raw capture. */
        val audioFile: File get() = sessionFile.takeIf { it.exists() } ?: wavFile
    }

    fun root(context: Context) = File(context.filesDir, "library")

    /** Display title for an untitled entry — capture date + time + a short hash (so two same-minute
     *  captures stay distinguishable). Replaced by the LLM title or a user rename when one arrives. */
    fun defaultTitle(createdAt: Long): String {
        val ts = SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(Date(createdAt))
        return "$ts · %04x".format((createdAt xor (createdAt ushr 17)).toInt() and 0xffff)
    }

    /** The library entry directory owning [uri] (a `file://` inside an entry), or null. */
    fun entryDirOf(context: Context, uri: Uri): File? =
        uri.takeIf { it.scheme == "file" }?.path?.let { File(it).parentFile }
            ?.takeIf { it.parentFile == root(context) }

    /** Rename an entry (user title edit or the LLM title arriving): updates the meta sidecar and
     *  the entry's RecentSessions row label. The on-disk file names never change — export/share
     *  already derive their file name from the title. */
    fun rename(context: Context, dir: File, title: String) {
        val t = title.trim().ifBlank { return }
        // Read-modify-write under the lock: interleaving with attachResults' own re-read/write
        // would otherwise lose one of the two updates.
        val entry = synchronized(metaLock) {
            val e = readMeta(dir) ?: return
            if (e.title == t) return
            runCatching { writeMeta(e.copy(title = t)) }
                .onFailure { Log.w(TAG, "could not rename library entry", it) }
            e
        }
        RecentSessions.add(context, Uri.fromFile(entry.audioFile).toString(), t, System.currentTimeMillis())
    }

    /**
     * Move a finalized capture WAV into a new library entry (status RECORDED) and surface it in
     * RecentSessions. Called from the recording pipeline's `finally` — it must be cheap (a rename;
     * copy only across filesystems, which can't happen from filesDir/audio) and never throw.
     * Returns null on failure, leaving [wav] where it was (the caller keeps using its path).
     */
    fun promoteRecording(context: Context, wav: File, durationSec: Int): Entry? = runCatching {
        val createdAt = System.currentTimeMillis()
        val base = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date(createdAt))
        var dir = File(root(context), base)
        var n = 2
        while (dir.exists()) dir = File(root(context), "$base-${n++}")
        dir.mkdirs()
        val dest = File(dir, WAV_NAME)
        if (!wav.renameTo(dest)) {
            wav.copyTo(dest, overwrite = true)
            wav.delete()
        }
        val entry = Entry(dir.name, dir, title = null, createdAt = createdAt, durationSec = durationSec, status = Status.RECORDED)
        writeMeta(entry)
        // Discoverable immediately: a home-screen row that re-opens (→ transcribes) the raw capture.
        RecentSessions.add(context, Uri.fromFile(dest).toString(), defaultTitle(createdAt), createdAt)
        // Reclaim raw WAVs of entries whose session file is already built (their player sources are
        // no longer in use — starting a new recording reset the UI session).
        pruneWavs(context, excludeId = entry.id)
        entry
    }.onFailure { Log.w(TAG, "could not promote recording into library", it) }.getOrNull()

    /**
     * Embed the finished pipeline results into [entry] as a self-describing `session.m4a` (audio +
     * transcript + summary + title) and mark it DONE. The raw WAV is kept for now — it is still the
     * open session's player source — and reclaimed by [pruneWavs] on the next recording.
     */
    suspend fun attachResults(
        context: Context,
        entry: Entry,
        utterances: List<TranscriptEvent.Utterance>,
        speakerNames: Map<Int, SpeakerName>,
        summary: String?,
        actionItems: String?,
        title: String?,
        /** v2 structured notes in wire form, or null. See VoxsumSession.Loaded.notes. */
        notes: String?,
        asrModelId: String?,
        asrBackend: String?,
        llmModelId: String?,
        // Audio to embed. Defaults to the raw capture; the edits-persist path passes the open
        // session's audio instead when the WAV was already pruned (session.m4a-only entries).
        audio: Uri? = null,
    ): Entry? {
        val built = VoxsumSession.buildSession(
            context, entry.dir, audio ?: Uri.fromFile(entry.wavFile), utterances, speakerNames,
            summary, actionItems, title, notes, asrModelId, asrBackend, llmModelId,
            coverEnabled = true, fileName = SESSION_NAME, format = VoxsumSession.Format.M4A,
        ) ?: return null
        clearProgress(entry)   // the run is complete: nothing left to resume
        // A user-given name (set at capture time or via rename) outranks the LLM title — batch
        // processing must never rename "Talk 3 — Dr. Smith" to whatever the model invents. Re-read
        // the meta rather than trusting [entry]: a rename made WHILE this item processed would
        // otherwise be clobbered by the stale snapshot taken at drain start. The re-read + write
        // is one atomic section (metaLock) so a rename can't slip between them and be lost.
        val updated = synchronized(metaLock) {
            val u = entry.copy(
                title = byId(context, entry.id)?.title ?: entry.title ?: title?.trim()?.ifBlank { null },
                status = Status.DONE,
            )
            runCatching { writeMeta(u) }.onFailure { Log.w(TAG, "could not update library meta", it) }
            u
        }
        // Replace the raw-capture Recent row with the finished session (different uri AND title, so
        // RecentSessions' own dedup wouldn't collapse them).
        RecentSessions.remove(context, Uri.fromFile(entry.wavFile).toString())
        RecentSessions.add(
            context, Uri.fromFile(updated.sessionFile).toString(),
            updated.title ?: defaultTitle(updated.createdAt), System.currentTimeMillis(),
        )
        return updated
    }

    /** A single entry by id, or null if missing/corrupt. */
    fun byId(context: Context, id: String): Entry? = readMeta(File(root(context), id))

    // --- pending transcript sidecar (queue drain, pass 1 → pass 2) ---
    //
    // The batch drain transcribes+diarizes EVERY queued item first (ASR models only), then loads
    // the LLM once and summarizes them all — never both model families resident on small
    // devices, and only one LLM load per drain instead of one per item. Between the passes each
    // item's transcript lives in this sidecar, so a process kill resumes summarize-only instead of
    // redoing ASR. The fingerprint (ASR model + language + target + diarization) invalidates a
    // sidecar written under settings the user has since changed — pass 1 then re-transcribes.
    private const val PENDING_TRANSCRIPT = "pending_transcript.json"

    fun savePendingTranscript(entry: Entry, utterances: List<TranscriptEvent.Utterance>, fingerprint: String) {
        runCatching {
            val arr = org.json.JSONArray()
            utterances.forEach { arr.put(VoxsumSession.utteranceToJson(it)) }
            val o = JSONObject().put("fingerprint", fingerprint).put("utterances", arr)
            File(entry.dir, PENDING_TRANSCRIPT).writeText(o.toString())
        }.onFailure { Log.w(TAG, "could not persist pending transcript for ${entry.id}", it) }
    }

    /** The sidecar's utterances, or null when absent, corrupt, or written under different settings
     *  ([fingerprint] mismatch — the stale file is deleted so pass 1 re-transcribes). */
    fun loadPendingTranscript(entry: Entry, fingerprint: String): List<TranscriptEvent.Utterance>? {
        val f = File(entry.dir, PENDING_TRANSCRIPT)
        if (!f.exists()) return null
        return runCatching {
            val o = JSONObject(f.readText())
            if (o.optString("fingerprint") != fingerprint) {
                runCatching { f.delete() }
                return null
            }
            val arr = o.getJSONArray("utterances")
            List(arr.length()) { i -> VoxsumSession.utteranceFromJson(arr.getJSONObject(i), fallbackIndex = i) }
        }.onFailure {
            Log.w(TAG, "corrupt pending transcript in ${entry.id}", it)
            runCatching { f.delete() }
        }.getOrNull()
    }

    /** The sidecar's utterances whatever settings wrote it — for DISPLAY only (watching a queued
     *  item whose ASR pass already finished); null when absent or unreadable. */
    fun peekPendingTranscript(entry: Entry): List<TranscriptEvent.Utterance>? {
        val f = File(entry.dir, PENDING_TRANSCRIPT)
        if (!f.exists()) return null
        return runCatching {
            val arr = JSONObject(f.readText()).getJSONArray("utterances")
            List(arr.length()) { i -> VoxsumSession.utteranceFromJson(arr.getJSONObject(i), fallbackIndex = i) }
        }.getOrNull()
    }

    // --- interrupted-run checkpoint (Stop / kill mid-processing → "Resume") ---
    //
    // Separate from PENDING_TRANSCRIPT on purpose: that sidecar means "ASR finished" and lets the
    // queue skip straight to summarizing, so a partial transcript must never be written there. This
    // one holds the FROZEN prefix only (utterances that can no longer change) plus how far the audio
    // got, and the reading agent's notes written so far. Present = the entry is resumable.
    private const val PROGRESS = "pending_progress.json"

    /** [asrDoneSec] = end of the last frozen utterance (where ASR resumes); [asrComplete] = ASR had
     *  finished, so only the reading/summary is left. [notes] = the agent journal, rendered. */
    data class Progress(
        val fingerprint: String,
        val utterances: List<TranscriptEvent.Utterance>,
        val asrDoneSec: Double,
        val asrComplete: Boolean,
        val notes: String,
    )

    fun saveProgress(entry: Entry, p: Progress) {
        runCatching {
            val arr = org.json.JSONArray()
            p.utterances.forEach { arr.put(VoxsumSession.utteranceToJson(it)) }
            val o = JSONObject().put("fingerprint", p.fingerprint).put("utterances", arr)
                .put("asrDoneSec", p.asrDoneSec).put("asrComplete", p.asrComplete).put("notes", p.notes)
            val tmp = File(entry.dir, "$PROGRESS.tmp")
            tmp.writeText(o.toString())
            if (!tmp.renameTo(File(entry.dir, PROGRESS))) { File(entry.dir, PROGRESS).delete(); tmp.renameTo(File(entry.dir, PROGRESS)) }
        }.onFailure { Log.w(TAG, "could not persist progress for ${entry.id}", it) }
    }

    /** The checkpoint whatever settings wrote it (callers compare [Progress.fingerprint]); null when
     *  absent or unreadable. */
    fun loadProgress(entry: Entry): Progress? {
        val f = File(entry.dir, PROGRESS)
        if (!f.exists()) return null
        return runCatching {
            val o = JSONObject(f.readText())
            val arr = o.getJSONArray("utterances")
            Progress(
                o.optString("fingerprint"),
                List(arr.length()) { i -> VoxsumSession.utteranceFromJson(arr.getJSONObject(i), fallbackIndex = i) },
                o.optDouble("asrDoneSec", 0.0), o.optBoolean("asrComplete", false), o.optString("notes"),
            )
        }.onFailure { Log.w(TAG, "corrupt progress in ${entry.id}", it) }.getOrNull()
    }

    private const val NOTES = "pending_notes.json"

    /** The reader's checkpoint (journal + how many transcript lines it covers), atomic. */
    fun saveNotes(entry: Entry, llmModelId: String, cp: studio.voxsum.core.reader.ReaderCheckpoint) {
        runCatching {
            val arr = org.json.JSONArray()
            cp.journal.forEach { arr.put(JSONObject().put("id", it.id).put("window", it.window).put("ts", it.ts).put("tag", it.tag ?: JSONObject.NULL).put("text", it.text)) }
            val o = JSONObject().put("llm", llmModelId).put("window", cp.window).put("offered", cp.offered).put("journal", arr)
            val tmp = File(entry.dir, "$NOTES.tmp")
            tmp.writeText(o.toString())
            if (!tmp.renameTo(File(entry.dir, NOTES))) { File(entry.dir, NOTES).delete(); tmp.renameTo(File(entry.dir, NOTES)) }
        }.onFailure { Log.w(TAG, "could not persist notes for ${entry.id}", it) }
    }

    /** The reader checkpoint written with [llmModelId] (another model's notes are not reused). */
    fun loadNotes(entry: Entry, llmModelId: String): studio.voxsum.core.reader.ReaderCheckpoint? {
        val f = File(entry.dir, NOTES)
        if (!f.exists()) return null
        return runCatching {
            val o = JSONObject(f.readText())
            if (o.optString("llm") != llmModelId) return@runCatching null
            val a = o.getJSONArray("journal")
            val journal = List(a.length()) { i ->
                val n = a.getJSONObject(i)
                studio.voxsum.core.reader.Note(n.getInt("id"), n.getInt("window"), n.getString("ts"), if (n.isNull("tag")) null else n.getString("tag"), n.getString("text"))
            }
            studio.voxsum.core.reader.ReaderCheckpoint(journal, o.getInt("window"), o.getInt("offered"))
        }.onFailure { Log.w(TAG, "corrupt notes in ${entry.id}", it) }.getOrNull()
    }

    fun clearNotes(entry: Entry) {
        runCatching { File(entry.dir, NOTES).delete() }
    }

    fun hasProgress(entry: Entry): Boolean = File(entry.dir, PROGRESS).exists()

    fun clearProgress(entry: Entry) {
        runCatching { File(entry.dir, PROGRESS).delete() }
        clearNotes(entry)
    }

    fun clearPendingTranscript(entry: Entry) {
        runCatching { File(entry.dir, PENDING_TRANSCRIPT).delete() }
    }

    /** All library entries, newest first. Corrupt/foreign directories are skipped, never deleted. */
    fun list(context: Context): List<Entry> =
        root(context).listFiles()?.mapNotNull { dir -> readMeta(dir) }?.sortedByDescending { it.createdAt }
            ?: emptyList()

    /**
     * Explicit user deletion. [file] is any file inside an entry (e.g. the recovered WAV the
     * recovery dialog holds) — removes the whole entry; a non-library file is just deleted.
     */
    fun discard(context: Context, file: File) {
        val dir = file.parentFile
        runCatching {
            if (dir != null && dir.parentFile == root(context)) {
                RecentSessions.remove(context, Uri.fromFile(File(dir, WAV_NAME)).toString())
                RecentSessions.remove(context, Uri.fromFile(File(dir, SESSION_NAME)).toString())
                dir.deleteRecursively()
            } else file.delete()
        }.onFailure { Log.w(TAG, "could not discard $file", it) }
    }

    /** Delete the raw WAV of every DONE entry (its session.m4a holds the same audio), except
     *  [excludeId] — the entry whose WAV the current UI session may still be playing. */
    private fun pruneWavs(context: Context, excludeId: String) {
        root(context).listFiles()?.forEach { dir ->
            if (dir.name == excludeId) return@forEach
            val wav = File(dir, WAV_NAME)
            if (wav.exists() && File(dir, SESSION_NAME).exists()) runCatching { wav.delete() }
        }
    }

    private fun writeMeta(entry: Entry) = synchronized(metaLock) {
        val o = JSONObject()
            .put("id", entry.id)
            .put("createdAt", entry.createdAt)
            .put("durationSec", entry.durationSec)
            .put("status", entry.status.name)
        entry.title?.let { o.put("title", it) }
        File(entry.dir, META).writeText(o.toString())
    }

    private fun readMeta(dir: File): Entry? = synchronized(metaLock) {
        val f = File(dir, META)
        if (!f.exists()) return null
        return runCatching {
            val o = JSONObject(f.readText())
            Entry(
                id = o.optString("id", dir.name),
                dir = dir,
                title = if (o.has("title")) o.getString("title") else null,
                createdAt = o.getLong("createdAt"),
                durationSec = o.optInt("durationSec"),
                status = runCatching { Status.valueOf(o.getString("status")) }.getOrDefault(Status.RECORDED),
            )
        }.onFailure { Log.w(TAG, "corrupt library meta in ${dir.name}", it) }.getOrNull()
    }
}
