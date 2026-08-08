package org.buetow.quicklog

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "org.buetow.quicklog/share"
    private val cacheFilename = "quicklog-shared.txt"

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
