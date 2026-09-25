package online.fxsecret.grabber

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Runs the queue one job at a time while showing a progress notification, so
 * downloads keep going with the app closed. Stops itself when the queue is empty.
 */
class DownloadService : Service() {
    companion object {
        private const val CH_PROGRESS = "progress"
        private const val CH_DONE = "done"
        private const val NOTIF_PROGRESS = 1
        private const val ACTION_CANCEL = "cancel"

        /** Id of the job being worked on, and of one the user asked to cancel. */
        @Volatile private var current: String? = null
        @Volatile private var cancelled: String? = null

        fun start(context: Context) =
            ContextCompat.startForegroundService(context, Intent(context, DownloadService::class.java))

        /** Stops a running job, or drops a waiting or failed one from the queue. */
        fun cancel(id: String) {
            if (current == id) {
                cancelled = id
                Engine.cancel(processId(id))
            } else {
                Store.removeJob(id)
            }
        }

        private fun processId(id: String) = "job-$id"

        private val videoExt = setOf("mp4", "webm", "mkv", "mov")
        private val audioExt = setOf("m4a", "mp3", "opus", "ogg", "aac")
        private val imageExt = setOf("jpg", "jpeg", "png", "webp", "heic")

        const val USER_AGENT =
            "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
    }

    private class Cancelled : Exception()

    private val main = Handler(Looper.getMainLooper())
    private var worker: Thread? = null
    private lateinit var notifications: NotificationManager
    private var lastNotify = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Store.load(this)
        notifications = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            notifications.createNotificationChannel(
                NotificationChannel(CH_PROGRESS, "Загрузки", NotificationManager.IMPORTANCE_LOW)
                    .apply { setShowBadge(false) }
            )
            notifications.createNotificationChannel(
                NotificationChannel(CH_DONE, "Готовые загрузки", NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android requires startForeground() promptly after startForegroundService().
        ServiceCompat.startForeground(
            this, NOTIF_PROGRESS, progressNotification(null),
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
        )
        if (intent?.action == ACTION_CANCEL) intent.getStringExtra("id")?.let(::cancel)
        if (worker == null) startWorker()
        return START_NOT_STICKY
    }

    // Android 15+ caps dataSync services at 6 h a day; whatever is left waits
    // for the next time the app is opened.
    override fun onTimeout(startId: Int, fgsType: Int) {
        current?.let { cancel(it) }
        stopSelf()
    }

    private fun startWorker() {
        worker = Thread({
            while (true) {
                val job = claimNext() ?: break
                run(job)
            }
            // Lifecycle decisions happen on the main thread, where
            // onStartCommand runs, so an enqueue can't slip between them.
            main.post {
                worker = null
                if (Store.hasQueued()) startWorker()
                else {
                    ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }, "grabber-worker").apply { start() }
    }

    private fun claimNext(): Job? = synchronized(Store) {
        Store.nextQueued()?.also { it.state = "running"; it.progress = 0f; it.phase = "" }
    }

    private fun run(job: Job) {
        current = job.id
        val dir = File(cacheDir, "jobs/${job.id}")
        val wake = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "grabber:download")
        wake.acquire(3 * 60 * 60 * 1000L)
        try {
            if (!awaitNetwork(job)) throw Cancelled()
            dir.deleteRecursively()
            dir.mkdirs()
            Engine.ensure(this)
            val files = fetch(job, dir)
            update(job, "Сохраняю", -1f)
            val saved = files.map { (file, collection) -> Media.save(this, file, collection) }
            val entry = Entry(job.id, job.url, job.title, job.platform, saveThumb(job), saved, System.currentTimeMillis())
            Store.complete(job, entry)
            notifyDone(entry)
        } catch (e: Throwable) {
            when {
                cancelled == job.id || e is Cancelled || e is YoutubeDL.CanceledException -> Store.removeJob(job.id)
                // The connection dropped mid-download: wait for it and start over.
                !online() -> {
                    job.state = "queued"
                    Store.changed(persist = true)
                }
                else -> {
                    job.state = "failed"
                    job.error = Engine.message(e)
                    job.phase = ""
                    Store.changed(persist = true)
                    notifyFailed(job)
                }
            }
        } finally {
            dir.deleteRecursively()
            // The probe's JSON stays only while a retry could still use it.
            if (Store.job(job.id) == null) {
                job.steps.mapNotNull { it.info }.distinct().forEach { Engine.infoFile(this, it).delete() }
            }
            current = null
            cancelled = null
            if (wake.isHeld) wake.release()
        }
    }

    private fun online(): Boolean {
        val cm = getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    /** Blocks until there is a network; false if the job was cancelled meanwhile. */
    private fun awaitNetwork(job: Job): Boolean {
        if (online()) return true
        job.state = "network"
        update(job, "Жду сеть", -1f, force = true)
        while (!online()) {
            if (cancelled == job.id) return false
            Thread.sleep(3000)
        }
        job.state = "running"
        update(job, "", 0f, force = true)
        return true
    }

    /** Runs the job's steps; returns every produced file with its collection. */
    private fun fetch(job: Job, dir: File): List<Pair<File, String>> {
        val out = mutableListOf<Pair<File, String>>()
        val total = job.steps.sumOf { it.streams }.toFloat()
        var done = 0
        for ((i, step) in job.steps.withIndex()) {
            if (cancelled == job.id) throw Cancelled()
            val stepDir = File(dir, "$i").apply { mkdirs() }
            when (step.kind) {
                "ytdlp" -> ytdlp(job, step, stepDir) { p -> if (p < 0) -1f else (done + p * step.streams) / total }
                "http" -> http(job, step, stepDir) { p -> (done + p) / total }
                else -> throw IOException("unknown step ${step.kind}")
            }
            val wanted = when (step.collection) {
                "audio" -> audioExt
                "image" -> imageExt
                else -> videoExt
            }
            // Leftovers (.part, a thumbnail that wasn't embedded) stay behind.
            stepDir.listFiles()
                ?.filter { it.isFile && it.extension.lowercase() in wanted }
                ?.sortedBy { it.name }
                ?.forEach { out += it to step.collection }
            done += step.streams
        }
        if (out.isEmpty()) throw IOException("Ничего не скачалось")
        return out
    }

    private fun ytdlp(job: Job, step: Step, dir: File, overall: (Float) -> Float) {
        val info = step.info?.let { Engine.infoFile(this, it) }?.takeIf { it.exists() }
        if (info != null) {
            try {
                ytdlpRun(job, step, dir, overall, YoutubeDLRequest(emptyList<String>()).addOption("--load-info-json", info.absolutePath))
                return
            } catch (e: YoutubeDL.CanceledException) {
                throw e
            } catch (e: Exception) {
                // The stream URLs in the probe's JSON expire after some hours
                // in the queue; extract again from the link.
                if (cancelled == job.id) throw Cancelled()
                dir.listFiles()?.forEach { it.deleteRecursively() }
                info.delete()
            }
        }
        ytdlpRun(job, step, dir, overall, YoutubeDLRequest(step.url))
    }

    private fun ytdlpRun(job: Job, step: Step, dir: File, overall: (Float) -> Float, req: YoutubeDLRequest) {
        req.addOption("-o", File(dir, "%(title).80B [%(id)s].%(ext)s").absolutePath)
            .addOption("--no-mtime")
            .addOption("--no-part")
            .addOption("--cache-dir", Engine.cacheDir(this))
            .addCommands(step.args)
        // Two streams (video, then audio) each report 0→100%; count the
        // "Destination" lines to know which one is going.
        var stream = -1
        YoutubeDL.getInstance().execute(req, processId(job.id)) { pct, _, line ->
            when {
                line.startsWith("[download] Destination:") -> {
                    stream++
                    update(job, if (step.collection == "audio" || stream > 0 && step.streams > 1) "Звук" else "Скачиваю", overall(stream.coerceAtLeast(0).toFloat() / step.streams))
                }
                line.startsWith("[download]") && pct >= 0 && line.contains('%') -> {
                    val s = stream.coerceIn(0, step.streams - 1)
                    update(job, job.phase.ifEmpty { "Скачиваю" }, overall((s + pct / 100f) / step.streams))
                }
                line.startsWith("[Merger]") -> update(job, "Склеиваю", -1f)
                line.startsWith("[ExtractAudio]") || line.startsWith("[VideoConvertor]") -> update(job, "Конвертирую", -1f)
                line.startsWith("[EmbedThumbnail]") || line.startsWith("[Metadata]") -> update(job, "Обложка", -1f)
            }
        }
    }

    private fun http(job: Job, step: Step, dir: File, overall: (Float) -> Float) {
        val name = step.name ?: "image.jpg"
        update(job, "Скачиваю", overall(0f))
        download(step.url, step.headers, File(dir, name)) { got, len ->
            if (cancelled == job.id) throw Cancelled()
            if (len > 0) update(job, "Скачиваю", overall(got.toFloat() / len))
        }
    }

    private fun download(url: String, headers: Map<String, String>, dest: File, progress: (Long, Long) -> Unit) {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 20_000
            conn.readTimeout = 30_000
            conn.instanceFollowRedirects = true
            conn.setRequestProperty("User-Agent", USER_AGENT)
            headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
            if (conn.responseCode !in 200..299) throw IOException("HTTP ${conn.responseCode}")
            val len = conn.contentLengthLong
            var got = 0L
            conn.inputStream.use { input ->
                dest.outputStream().use { out ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        got += n
                        progress(got, len)
                    }
                }
            }
        } finally {
            conn.disconnect()
        }
    }

    /** A local copy of the cover for the history, so it shows offline. Best effort. */
    private fun saveThumb(job: Job): String? {
        val url = job.thumb ?: return null
        return try {
            val dir = File(filesDir, "thumbs").apply { mkdirs() }
            val f = File(dir, job.id)
            download(url, mapOf("Referer" to job.url), f) { _, _ -> }
            f.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    /** Publishes progress to the UI and the notification, throttled. */
    private fun update(job: Job, phase: String, progress: Float, force: Boolean = false) {
        job.phase = phase
        job.progress = progress
        val now = System.currentTimeMillis()
        if (!force && now - lastNotify < 400) return
        lastNotify = now
        Store.changed(persist = false)
        notifications.notify(NOTIF_PROGRESS, progressNotification(job))
    }

    private fun openApp(): PendingIntent = PendingIntent.getActivity(
        this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun progressNotification(job: Job?): Notification {
        val waiting = synchronized(Store) { Store.queue.count { it.state == "queued" } }
        val b = NotificationCompat.Builder(this, CH_PROGRESS)
            .setSmallIcon(R.drawable.ic_stat)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(openApp())
            .setContentTitle(job?.title ?: "Граббер")
        if (job == null) return b.setContentText("Готовлюсь…").setProgress(0, 0, true).build()
        val pct = (job.progress * 100).toInt()
        val status = buildString {
            append(job.phase.ifEmpty { "Скачиваю" })
            if (job.progress >= 0) append(" · $pct%")
            if (waiting > 0) append(" · ещё $waiting в очереди")
        }
        val cancel = PendingIntent.getService(
            this, job.id.hashCode(),
            Intent(this, DownloadService::class.java).setAction(ACTION_CANCEL).putExtra("id", job.id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return b.setContentText(status)
            .setProgress(100, pct.coerceIn(0, 100), job.progress < 0)
            .addAction(0, "Отменить", cancel)
            .build()
    }

    private fun notifyDone(entry: Entry) {
        val first = entry.files.firstOrNull() ?: return
        val view = Intent(Intent.ACTION_VIEW)
            .setDataAndType(Media.shareable(this, first.uri), first.mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        val tap = PendingIntent.getActivity(
            this, entry.id.hashCode(), view, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val text = if (entry.files.size > 1) "${entry.files.size} файлов · ${entry.title}" else entry.title
        notifications.notify(
            entry.id.hashCode(),
            NotificationCompat.Builder(this, CH_DONE)
                .setSmallIcon(R.drawable.ic_stat)
                .setContentTitle("Скачано")
                .setContentText(text)
                .setContentIntent(tap)
                .setAutoCancel(true)
                .build(),
        )
    }

    private fun notifyFailed(job: Job) {
        notifications.notify(
            job.id.hashCode(),
            NotificationCompat.Builder(this, CH_DONE)
                .setSmallIcon(R.drawable.ic_stat)
                .setContentTitle("Не скачалось")
                .setContentText(job.title)
                .setStyle(NotificationCompat.BigTextStyle().bigText("${job.title}\n${job.error ?: ""}"))
                .setContentIntent(openApp())
                .setAutoCancel(true)
                .build(),
        )
    }
}
