package dev.luisnquin.upgrade

import android.app.Activity
import android.content.ClipData
import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class FileBridge(private val activity: Activity) {
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var saving: File? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(result)
            "share" -> result.success(share(call.argument<List<String>>("paths") ?: emptyList()))
            "save" -> save(call.argument<String>("path") ?: "", call.argument<String>("name") ?: "file", result)
            "outgoing" -> result.success(swept(outgoingDir(activity)))
            "scratch" -> result.success(swept(File(activity.cacheDir, "scratch")))
            "takeShared" -> result.success(SharedInbox.take())
            "transfers" -> {
                val title = call.argument<String>("title") ?: ""
                if (call.argument<Boolean>("done") == true) {
                    TransferService.done(activity.applicationContext, title)
                } else {
                    TransferService.moving(
                        activity.applicationContext,
                        title,
                        call.argument<String>("text") ?: "",
                        call.argument<Int>("percent") ?: -1,
                    )
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun begin(result: MethodChannel.Result): Boolean {
        if (pending != null) {
            result.error("busy", "a document picker is already up", null)
            return false
        }
        pending = result
        return true
    }

    private fun pick(result: MethodChannel.Result) {
        if (!begin(result)) return
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        activity.startActivityForResult(intent, PICK_FILES)
    }

    private fun save(path: String, name: String, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.isFile) {
            result.error("save", "no file at $path", null)
            return
        }
        if (!begin(result)) return
        saving = file
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeOf(name)
            putExtra(Intent.EXTRA_TITLE, name)
        }
        activity.startActivityForResult(intent, SAVE_FILE)
    }

    private fun share(paths: List<String>): Boolean {
        val root = outgoingDir(activity).canonicalFile
        val uris = paths.map(::File).filter { it.canonicalPath.startsWith(root.path + File.separator) }
            .map { OutgoingProvider.uriFor(activity, root, it) }
        if (uris.isEmpty()) return false
        val intent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).apply {
                type = mimeOf(uris[0].lastPathSegment ?: "")
                putExtra(Intent.EXTRA_STREAM, uris[0])
            }
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                type = "*/*"
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            }
        }
        intent.clipData = ClipData.newUri(activity.contentResolver, "files", uris[0]).apply {
            uris.drop(1).forEach { addItem(ClipData.Item(it)) }
        }
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(Intent.createChooser(intent, null))
        return true
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_FILES && requestCode != SAVE_FILE) return false
        val result = pending ?: return true
        val source = saving
        pending = null
        saving = null
        val ok = resultCode == Activity.RESULT_OK && data != null
        if (requestCode == PICK_FILES) {
            val uris = if (ok) urisOf(data!!) else emptyList()
            Thread {
                val picked = uris.mapNotNull { copyIn(activity, it, "picked") }
                main.post { result.success(picked) }
            }.start()
            return true
        }
        val target = if (ok) data!!.data else null
        if (target == null || source == null) {
            result.success(false)
            return true
        }
        Thread {
            val error = try {
                activity.contentResolver.openOutputStream(target, "wt")?.use { out ->
                    source.inputStream().use { it.copyTo(out) }
                } ?: throw IllegalStateException("no stream for $target")
                null
            } catch (e: Exception) {
                e.message ?: "$e"
            }
            main.post {
                if (error == null) result.success(true) else result.error("save", error, null)
            }
        }.start()
        return true
    }

    companion object {
        private const val PICK_FILES = 3911
        private const val SAVE_FILE = 3912

        fun outgoingDir(context: Context) = File(context.cacheDir, "outgoing")

        private fun swept(dir: File): String = dir.apply { mkdirs() }.also(::sweep).absolutePath

        fun mimeOf(name: String): String =
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
                ?: "application/octet-stream"

        fun urisOf(intent: Intent): List<Uri> {
            val clip = intent.clipData
            if (clip != null && clip.itemCount > 0) {
                return (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
            }
            return listOfNotNull(intent.data)
        }

        private fun nameOf(context: Context, uri: Uri): String {
            val queried = try {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { if (it.moveToFirst()) it.getString(0) else null }
            } catch (_: Exception) {
                // ignored: a provider without a display name falls back to the uri
                null
            }
            val base = (queried ?: uri.lastPathSegment ?: "file").substringAfterLast('/')
            val safe = base.replace(Regex("[\\u0000-\\u001f/\\\\]"), "_").trimStart('.')
            return safe.ifEmpty { "file" }
        }

        private fun sweep(dir: File) {
            val stale = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
            dir.listFiles()?.filter { it.lastModified() < stale }?.forEach { it.deleteRecursively() }
        }

        // A file: uri reads with this app's own permissions, so another app could hand
        // over the app's private files.
        fun copyIn(context: Context, uri: Uri, into: String): Map<String, Any>? {
            if (uri.scheme != ContentResolver.SCHEME_CONTENT) return null
            return try {
                val root = File(context.cacheDir, into).apply { mkdirs() }
                sweep(root)
                val name = nameOf(context, uri)
                val file = File(File(root, UUID.randomUUID().toString()).apply { mkdirs() }, name)
                context.contentResolver.openInputStream(uri)?.use { input ->
                    file.outputStream().use { input.copyTo(it) }
                } ?: throw IllegalStateException("no stream for $uri")
                mapOf(
                    "kind" to "file",
                    "path" to file.absolutePath,
                    "name" to name,
                    "size" to file.length(),
                    "mime" to (context.contentResolver.getType(uri) ?: mimeOf(name)),
                )
            } catch (_: Exception) {
                // ignored: an unreadable uri is not copied, and the rest still are
                null
            }
        }
    }
}

object SharedInbox {
    private val pending = mutableListOf<Map<String, Any>>()
    var listener: (() -> Unit)? = null

    @Synchronized
    fun add(items: List<Map<String, Any>>) {
        pending.addAll(items)
    }

    @Synchronized
    fun take(): List<Map<String, Any>> = pending.toList().also { pending.clear() }

    @Synchronized
    fun waiting() = pending.isNotEmpty()
}

class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val intent = intent
        Thread {
            val items = mutableListOf<Map<String, Any>>()
            val streams = when (intent.action) {
                Intent.ACTION_SEND -> listOfNotNull(streamOf(intent))
                Intent.ACTION_SEND_MULTIPLE -> streamsOf(intent)
                else -> emptyList()
            }
            for (stream in streams) {
                items.add(FileBridge.copyIn(this, stream, "shared") ?: mapOf("kind" to "unreadable"))
            }
            if (streams.isEmpty()) {
                intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.let {
                    items.add(mapOf("kind" to "text", "text" to it))
                }
            }
            SharedInbox.add(items)
            runOnUiThread {
                startActivity(
                    Intent(this, MainActivity::class.java)
                        .setAction(SHARED_ACTION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                )
                SharedInbox.listener?.invoke()
                finish()
            }
        }.start()
    }

    @Suppress("DEPRECATION")
    private fun streamOf(intent: Intent): Uri? =
        intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri

    @Suppress("DEPRECATION")
    private fun streamsOf(intent: Intent): List<Uri> =
        intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()

    companion object {
        const val SHARED_ACTION = "dev.luisnquin.upgrade.SHARED"
    }
}

class OutgoingProvider : ContentProvider() {
    override fun onCreate() = true

    private fun fileOf(uri: Uri): File? {
        val context = context ?: return null
        val root = FileBridge.outgoingDir(context).canonicalFile
        val file = File(root, uri.path?.trimStart('/') ?: return null).canonicalFile
        return if (file.path.startsWith(root.path + File.separator) && file.isFile) file else null
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val file = fileOf(uri) ?: throw java.io.FileNotFoundException("$uri")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        val file = fileOf(uri) ?: return null
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val row = columns.map {
            when (it) {
                OpenableColumns.DISPLAY_NAME -> file.name
                OpenableColumns.SIZE -> file.length()
                else -> null
            }
        }
        return MatrixCursor(columns).apply { addRow(row) }
    }

    override fun getType(uri: Uri) = FileBridge.mimeOf(uri.lastPathSegment ?: "")

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ) = 0

    companion object {
        fun uriFor(context: Context, root: File, file: File): Uri = Uri.Builder()
            .scheme("content")
            .authority("${context.packageName}.outgoing")
            .path(file.canonicalPath.removePrefix(root.path))
            .build()
    }
}
