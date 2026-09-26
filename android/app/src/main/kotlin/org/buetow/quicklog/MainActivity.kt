package org.buetow.quicklog

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private val channelName = "org.buetow.quicklog/share"
    private val cacheFilename = "quicklog-shared.txt"
    private val settingsChannelName = "org.buetow.quicklog/settings"
    private val requestExportSettings = 4201
    private val requestImportSettings = 4202

    // Settings export/import goes through the system file dialogs (Storage
    // Access Framework): no storage permission and no picker library needed.
    // One dialog at a time; the Dart side awaits the stored result.
    private var pendingSettingsResult: MethodChannel.Result? = null
    private var pendingExportContent: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readSharedTextFromCache" -> result.success(readCache())
                    "clearSharedTextCache" -> {
                        clearCache()
                        result.success(null)
                    }
                    "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                    "requestAllFilesAccess" -> {
                        requestAllFilesAccess()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, settingsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveSettingsFile" -> {
                        val content = call.argument<String>("content")
                        if (content == null) {
                            result.error("bad_args", "Nothing to export.", null)
                        } else {
                            val name = call.argument<String>("name") ?: "quicklog-settings.json"
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/json"
                                putExtra(Intent.EXTRA_TITLE, name)
                            }
                            startSettingsDialog(intent, requestExportSettings, result, content)
                        }
                    }
                    "openSettingsFile" -> {
                        // File managers label .json inconsistently, so accept
                        // anything and let the Dart side validate the content.
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        startSettingsDialog(intent, requestImportSettings, result, null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startSettingsDialog(
        intent: Intent,
        requestCode: Int,
        result: MethodChannel.Result,
        exportContent: String?,
    ) {
        if (pendingSettingsResult != null) {
            result.error("busy", "Another file dialog is already open.", null)
            return
        }
        pendingSettingsResult = result
        pendingExportContent = exportContent
        try {
            startActivityForResult(intent, requestCode)
        } catch (e: ActivityNotFoundException) {
            pendingSettingsResult = null
            pendingExportContent = null
            result.error("no_picker", "No file manager app is available.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != requestExportSettings && requestCode != requestImportSettings) return
        // No pending result means Android killed the process while the file
        // dialog was open: the Dart call that asked for it, and the export
        // text, died with it. Nothing is restored (the user just taps Export
        // again), but an export would otherwise leave the empty document the
        // dialog created behind, so remove it.
        val result = pendingSettingsResult ?: run {
            if (requestCode == requestExportSettings && resultCode == Activity.RESULT_OK) {
                data?.data?.let { deleteQuietly(it) }
            }
            return
        }
        val content = pendingExportContent
        pendingSettingsResult = null
        pendingExportContent = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            if (requestCode == requestExportSettings) {
                writeDocument(uri, content ?: "")
                result.success(displayName(uri))
            } else {
                val input = contentResolver.openInputStream(uri)
                    ?: throw IOException("Cannot open the selected file.")
                val text = input.use { it.readBytes().toString(Charsets.UTF_8) }
                result.success(text)
            }
        } catch (e: Exception) {
            result.error("io", e.message ?: e.toString(), null)
        }
    }

    private fun deleteQuietly(uri: Uri) {
        try {
            DocumentsContract.deleteDocument(contentResolver, uri)
        } catch (e: Exception) {
            // Provider without delete support, or already gone: an empty
            // file is harmless, so leave it.
        }
    }

    private fun writeDocument(uri: Uri, content: String) {
        val bytes = content.toByteArray(Charsets.UTF_8)
        // "wt" truncates; a few providers reject it, and a just-created
        // document is empty anyway, so plain "w" is a safe fallback.
        val out = try {
            contentResolver.openOutputStream(uri, "wt")
        } catch (e: Exception) {
            contentResolver.openOutputStream(uri, "w")
        } ?: throw IOException("Cannot write the selected file.")
        out.use { it.write(bytes) }
    }

    private fun displayName(uri: Uri): String {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val name = cursor.getString(0)
                        if (!name.isNullOrEmpty()) return name
                    }
                }
        } catch (e: Exception) {
            // Fall through to the URI: the name is only for the confirmation.
        }
        return uri.lastPathSegment ?: uri.toString()
    }

    // "All files access" (MANAGE_EXTERNAL_STORAGE) is required on Android 11+
    // to read/write directories outside the app sandbox, e.g. a synced notes
    // vault the user points Quicklog at. Below API 30 no such gate exists.
    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()

    // Android has no runtime-permission dialog for this; the user must flip
    // it in Settings, so we deep-link straight to this app's toggle there.
    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val intent = Intent(
            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
            Uri.parse("package:$packageName"),
        )
        startActivity(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureSendIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        captureSendIntent(intent)
    }

    private fun captureSendIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND && intent.type?.startsWith("text/") == true) {
            intent.getStringExtra(Intent.EXTRA_TEXT)?.let { text ->
                File(cacheDir, cacheFilename).writeText(text)
            }
        }
    }

    private fun readCache(): String? {
        val f = File(cacheDir, cacheFilename)
        return if (f.exists()) f.readText() else null
    }

    private fun clearCache() {
        val f = File(cacheDir, cacheFilename)
        if (f.exists()) f.delete()
    }
}
