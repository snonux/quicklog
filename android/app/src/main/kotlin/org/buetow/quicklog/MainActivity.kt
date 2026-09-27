package org.buetow.quicklog

import android.app.Activity
import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

private fun MethodCall.requireString(key: String): String =
    argument<String>(key) ?: throw IllegalArgumentException("$key is required.")

class MainActivity : FlutterActivity() {
    private val channelName = "org.buetow.quicklog/share"
    private val cacheFilename = "quicklog-shared.txt"
    private val settingsChannelName = "org.buetow.quicklog/settings"
    private val safChannelName = "org.buetow.quicklog/saf"
    private val requestExportSettings = 4201
    private val requestImportSettings = 4202
    private val requestLegacyStorage = 4203
    private var pendingStorageResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    // A single worker preserves call order (create followed by read, for
    // example). Bound the queue so a stalled cloud provider cannot retain an
    // unlimited number of requests or block Flutter's UI thread.
    private val safExecutor = ThreadPoolExecutor(
        1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(32),
        ThreadFactory { task -> Thread(task, "quicklog-saf") },
    )

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
        val saf = SafTreeDocuments(contentResolver)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, safChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method !in setOf("list", "read", "create", "update", "delete")) {
                    result.notImplemented()
                } else {
                    try {
                        safExecutor.execute {
                            try {
                                val treeUri = call.requireString("treeUri")
                                val value = when (call.method) {
                                    "list" -> saf.list(treeUri)
                                    "read" -> saf.read(treeUri, call.requireString("id"))
                                    "create" -> {
                                        saf.create(treeUri, call.requireString("id"), call.requireString("text"))
                                        null
                                    }
                                    "update" -> {
                                        saf.update(treeUri, call.requireString("id"), call.requireString("text"))
                                        null
                                    }
                                    else -> {
                                        saf.delete(treeUri, call.requireString("id"))
                                        null
                                    }
                                }
                                mainHandler.post { result.success(value) }
                            } catch (e: IllegalArgumentException) {
                                mainHandler.post { result.error("bad_args", e.message, null) }
                            } catch (e: SecurityException) {
                                mainHandler.post { result.error("access_denied", e.message, null) }
                            } catch (e: NoteMissingException) {
                                mainHandler.post { result.error("not_found", e.message, null) }
                            } catch (e: Exception) {
                                mainHandler.post { result.error("io", e.message ?: e.toString(), null) }
                            }
                        }
                    } catch (_: RejectedExecutionException) {
                        result.error("busy", "The document provider has too many pending requests.", null)
                    }
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
        captureSendIntent(intent)
    }

    override fun onDestroy() {
        // Let in-flight writes finish; interrupting a provider while writing
        // could leave a partially updated note. No new requests are accepted.
        safExecutor.shutdown()
        super.onDestroy()
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
}
