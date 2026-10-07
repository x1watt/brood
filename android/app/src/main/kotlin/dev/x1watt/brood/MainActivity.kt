// Brood's Android activity: keeps the screen on while playing and offers the
// "brood/files" channel the Dart side uses for its folders and the game files:
//   getDirs         -> {files, external}: where the app keeps its data and
//                      where the game files live (external/BROOD)
//   hasBundledFiles -> whether the APK carries the game files (assets/BROOD,
//                      see android/app/build.gradle.kts)
//   installBundledFiles -> copies them into external/BROOD; progress comes
//                      back as "progress" calls, the result as for
//                      pickGameFolder.
//   openUrl(url)    -> opens a link in the browser
//   shareText(text) -> the share sheet (messengers, mail...) with the text
//   installWebFiles -> copies the browser version the APK carries
//                      (assets/web) into files/web for the home server, once
//                      per installed version; its folder, or null.
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
                "hasBundledFiles" -> result.success(
                    assets.list("BROOD")?.contains("StarDat.mpq") == true
                )
                "installBundledFiles" -> Thread { installBundled(result) }.start()
                "installWebFiles" -> Thread { installWeb(result) }.start()
                "openUrl" -> {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.arguments as String)))
                    result.success(null)
                }
                "shareText" -> {
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, call.arguments as String)
                    }
                    startActivity(Intent.createChooser(send, null))
                    result.success(null)
                }
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

    // Every file under assets/[dir], by its path under assets/.
    private fun assetFiles(dir: String, out: MutableList<String>) {
        for (name in assets.list(dir) ?: emptyArray()) {
            val path = "$dir/$name"
            if (assets.list(path).isNullOrEmpty()) out.add(path) else assetFiles(path, out)
        }
    }

    private fun installWeb(result: MethodChannel.Result) {
        try {
            if (assets.list("web")?.contains("index.html") != true) {
                main.post { result.success(null) }
                return
            }
            val root = File(filesDir, "web")
            val stamp = File(root, ".installed")
            val version = packageManager.getPackageInfo(packageName, 0).lastUpdateTime.toString()
            if (!stamp.exists() || stamp.readText() != version) {
                root.deleteRecursively()
                val files = mutableListOf<String>()
                assetFiles("web", files)
                for (path in files) {
                    val dest = File(root, path.removePrefix("web/"))
                    dest.parentFile?.mkdirs()
                    assets.open(path).use { input -> dest.outputStream().use { input.copyTo(it, 1 shl 16) } }
                }
                stamp.writeText(version)
            }
            main.post { result.success(root.absolutePath) }
        } catch (e: Exception) {
            main.post { result.error("web", "Copying the browser version failed: ${e.message}", null) }
        }
    }

    private fun installBundled(result: MethodChannel.Result) {
        try {
            val all = mutableListOf<String>()
            assetFiles("BROOD", all)
            val files = all.map { it.removePrefix("BROOD/") }
            val root = File(getExternalFilesDir(null) ?: filesDir, "BROOD")
            files.forEachIndexed { i, rel ->
                val dest = File(root, rel)
                dest.parentFile?.mkdirs()
                // Through a temporary file, so a cut short copy is not taken
                // for the whole file next time.
                val tmp = File(dest.path + ".tmp")
                assets.open("BROOD/$rel").use { input -> tmp.outputStream().use { input.copyTo(it, 1 shl 16) } }
                tmp.renameTo(dest)
                main.post { channel.invokeMethod("progress", listOf(i + 1, files.size)) }
            }
            main.post { result.success(mapOf("dir" to root.absolutePath, "count" to files.size)) }
        } catch (e: Exception) {
            main.post { result.success(mapOf("error" to "Copying the game files failed: ${e.message}")) }
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
