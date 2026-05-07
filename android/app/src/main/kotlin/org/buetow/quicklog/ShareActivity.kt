package org.buetow.quicklog

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import java.io.File

class ShareActivity : Activity() {
    companion object {
        private const val TAG = "QuicklogShare"
        private const val CACHE_FILENAME = "quicklog-shared.txt"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShare(intent)
        launchMain()
        finish()
    }

    private fun handleShare(intent: Intent?) {
        if (intent == null) return
        val type = intent.type
        if (intent.action == Intent.ACTION_SEND && type != null && type.startsWith("text/")) {
            val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (sharedText != null) {
                try {
                    val f = File(cacheDir, CACHE_FILENAME)
                    f.writeText(sharedText)
                    Log.i(TAG, "Wrote shared text to ${f.absolutePath}")
                } catch (e: Exception) {
                    Log.e(TAG, "Error writing shared text", e)
                }
            }
        }
    }

    private fun launchMain() {
        try {
            val launch = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            }
            startActivity(launch)
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to launch main activity", t)
        }
    }
}
