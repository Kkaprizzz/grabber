package online.fxsecret.grabber

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException

/** Where finished files go: Movies/Grabber, Music/Grabber, Pictures/Grabber. */
object Media {
    private const val FOLDER = "Grabber"

    private val mimes = mapOf(
        "mp4" to "video/mp4", "webm" to "video/webm", "mkv" to "video/x-matroska", "mov" to "video/quicktime",
        "m4a" to "audio/mp4", "mp3" to "audio/mpeg", "opus" to "audio/ogg", "ogg" to "audio/ogg", "aac" to "audio/aac",
        "jpg" to "image/jpeg", "jpeg" to "image/jpeg", "png" to "image/png", "webp" to "image/webp", "heic" to "image/heic",
    )

    fun mimeOf(name: String): String = mimes[name.substringAfterLast('.', "").lowercase()] ?: "application/octet-stream"

    private fun directory(collection: String) = when (collection) {
        "audio" -> Environment.DIRECTORY_MUSIC
        "image" -> Environment.DIRECTORY_PICTURES
        else -> Environment.DIRECTORY_MOVIES
    }

    /** Copies [src] into the shared collection and returns where it landed. */
    fun save(context: Context, src: File, collection: String): SavedFile {
        val mime = mimeOf(src.name)
        val uri = if (Build.VERSION.SDK_INT >= 29) saveToMediaStore(context, src, collection, mime)
        else saveLegacy(context, src, collection)
        return SavedFile(uri, src.name, mime, src.length(), collection)
    }

    // Android 10+: no permission needed. The entry stays IS_PENDING while
    // written, so the Gallery never shows a half file; MediaStore renames on a clash.
    private fun saveToMediaStore(context: Context, src: File, collection: String, mime: String): String {
        val volume = MediaStore.VOLUME_EXTERNAL_PRIMARY
        val table = when (collection) {
            "audio" -> MediaStore.Audio.Media.getContentUri(volume)
            "image" -> MediaStore.Images.Media.getContentUri(volume)
            else -> MediaStore.Video.Media.getContentUri(volume)
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, src.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, directory(collection) + "/" + FOLDER)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(table, values) ?: throw IOException("MediaStore refused ${src.name}")
        try {
            val out = resolver.openOutputStream(uri) ?: throw IOException("cannot open MediaStore entry")
            out.use { o -> src.inputStream().use { it.copyTo(o, 1 shl 16) } }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri.toString()
    }

    // Android 8–9: a plain file, then the media scanner so the Gallery sees it
    // right away. Needs WRITE_EXTERNAL_STORAGE, asked for before enqueueing.
    @Suppress("DEPRECATION")
    private fun saveLegacy(context: Context, src: File, collection: String): String {
        val dir = File(Environment.getExternalStoragePublicDirectory(directory(collection)), FOLDER)
        if (!dir.isDirectory && !dir.mkdirs()) throw IOException("cannot create $dir")
        val base = src.name.substringBeforeLast('.')
        val ext = if (src.name.contains('.')) "." + src.name.substringAfterLast('.') else ""
        var dest = File(dir, src.name)
        var n = 1
        while (dest.exists()) dest = File(dir, "$base (${n++})$ext")
        src.copyTo(dest)
        MediaScannerConnection.scanFile(context, arrayOf(dest.absolutePath), null, null)
        return dest.absolutePath
    }

    /** A URI other apps can open: MediaStore's own, or ours via FileProvider for 8–9 paths. */
    fun shareable(context: Context, saved: String): Uri =
        if (saved.startsWith("content://")) Uri.parse(saved)
        else FileProvider.getUriForFile(context, context.packageName + ".files", File(saved))

    /**
     * False only when the file is surely gone: no MediaStore row, or the row
     * sits in the Gallery's trash. Anything we can't tell (a failed query,
     * a provider hiccup) counts as present — the history shouldn't call an
     * existing video deleted.
     */
    fun exists(context: Context, saved: String): Boolean {
        if (!saved.startsWith("content://")) return File(saved).exists()
        val uri = Uri.parse(saved)
        return try {
            val cursor = if (Build.VERSION.SDK_INT >= 30) {
                // Trashed and pending rows are hidden by default; ask for them
                // and decide ourselves, so a hidden row isn't taken for no row.
                val args = Bundle().apply {
                    putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_INCLUDE)
                    putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
                }
                context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.IS_TRASHED), args, null)
            } else {
                context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null)
            }
            cursor?.use { c ->
                when {
                    !c.moveToFirst() -> false
                    Build.VERSION.SDK_INT >= 30 -> c.getInt(0) == 0
                    else -> true
                }
            } ?: true
        } catch (e: Exception) {
            true
        }
    }

    /**
     * Deletes a saved file. Throws [SecurityException] on Android 10+ when the
     * app no longer owns the entry (e.g. after a reinstall); the caller then
     * asks the user through MediaStore.createDeleteRequest.
     */
    @Suppress("DEPRECATION")
    fun delete(context: Context, saved: String) {
        if (saved.startsWith("content://")) {
            context.contentResolver.delete(Uri.parse(saved), null, null)
        } else {
            val f = File(saved)
            if (f.exists() && !f.delete()) throw IOException("cannot delete $f")
            MediaScannerConnection.scanFile(context, arrayOf(f.absolutePath), null, null)
        }
    }
}
