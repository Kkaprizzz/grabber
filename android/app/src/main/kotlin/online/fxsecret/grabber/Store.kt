package online.fxsecret.grabber

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

/**
 * One thing to fetch inside a job. The Dart side decides what to fetch (it
 * knows the formats the user picked); native only runs it.
 *
 * - `ytdlp`: yt-dlp with [args] on [url]. [streams] is how many separate
 *   downloads yt-dlp will do (2 for video+audio merged), for overall progress.
 *   [info] is the probe id whose JSON (Engine.infoFile) the download starts
 *   from, which skips extracting the link again.
 * - `http`: a plain GET of [url] with [headers] (Instagram and TikTok photos,
 *   which yt-dlp doesn't download), saved as [name].
 *
 * [collection] says where the result goes: video → Movies, audio → Music,
 * image → Pictures.
 */
class Step(
    val kind: String,
    val url: String,
    val args: List<String>,
    val headers: Map<String, String>,
    val name: String?,
    val collection: String,
    val streams: Int,
    val info: String?,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("kind", kind)
        .put("url", url)
        .put("args", JSONArray(args))
        .put("headers", JSONObject(headers))
        .put("name", name)
        .put("collection", collection)
        .put("streams", streams)
        .put("info", info)

    companion object {
        fun fromJson(j: JSONObject) = Step(
            kind = j.getString("kind"),
            url = j.getString("url"),
            args = j.optJSONArray("args").strings(),
            headers = j.optJSONObject("headers").stringMap(),
            name = j.optString("name").ifEmpty { null },
            collection = j.getString("collection"),
            streams = j.optInt("streams", 1).coerceAtLeast(1),
            info = j.optString("info").ifEmpty { null },
        )
    }
}

/** A queued download: what the user asked for, split into [steps]. */
class Job(
    val id: String,
    val url: String,
    val title: String,
    val platform: String,
    val thumb: String?,
    /** width / height of the video, so covers keep their shape; 0 = unknown. */
    val aspect: Double,
    val steps: List<Step>,
    val createdAt: Long,
) {
    /** queued | running | network (waiting for one) | failed */
    @Volatile var state = "queued"
    /** 0..1, or -1 while nothing measurable happens (merging, converting). */
    @Volatile var progress = 0f
    /** Short Russian status line: "Видео", "Склеиваю", "Жду сеть"... */
    @Volatile var phase = ""
    @Volatile var error: String? = null

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("url", url)
        .put("title", title)
        .put("platform", platform)
        .put("thumb", thumb)
        .put("aspect", aspect)
        .put("steps", JSONArray(steps.map { it.toJson() }))
        .put("createdAt", createdAt)
        .put("state", state)
        .put("progress", progress.toDouble())
        .put("phase", phase)
        .put("error", error)

    companion object {
        fun fromJson(j: JSONObject) = Job(
            id = j.getString("id"),
            url = j.getString("url"),
            title = j.optString("title"),
            platform = j.optString("platform"),
            thumb = j.optString("thumb").ifEmpty { null },
            aspect = j.optDouble("aspect", 0.0).takeUnless { it.isNaN() } ?: 0.0,
            steps = j.getJSONArray("steps").objects().map(Step::fromJson),
            createdAt = j.optLong("createdAt"),
        ).apply {
            // A job that was running when the process died starts over.
            state = if (j.optString("state") == "failed") "failed" else "queued"
            error = j.optString("error").ifEmpty { null }
        }
    }
}

/** A saved file: a MediaStore content:// URI on Android 10+, a path on 8–9. */
class SavedFile(val uri: String, val name: String, val mime: String, val size: Long, val collection: String) {
    fun toJson(): JSONObject = JSONObject()
        .put("uri", uri).put("name", name).put("mime", mime).put("size", size).put("collection", collection)

    companion object {
        fun fromJson(j: JSONObject) = SavedFile(
            j.getString("uri"), j.optString("name"), j.optString("mime"), j.optLong("size"), j.optString("collection"),
        )
    }
}

/** A finished download in the history. [thumb] is a local file, so it shows offline. */
class Entry(
    val id: String,
    val url: String,
    val title: String,
    val platform: String,
    val thumb: String?,
    val aspect: Double,
    val files: List<SavedFile>,
    val at: Long,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("url", url).put("title", title).put("platform", platform)
        .put("thumb", thumb).put("aspect", aspect).put("files", JSONArray(files.map { it.toJson() })).put("at", at)

    companion object {
        fun fromJson(j: JSONObject) = Entry(
            id = j.getString("id"),
            url = j.optString("url"),
            title = j.optString("title"),
            platform = j.optString("platform"),
            thumb = j.optString("thumb").ifEmpty { null },
            aspect = j.optDouble("aspect", 0.0).takeUnless { it.isNaN() } ?: 0.0,
            files = j.optJSONArray("files").objects().map(SavedFile::fromJson),
            at = j.optLong("at"),
        )
    }
}

/**
 * Queue and history, shared by the UI and [DownloadService] (same process),
 * persisted to one JSON file so a killed process loses nothing.
 */
object Store {
    private var file: File? = null
    val queue = mutableListOf<Job>()
    /** Newest first. */
    val history = mutableListOf<Entry>()

    /** Called with "queue" or "history" after a change. */
    private val listeners = CopyOnWriteArrayList<(String) -> Unit>()

    @Synchronized
    fun load(context: Context) {
        if (file != null) return
        val f = File(context.filesDir, "state.json")
        file = f
        if (!f.exists()) return
        try {
            val j = JSONObject(f.readText())
            queue += j.optJSONArray("queue").objects().map(Job::fromJson)
            history += j.optJSONArray("history").objects().map(Entry::fromJson)
        } catch (e: Exception) {
            // A corrupt file shouldn't brick the app; keep it for a look.
            f.renameTo(File(context.filesDir, "state.broken.json"))
        }
    }

    /** Written through a temp file and a rename, so a crash mid-write can't corrupt it. */
    @Synchronized
    fun save() {
        val f = file ?: return
        val j = JSONObject()
            .put("queue", JSONArray(queue.map { it.toJson() }))
            .put("history", JSONArray(history.map { it.toJson() }))
        val tmp = File(f.parentFile, f.name + ".tmp")
        tmp.writeText(j.toString())
        tmp.renameTo(f)
    }

    @Synchronized
    fun queueJson(): String = JSONArray(queue.map { it.toJson() }).toString()

    @Synchronized
    fun historyJson(): String = JSONArray(history.map { it.toJson() }).toString()

    @Synchronized
    fun add(job: Job) {
        queue += job
        save()
        emit("queue")
    }

    @Synchronized
    fun nextQueued(): Job? = queue.firstOrNull { it.state == "queued" }

    @Synchronized
    fun hasQueued(): Boolean = queue.any { it.state == "queued" }

    @Synchronized
    fun job(id: String): Job? = queue.firstOrNull { it.id == id }

    @Synchronized
    fun removeJob(id: String) {
        if (queue.removeAll { it.id == id }) {
            save()
            emit("queue")
        }
    }

    /** Marks a failed job queued again. */
    @Synchronized
    fun retry(id: String): Boolean {
        val j = job(id) ?: return false
        if (j.state != "failed") return false
        j.state = "queued"
        j.error = null
        j.progress = 0f
        j.phase = ""
        save()
        emit("queue")
        return true
    }

    @Synchronized
    fun retryAllFailed() {
        var any = false
        for (j in queue) if (j.state == "failed") {
            j.state = "queued"; j.error = null; j.progress = 0f; j.phase = ""; any = true
        }
        if (any) { save(); emit("queue") }
    }

    /** The job finished: it leaves the queue and becomes a history entry. */
    @Synchronized
    fun complete(job: Job, entry: Entry) {
        queue.removeAll { it.id == job.id }
        history.add(0, entry)
        save()
        emit("queue")
        emit("history")
    }

    @Synchronized
    fun changed(persist: Boolean) {
        if (persist) save()
        emit("queue")
    }

    @Synchronized
    fun removeEntry(id: String): Entry? {
        val e = history.firstOrNull { it.id == id } ?: return null
        history.remove(e)
        save()
        emit("history")
        return e
    }

    @Synchronized
    fun clearHistory(): List<Entry> {
        val all = history.toList()
        history.clear()
        save()
        emit("history")
        return all
    }

    fun listen(l: (String) -> Unit) { listeners += l }
    fun unlisten(l: (String) -> Unit) { listeners -= l }
    private fun emit(what: String) = listeners.forEach { it(what) }
}

internal fun JSONArray?.strings(): List<String> =
    if (this == null) emptyList() else (0 until length()).map { getString(it) }

internal fun JSONArray?.objects(): List<JSONObject> =
    if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }

internal fun JSONObject?.stringMap(): Map<String, String> =
    if (this == null) emptyMap() else keys().asSequence().associateWith { getString(it) }
