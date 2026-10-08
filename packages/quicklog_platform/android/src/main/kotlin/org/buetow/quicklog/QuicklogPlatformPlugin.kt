package org.buetow.quicklog

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Registered on every Flutter engine, including WorkManager's headless engine. */
class QuicklogPlatformPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    private var executor: ThreadPoolExecutor? = null
    private var coordination: MethodChannel? = null
    private var stateChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val preferences = binding.applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val state = AtomicS3State(object : S3StateStorage {
            override fun read(key: String): String? = preferences.getString(key, null)
            override fun write(values: Map<String, String?>) {
                val editor = preferences.edit()
                for ((key, value) in values) {
                    if (value == null) editor.remove(key) else editor.putString(key, value)
                }
                check(editor.commit()) { "Cannot persist S3 state." }
            }
        })
        stateChannel = MethodChannel(binding.binaryMessenger, "org.buetow.quicklog/s3-state").also {
            it.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "repairRead" -> result.success(state.readRepairs(call.requireString("legacy")))
                        "repairMutate" -> {
                            val (changed, document) = state.mutateRepair(
                                call.requireString("legacy"), call.requireString("folder"), call.requireString("id"),
                                call.requireString("operation"), call.argument<String>("expectedRevision"),
                                call.argument<Boolean>("checkRevision") ?: false,
                            )
                            result.success(mapOf("changed" to changed, "document" to document))
                        }
                        "clearFailure" -> result.success(state.clearFailure(call.argument<String>("expected")))
                        "receiptConfirm" -> {
                            state.confirmReceipt(call.requireString("scope"), call.requireString("id"), call.requireString("digest"))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("state", "S3 state could not be updated.", null)
                }
            }
        }
        coordination = MethodChannel(binding.binaryMessenger, "org.buetow.quicklog/s3-lease").also {
            it.setMethodCallHandler { call, result ->
                val token = call.argument<String>("token")
                if (token == null) {
                    result.error("bad_args", "An operation token is required.", null)
                } else when (call.method) {
                    "acquire" -> result.success(S3OperationLease.acquire(this, token))
                    "release" -> {
                        S3OperationLease.release(this, token)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        val saf = SafTreeDocuments(binding.applicationContext.contentResolver)
        val handler = Handler(Looper.getMainLooper())
        val worker = ThreadPoolExecutor(
            1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(32),
            ThreadFactory { task -> Thread(task, "quicklog-saf") },
        )
        executor = worker
        channel = MethodChannel(binding.binaryMessenger, "org.buetow.quicklog/saf-notes").also {
            it.setMethodCallHandler { call, result ->
                if (call.method !in setOf("list", "read", "firstLine", "create", "update", "delete", "writeImage")) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    worker.execute {
                        try {
                            val treeUri = call.requireString("treeUri")
                            val value = when (call.method) {
                                "list" -> saf.list(treeUri)
                                "read" -> saf.read(treeUri, call.requireString("id"))
                                "firstLine" -> saf.firstLine(treeUri, call.requireString("id"))
                                "create" -> {
                                    saf.create(treeUri, call.requireString("id"), call.requireString("text"))
                                    null
                                }
                                "writeImage" -> {
                                    val bytes = call.argument<ByteArray>("bytes")
                                        ?: throw IllegalArgumentException("Missing bytes.")
                                    saf.writeImage(
                                        treeUri,
                                        call.requireString("id"),
                                        call.requireString("mimeType"),
                                        bytes,
                                    )
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
                            handler.post { result.success(value) }
                        } catch (e: IllegalArgumentException) {
                            handler.post { result.error("bad_args", e.message, null) }
                        } catch (e: SecurityException) {
                            handler.post { result.error("access_denied", e.message, null) }
                        } catch (e: NoteMissingException) {
                            handler.post { result.error("not_found", e.message, null) }
                        } catch (e: Exception) {
                            handler.post { result.error("io", e.message ?: e.toString(), null) }
                        }
                    }
                } catch (_: RejectedExecutionException) {
                    result.error("busy", "The document provider has too many pending requests.", null)
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stateChannel?.setMethodCallHandler(null)
        stateChannel = null
        S3OperationLease.detach(this)
        coordination?.setMethodCallHandler(null)
        coordination = null
        channel?.setMethodCallHandler(null)
        channel = null
        // Finish writes already handed to the provider, just as MainActivity did.
        executor?.shutdown()
        executor = null
    }
}

private fun MethodCall.requireString(key: String): String =
    argument<String>(key) ?: throw IllegalArgumentException("$key is required.")
