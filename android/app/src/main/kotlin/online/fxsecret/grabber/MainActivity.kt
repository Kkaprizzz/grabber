package online.fxsecret.grabber

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val permissionRequest = 4711
    private val deleteRequest = 4712
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingDelete: (() -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()

    private var events: EventChannel.EventSink? = null
    /** A shared link that arrived before Dart started listening. */
    private var sharedText: String? = null

    private val storeListener: (String) -> Unit = { what ->
        main.post {
            val data = if (what == "queue") Store.queueJson() else Store.historyJson()
            events?.success(mapOf("type" to what, "data" to data))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Store.load(this)
        sharedText = sharedTextOf(intent)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "grabber/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    events = sink
                    Store.listen(storeListener)
                }

                override fun onCancel(arguments: Any?) {
                    Store.unlisten(storeListener)
                    events = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "grabber/native")
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    override fun onDestroy() {
        Store.unlisten(storeListener)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val text = sharedTextOf(intent) ?: return
        val sink = events
        if (sink != null) sink.success(mapOf("type" to "share", "data" to text)) else sharedText = text
    }

    private fun sharedTextOf(intent: Intent?): String? =
        if (intent?.action == Intent.ACTION_SEND) intent.getStringExtra(Intent.EXTRA_TEXT) else null

    /** Runs [work] off the main thread and answers on it. */
    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val v = work()
                main.post { result.success(v) }
            } catch (e: Throwable) {
                main.post { result.error("failed", Engine.message(e), null) }
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sharedText" -> {
                result.success(sharedText)
                sharedText = null
            }
            "engine" -> background(result) {
                Engine.ensure(this)
                Engine.version(this)
            }
            "probe" -> background(result) {
                Engine.probe(
                    this, call.argument<String>("url")!!,
                    call.argument<List<String>>("args") ?: emptyList(), call.argument<String>("id")!!,
                )
            }
            "cancelProbe" -> {
                Engine.cancel(call.argument<String>("id")!!)
                result.success(null)
            }
            "updateYtDlp" -> background(result) {
                val status = Engine.update(this)
                mapOf("status" to status, "version" to Engine.version(this))
            }
            "queue" -> result.success(Store.queueJson())
            "history" -> result.success(Store.historyJson())
            "enqueue" -> {
                Store.add(Job.fromJson(JSONObject(call.argument<String>("job")!!)))
                DownloadService.start(this)
                result.success(null)
            }
            "resume" -> {
                // Jobs left over from a process Android killed.
                if (Store.hasQueued()) DownloadService.start(this)
                result.success(null)
            }
            "cancel" -> {
                DownloadService.cancel(call.argument<String>("id")!!)
                result.success(null)
            }
            "retry" -> {
                val id = call.argument<String>("id")
                if (id == null) Store.retryAllFailed() else Store.retry(id)
                if (Store.hasQueued()) DownloadService.start(this)
                result.success(null)
            }
            "exists" -> background(result) {
                call.argument<List<String>>("uris")!!.map { Media.exists(this, it) }
            }
            "open" -> {
                val uri = call.argument<String>("uri")!!
                val mime = call.argument<String>("mime")!!
                try {
                    startActivity(
                        Intent(Intent.ACTION_VIEW)
                            .setDataAndType(Media.shareable(this, uri), mime)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            "share" -> {
                val files = call.argument<List<Map<String, String>>>("files")!!
                val uris = ArrayList(files.map { Media.shareable(this, it["uri"]!!) })
                val mimes = files.map { it["mime"]!! }.distinct()
                val type = if (mimes.size == 1) mimes[0] else mimes.map { it.substringBefore('/') }.distinct()
                    .let { if (it.size == 1) "${it[0]}/*" else "*/*" }
                val send = if (uris.size == 1) {
                    Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
                } else {
                    Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                }
                send.setType(type).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                startActivity(Intent.createChooser(send, null))
                result.success(null)
            }
            "deleteEntry" -> deleteEntry(call.argument<String>("id")!!, call.argument<Boolean>("files") ?: false, result)
            "clearHistory" -> {
                Store.clearHistory().forEach { e -> e.thumb?.let { File(it).delete() } }
                result.success(null)
            }
            "permissions" -> askPermissions(result)
            "version" -> {
                val info = packageManager.getPackageInfo(packageName, 0)
                @Suppress("DEPRECATION")
                val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
                result.success(mapOf("name" to info.versionName, "code" to code))
            }
            "install" -> install(call.argument<String>("path")!!, result)
            else -> result.notImplemented()
        }
    }

    /**
     * Drops a history entry and, if asked, its files. On Android 11+ files
     * the app no longer owns (after a reinstall) go through the system's
     * "allow deleting?" dialog; on 10 they're left for the Gallery.
     * Answers "done" or "kept" (some files could not be deleted).
     */
    private fun deleteEntry(id: String, files: Boolean, result: MethodChannel.Result) {
        val entry = synchronized(Store) { Store.history.firstOrNull { it.id == id } }
        if (entry == null) {
            result.success("done")
            return
        }
        io.execute {
            val foreign = mutableListOf<Uri>()
            var kept = false
            if (files) for (f in entry.files) {
                try {
                    Media.delete(this, f.uri)
                } catch (e: SecurityException) {
                    if (Build.VERSION.SDK_INT >= 30) foreign += Uri.parse(f.uri) else kept = true
                } catch (e: Exception) {
                    kept = true
                }
            }
            main.post {
                val finish = {
                    Store.removeEntry(id)
                    entry.thumb?.let { File(it).delete() }
                    result.success(if (kept) "kept" else "done")
                }
                if (foreign.isEmpty() || Build.VERSION.SDK_INT < 30) {
                    finish()
                } else {
                    pendingDelete = finish
                    val req = MediaStore.createDeleteRequest(contentResolver, foreign)
                    startIntentSenderForResult(req.intentSender, deleteRequest, null, 0, 0, 0)
                }
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == deleteRequest) {
            // Declined or not, the entry goes: the user asked to remove it.
            pendingDelete?.invoke()
            pendingDelete = null
        }
    }

    /**
     * Storage on Android 8–9 (writing to Movies/Music/Pictures) and
     * notifications on 13+. Answers whether saving will work; notifications
     * are optional, downloads run without them.
     */
    private fun askPermissions(result: MethodChannel.Result) {
        val wanted = mutableListOf<String>()
        if (Build.VERSION.SDK_INT < 29) wanted += Manifest.permission.WRITE_EXTERNAL_STORAGE
        if (Build.VERSION.SDK_INT >= 33) wanted += Manifest.permission.POST_NOTIFICATIONS
        val missing = wanted.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        pendingPermission = result
        requestPermissions(missing.toTypedArray(), permissionRequest)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequest) return
        val storageOk = Build.VERSION.SDK_INT >= 29 ||
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(storageOk)
        pendingPermission = null
    }

    private fun install(path: String, result: MethodChannel.Result) {
        // Android 8+ asks per app whether it may install APKs; send the user
        // to that switch once, then they retry.
        if (!packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            result.success("needs_permission")
            return
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.files", File(path))
        startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        result.success("started")
    }
}
