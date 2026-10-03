// Brood's Android activity: keeps the screen on while playing and offers the
// "brood/files" channel the Dart side uses for its folders and to import the
// player's own game files (never bundled with the app):
//   getDirs         -> {files, external}: where the app keeps its data and
//                      where the game files live (external/BROOD)
//   pickGameFolder  -> lets the player pick their StarCraft folder (storage
//                      access framework) and copies StarDat.mpq, BrooDat.mpq,
//                      Patch_rt.mpq and the melee maps under maps/ into
//                      external/BROOD; progress comes back as "progress" calls.
package dev.x1watt.brood

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private var pending: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    companion object {
        private const val PICK_FOLDER = 4242
        private val ARCHIVES = listOf("StarDat.mpq", "BrooDat.mpq", "Patch_rt.mpq")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "brood/files")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getDirs" -> result.success(
                    mapOf(
                        "files" to filesDir.absolutePath,
                        "external" to (getExternalFilesDir(null) ?: filesDir).absolutePath,
                    )
                )
                "pickGameFolder" -> {
                    if (pending != null) {
                        result.error("busy", "A folder is already being chosen", null)
                    } else {
                        pending = result
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), PICK_FOLDER)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FOLDER) return
        val result = pending ?: return
        pending = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            result.success(mapOf("error" to "No folder was chosen."))
            return
        }
        Thread { importFrom(tree, result) }.start()
    }

    private data class Doc(val uri: Uri, val name: String, val path: String)

    // Every file under the tree, with its path relative to the chosen folder.
    private fun walk(tree: Uri, docId: String, prefix: String, out: MutableList<Doc>) {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
        contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0)
                val name = c.getString(1)
                val mime = c.getString(2)
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walk(tree, id, "$prefix$name/", out)
                } else {
                    out.add(Doc(DocumentsContract.buildDocumentUriUsingTree(tree, id), name, "$prefix$name"))
                }
            }
        }
    }

    private fun importFrom(tree: Uri, result: MethodChannel.Result) {
        try {
            val all = mutableListOf<Doc>()
            walk(tree, DocumentsContract.getTreeDocumentId(tree), "", all)
            // What to keep: the archives (by name, anywhere) and melee maps
            // under a maps/ folder, at the same relative place as on disk.
            val keep = mutableListOf<Pair<Doc, String>>()
            for (d in all) {
                val archive = ARCHIVES.firstOrNull { it.equals(d.name, ignoreCase = true) }
                if (archive != null) {
                    keep.add(d to archive)
                    continue
                }
                val lower = d.path.lowercase()
                if (!lower.endsWith(".scm") && !lower.endsWith(".scx")) continue
                if (lower.contains("/campaign/") || lower.contains("/scenario/") || lower.contains("/save/")) continue
                val parts = d.path.split("/")
                val at = parts.indexOfFirst { it.equals("maps", ignoreCase = true) }
                val rel = if (at >= 0) (listOf("maps") + parts.drop(at + 1)).joinToString("/") else "maps/${d.name}"
                keep.add(d to rel)
            }
            val missing = ARCHIVES.filter { a -> keep.none { it.second == a } }
            if (missing.isNotEmpty()) {
                main.post { result.success(mapOf("error" to "These files are missing from the folder: ${missing.joinToString(", ")}.")) }
                return
            }
            val root = File(getExternalFilesDir(null) ?: filesDir, "BROOD")
            keep.forEachIndexed { i, (doc, rel) ->
                val dest = File(root, rel)
                dest.parentFile?.mkdirs()
                contentResolver.openInputStream(doc.uri)?.use { input ->
                    dest.outputStream().use { input.copyTo(it, 1 shl 16) }
                }
                main.post { channel.invokeMethod("progress", listOf(i + 1, keep.size)) }
            }
            main.post { result.success(mapOf("dir" to root.absolutePath, "count" to keep.size)) }
        } catch (e: Exception) {
            main.post { result.success(mapOf("error" to "Copying the game files failed: ${e.message}")) }
        }
    }
}
