package online.fxsecret.grabber

import android.content.Context
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File

/**
 * yt-dlp, Python and ffmpeg bundled by youtubedl-android. The first init
 * unpacks ~50 MB into the app's files, which takes seconds on a Galaxy S8,
 * so it runs lazily off the main thread.
 */
object Engine {
    @Volatile private var ready = false

    @Synchronized
    fun ensure(context: Context) {
        if (ready) return
        YoutubeDL.getInstance().init(context.applicationContext)
        FFmpeg.getInstance().init(context.applicationContext)
        sweepProbes(context)
        ready = true
    }

    /** The library only records a version after its first update; before that, ask yt-dlp. */
    fun version(context: Context): String? {
        ensure(context)
        YoutubeDL.getInstance().version(context.applicationContext)?.let { return it }
        return try {
            YoutubeDL.getInstance().execute(YoutubeDLRequest(emptyList<String>()).addOption("--version")).out.trim()
        } catch (e: Exception) {
            null
        }
    }

    /**
     * yt-dlp's cache (YouTube's solved player JS, mostly). The library turns
     * caching off unless a dir is given; without it every YouTube probe
     * re-solves the player, ~30 s on a Galaxy S8.
     */
    fun cacheDir(context: Context) = File(context.noBackupFilesDir, "ytdlp-cache").absolutePath

    /**
     * Metadata and formats for [url], as yt-dlp's JSON (the Dart side parses
     * it). [args] are extra options the Dart side picked for the platform.
     *
     * The JSON is also kept in a file ([infoFile]) so the download can start
     * from it with --load-info-json: on YouTube the extraction itself (solving
     * the player's JS challenge in QuickJS) is ~20 s on a Galaxy S8, and
     * shouldn't be paid twice.
     */
    fun probe(context: Context, url: String, args: List<String>, processId: String): String {
        ensure(context)
        val req = YoutubeDLRequest(url)
            .addOption("-J")
            // A watch?v=…&list=… link means that one video, not the playlist.
            .addOption("--no-playlist")
            .addOption("--no-warnings")
            .addOption("--cache-dir", cacheDir(context))
            .addCommands(args)
        val out = YoutubeDL.getInstance().execute(req, processId).out
        infoFile(context, processId).apply { parentFile?.mkdirs() }.writeText(out)
        return out
    }

    /** Where [probe] with this id left its JSON. */
    fun infoFile(context: Context, probeId: String) = File(context.noBackupFilesDir, "probes/$probeId.json")

    /** Probe results nobody downloaded; the URLs inside expire in hours anyway. */
    fun sweepProbes(context: Context) {
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        File(context.noBackupFilesDir, "probes").listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }
    }

    fun cancel(processId: String) = YoutubeDL.getInstance().destroyProcessById(processId)

    /** "done" or "up_to_date". Fetches the latest stable yt-dlp from its GitHub releases. */
    fun update(context: Context): String {
        ensure(context)
        return when (YoutubeDL.getInstance().updateYoutubeDL(context.applicationContext, YoutubeDL.UpdateChannel.STABLE)) {
            YoutubeDL.UpdateStatus.DONE -> "done"
            else -> "up_to_date"
        }
    }

    /** yt-dlp's own "ERROR: …" line from a failure, without the noise around it. */
    fun message(e: Throwable): String {
        val text = (e as? YoutubeDLException)?.message ?: e.message ?: e.toString()
        val err = text.lines().lastOrNull { it.startsWith("ERROR:") }
        return (err ?: text.lines().lastOrNull { it.isNotBlank() } ?: text).removePrefix("ERROR: ").trim()
    }
}
