package org.buetow.quicklog

import android.app.Activity
import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
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
    // Set from a share Intent / ShareActivity launch; cleared by
    // consumeShareHandoff. Not persisted — a cold start after kill must not
    // look like a fresh share handoff.
    private var pendingShareHandoff = false
    private val settingsChannelName = "org.buetow.quicklog/settings"
    private val safChannelName = "org.buetow.quicklog/saf"
    private val requestExportSettings = 4201
    private val requestImportSettings = 4202
    private val requestLegacyStorage = 4203
    private val requestNoteTree = 4204
    private var pendingStorageResult: MethodChannel.Result? = null
    private var pendingTreeResult: MethodChannel.Result? = null
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
                    "clearSharedTextCacheIfEquals" -> {
                        val expected = call.argument<String>("expected")
                        if (expected == null) {
                            result.error("bad_args", "Expected shared text is required.", null)
                        } else {
                            try {
                                result.success(
                                    clearSharedTextCacheIfEquals(
                                        File(cacheDir, cacheFilename),
                                        expected,
                                    ),
                                )
                            } catch (e: IOException) {
                                result.error("io", e.message ?: e.toString(), null)
                            }
                        }
                    }
                    "storageApiLevel" -> result.success(Build.VERSION.SDK_INT)
                    "requestStorageAccess" -> {
                        requestStorageAccess(result)
                    }
                    "consumeShareHandoff" -> {
                        // One-shot process-local flag from the share Intent.
                        result.success(consumeShareHandoff())
                    }
                    "moveTaskToBack" -> {
                        // After auto-logging a share, return to the previous
                        // app instead of leaving Quicklog in the foreground.
                        result.success(moveTaskToBack(true))
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, safChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "pickTree") {
                    if (pendingTreeResult != null || pendingSettingsResult != null) {
                        result.error("busy", "Another file dialog is already open.", null)
                    } else {
                        pendingTreeResult = result
                        try {
                            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                            }, requestNoteTree)
                        } catch (e: ActivityNotFoundException) {
                            pendingTreeResult = null
                            result.error("no_picker", "No folder picker is available.", null)
                        }
                    }
                } else if (call.method == "releaseTree") {
                    val raw = call.argument<String>("uri")
                    if (raw == null) {
                        result.error("bad_args", "A folder URI is required.", null)
                    } else {
                        try {
                            val uri = Uri.parse(raw)
                            val grant = contentResolver.persistedUriPermissions.firstOrNull { it.uri == uri }
                            if (grant != null) {
                                val flags = (if (grant.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                                    (if (grant.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
                                contentResolver.releasePersistableUriPermission(uri, flags)
                            }
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("access_denied", e.message ?: e.toString(), null)
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun startSettingsDialog(
        intent: Intent,
        requestCode: Int,
        result: MethodChannel.Result,
        exportContent: String?,
    ) {
        if (pendingSettingsResult != null || pendingTreeResult != null) {
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
        if (requestCode == requestNoteTree) {
            val result = pendingTreeResult ?: return
            pendingTreeResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                result.success(null)
                return
            }
            try {
                val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (flags != (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
                    throw SecurityException("The selected folder needs read and write access.")
                }
                val alreadyGranted = contentResolver.persistedUriPermissions.any {
                    it.uri == uri && it.isReadPermission && it.isWritePermission
                }
                contentResolver.takePersistableUriPermission(uri, flags)
                try {
                    val treeDocument = DocumentsContract.buildDocumentUriUsingTree(
                        uri, DocumentsContract.getTreeDocumentId(uri))
                    result.success(mapOf("uri" to uri.toString(), "name" to displayName(treeDocument)))
                } catch (e: Exception) {
                    if (!alreadyGranted) contentResolver.releasePersistableUriPermission(uri, flags)
                    throw e
                }
            } catch (e: Exception) {
                result.error("access_denied", e.message ?: e.toString(), null)
            }
            return
        }
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

    // Android 7-10 uses a runtime permission for direct paths in shared storage.
    private fun hasLegacyStoragePermission(): Boolean =
        checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    private fun requestStorageAccess(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            if (hasLegacyStoragePermission()) {
                result.success(null)
            } else if (pendingStorageResult != null) {
                result.error("busy", "A storage permission request is already open.", null)
            } else {
                pendingStorageResult = result
                requestPermissions(
                    arrayOf(
                        Manifest.permission.READ_EXTERNAL_STORAGE,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE,
                    ),
                    requestLegacyStorage,
                )
            }
            return
        }
        // Android has no runtime dialog for MANAGE_EXTERNAL_STORAGE.
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName"),
                ),
            )
            result.success(null)
        } catch (e: ActivityNotFoundException) {
            result.error("no_settings", "Storage settings are unavailable.", null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == requestLegacyStorage) {
            pendingStorageResult?.success(null)
            pendingStorageResult = null
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        noteShareHandoff(intent)
        captureSendIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        noteShareHandoff(intent)
        captureSendIntent(intent)
    }

    private fun noteShareHandoff(intent: Intent?) {
        if (intent == null) return
        // Recents / task restore redelivers the start Intent; that must not
        // look like a fresh share after process death.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        if (intent.getBooleanExtra(ShareActivity.EXTRA_SHARE_HANDOFF, false)) {
            pendingShareHandoff = true
            intent.removeExtra(ShareActivity.EXTRA_SHARE_HANDOFF)
        }
    }

    private fun captureSendIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        if (intent.action == Intent.ACTION_SEND && intent.type?.startsWith("text/") == true) {
            intent.getStringExtra(Intent.EXTRA_TEXT)?.let { text ->
                File(cacheDir, cacheFilename).writeText(text)
                pendingShareHandoff = true
            }
        }
    }

    private fun consumeShareHandoff(): Boolean {
        val had = pendingShareHandoff
        pendingShareHandoff = false
        return had
    }

    private fun readCache(): String? {
        val f = File(cacheDir, cacheFilename)
        return if (f.exists()) f.readText() else null
    }
}
