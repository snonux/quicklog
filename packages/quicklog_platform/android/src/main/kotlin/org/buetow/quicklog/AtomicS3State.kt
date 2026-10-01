package org.buetow.quicklog

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal interface S3StateStorage {
    fun read(key: String): String?
    fun write(values: Map<String, String?>)
}

/** Short, network-free transactions shared by every Flutter engine. */
internal class AtomicS3State(private val storage: S3StateStorage) {
    companion object {
        private val lock = Any()
        const val repairsKey = "flutter.DualWritePending"
        const val receiptsKey = "flutter.S3UploadReceipts"
    }

    private fun repairs(legacy: String): JSONObject {
        val raw = storage.read(repairsKey)
        val root = JSONObject(raw ?: legacy)
        val grouped = root.opt("folders")
        val folders = when {
            grouped is JSONObject -> grouped
            grouped != null -> throw IllegalArgumentException("Invalid repair folders.")
            root.has("directory") -> {
                require(root.has("uploads") || root.has("deletes")) { "Invalid legacy repair document." }
                val queue = JSONObject()
                for (kind in listOf("uploads", "deletes")) {
                    val values = root.opt(kind)
                    require(values == null || values is JSONArray) { "Invalid legacy repair list." }
                    queue.put(kind, values ?: JSONArray())
                }
                JSONObject().put(root.getString("directory"), queue)
            }
            else -> throw IllegalArgumentException("Invalid repair document.")
        }
        for (folder in folders.keys()) {
            val queue = folders.getJSONObject(folder)
            for (kind in listOf("uploads", "deletes")) {
                val values = queue.opt(kind)
                if (values != null && values !is JSONArray) throw IllegalArgumentException("Invalid repair list.")
                val ids = values as? JSONArray ?: JSONArray()
                for (i in 0 until ids.length()) {
                    if (ids.get(i) !is String) throw IllegalArgumentException("Invalid repair id.")
                }
            }
            val revisions = queue.opt("revisions")
            if (revisions != null && revisions !is JSONObject) throw IllegalArgumentException("Invalid repair revisions.")
            if (revisions is JSONObject) for (id in revisions.keys()) {
                if (revisions.get(id) !is String) throw IllegalArgumentException("Invalid repair revision.")
            }
        }
        return JSONObject().put("folders", folders)
    }

    fun readRepairs(legacy: String): String = synchronized(lock) { repairs(legacy).toString() }

    fun mutateRepair(legacy: String, folder: String, id: String, operation: String,
                     expectedRevision: String?, checkRevision: Boolean): Pair<Boolean, String> = synchronized(lock) {
        require(isQuicklogNoteName(id)) { "Invalid note filename." }
        val root = repairs(legacy)
        val folders = root.getJSONObject("folders")
        val queue = folders.optJSONObject(folder) ?: JSONObject()
        val revisions = queue.optJSONObject("revisions") ?: JSONObject()
        val actual = if (revisions.has(id)) revisions.getString(id) else null
        if (operation == "clear" && checkRevision && actual != expectedRevision) {
            return@synchronized false to root.toString()
        }
        fun without(values: JSONArray?, excluded: String): JSONArray {
            val result = JSONArray()
            if (values != null) for (i in 0 until values.length()) {
                val value = values.getString(i)
                if (value != excluded) result.put(value)
            }
            return result
        }
        val uploads = without(queue.optJSONArray("uploads"), id)
        val deletes = without(queue.optJSONArray("deletes"), id)
        when (operation) {
            "upload" -> { uploads.put(id); revisions.put(id, UUID.randomUUID().toString()) }
            "delete" -> { deletes.put(id); revisions.put(id, UUID.randomUUID().toString()) }
            "clear" -> revisions.remove(id)
            else -> throw IllegalArgumentException("Invalid repair operation.")
        }
        queue.put("uploads", uploads).put("deletes", deletes).put("revisions", revisions)
        if (uploads.length() == 0 && deletes.length() == 0) folders.remove(folder)
        else folders.put(folder, queue)
        val canonical = root.toString()
        storage.write(mapOf(repairsKey to canonical,
            "flutter.DualWritePendingUploads" to null, "flutter.DualWritePendingDeletes" to null))
        true to canonical
    }

    fun clearFailure(expected: String?): Boolean = synchronized(lock) {
        if (storage.read("flutter.StorageMode") != "s3" ||
            storage.read("flutter.S3DegradedUntil") != expected) return@synchronized false
        storage.write(mapOf("flutter.S3DegradedUntil" to null))
        true
    }

    fun confirmReceipt(scope: String, id: String, digest: String) = synchronized(lock) {
        val root = JSONObject(storage.read(receiptsKey) ?: "{}")
        for (key in root.keys()) {
            val notes = root.getJSONObject(key)
            for (note in notes.keys()) {
                if (notes.get(note) !is String) throw IllegalArgumentException("Invalid S3 receipt.")
            }
        }
        val notes = root.optJSONObject(scope) ?: JSONObject()
        notes.put(id, digest)
        root.put(scope, notes)
        storage.write(mapOf(receiptsKey to root.toString()))
    }
}
