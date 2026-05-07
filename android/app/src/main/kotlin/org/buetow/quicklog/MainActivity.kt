package org.buetow.quicklog

import android.content.Intent
import android.os.Bundle
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
                    else -> result.notImplemented()
                }
            }
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
