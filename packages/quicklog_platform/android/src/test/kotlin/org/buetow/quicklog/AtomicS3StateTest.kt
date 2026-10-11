package org.buetow.quicklog

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

private class MemoryS3State : S3StateStorage {
    val values = mutableMapOf<String, String>()
    override fun read(key: String) = values[key]
    override fun write(values: Map<String, String?>) {
        for ((key, value) in values) {
            if (value == null) this.values.remove(key) else this.values[key] = value
        }
    }
}

class AtomicS3StateTest {
    private val empty = "{\"folders\":{}}"
    private val first = "ql-261001-090000.md"
    private val second = "ql-261001-090001.md"

    @Test
    fun twoEngineOwnersMergeUnrelatedIdsAndRejectOlderSameIdClear() {
        val storage = MemoryS3State()
        val foreground = AtomicS3State(storage)
        val worker = AtomicS3State(storage)
        foreground.mutateRepair(empty, "/notes", first, "upload", null, false)
        val snapshot = JSONObject(worker.readRepairs(empty))
        val revision = snapshot.getJSONObject("folders").getJSONObject("/notes")
            .getJSONObject("revisions").getString(first)
        foreground.mutateRepair(empty, "/other", second, "upload", null, false)
        foreground.mutateRepair(empty, "/notes", first, "upload", null, false)
        val (cleared, document) = worker.mutateRepair(empty, "/notes", first, "clear", revision, true)
        assertFalse(cleared)
        val folders = JSONObject(document).getJSONObject("folders")
        assertEquals(first, folders.getJSONObject("/notes").getJSONArray("uploads").getString(0))
        assertEquals(second, folders.getJSONObject("/other").getJSONArray("uploads").getString(0))
        val latest = folders.getJSONObject("/notes").getJSONObject("revisions").getString(first)
        assertTrue(worker.mutateRepair(empty, "/notes", first, "clear", latest, true).first)
        assertTrue(JSONObject(worker.readRepairs(empty)).getJSONObject("folders").has("/other"))
    }

    @Test
    fun legacyCanonicalMigrationPreservesFoldersAndRemovesLegacyKeys() {
        val storage = MemoryS3State()
        storage.values[AtomicS3State.repairsKey] = """{"directory":"/legacy","uploads":["$first"],"deletes":[]}"""
        storage.values["flutter.DualWritePendingUploads"] = "legacy-list"
        val state = AtomicS3State(storage)
        val (_, document) = state.mutateRepair(empty, "saf:content://tree/new", second, "delete", null, false)
        val folders = JSONObject(document).getJSONObject("folders")
        assertTrue(folders.has("/legacy"))
        assertTrue(folders.has("saf:content://tree/new"))
        assertFalse(storage.values.containsKey("flutter.DualWritePendingUploads"))
        assertTrue(storage.values[AtomicS3State.repairsKey]!!.contains("folders"))
    }

    @Test
    fun legacyListsPassedByDartMigrateWithoutOverwritingOtherEngineCanonicalState() {
        val storage = MemoryS3State()
        val state = AtomicS3State(storage)
        val legacy = """{"folders":{"/legacy":{"uploads":["$first"],"deletes":[]}}}"""
        state.mutateRepair(legacy, "/new", second, "upload", null, false)
        // Another engine still supplies its old legacy snapshot. Canonical wins.
        state.mutateRepair(legacy, "/legacy", first, "clear", null, false)
        val folders = JSONObject(state.readRepairs(legacy)).getJSONObject("folders")
        assertFalse(folders.has("/legacy"))
        assertTrue(folders.has("/new"))
    }

    @Test
    fun receiptsMergeAcrossEnginesWithoutRawPayloads() {
        val storage = MemoryS3State()
        AtomicS3State(storage).confirmReceipt("scope-a", first, "digest-a")
        AtomicS3State(storage).confirmReceipt("scope-b", second, "digest-b")
        val root = JSONObject(storage.values[AtomicS3State.receiptsKey]!!)
        assertEquals("digest-a", root.getJSONObject("scope-a").getString(first))
        assertEquals("digest-b", root.getJSONObject("scope-b").getString(second))
    }

    @Test
    fun pruningPreservesLiveDigestsAndOtherEngineScopes() {
        val storage = MemoryS3State()
        val foreground = AtomicS3State(storage)
        val worker = AtomicS3State(storage)
        foreground.confirmReceipt("scope", first, "kept")
        foreground.confirmReceipt("scope", second, "gone")
        worker.confirmReceipt("other", second, "other")
        worker.pruneReceipts("scope", setOf(first))
        var root = JSONObject(storage.values[AtomicS3State.receiptsKey]!!)
        assertEquals("kept", root.getJSONObject("scope").getString(first))
        assertFalse(root.getJSONObject("scope").has(second))
        assertEquals("other", root.getJSONObject("other").getString(second))
        foreground.confirmReceipt("scope", second, "new")
        assertEquals("new", JSONObject(storage.values[AtomicS3State.receiptsKey]!!)
            .getJSONObject("scope").getString(second))
        worker.pruneReceipts("scope", emptySet())
        root = JSONObject(storage.values[AtomicS3State.receiptsKey]!!)
        assertFalse(root.has("scope"))
        assertTrue(root.has("other"))
    }

    @Test
    fun pruningNoOpDoesNotRewriteReceipts() {
        val storage = MemoryS3State()
        val state = AtomicS3State(storage)
        state.pruneReceipts("missing", emptySet())
        assertFalse(storage.values.containsKey(AtomicS3State.receiptsKey))
        val original = """{ "scope": { "$first": "digest" } }"""
        storage.values[AtomicS3State.receiptsKey] = original
        state.pruneReceipts("scope", setOf(first))
        state.pruneReceipts("missing", emptySet())
        assertEquals(original, storage.values[AtomicS3State.receiptsKey])
    }

    @Test
    fun pruningCorruptReceiptsFailsWithoutMutation() {
        for (damaged in listOf("{broken", "{\"scope\":4}", "{\"scope\":{\"id\":4}}")) {
            val storage = MemoryS3State()
            storage.values[AtomicS3State.receiptsKey] = damaged
            try {
                AtomicS3State(storage).pruneReceipts("scope", emptySet())
                fail("damaged receipts accepted")
            } catch (_: Exception) { }
            assertEquals(damaged, storage.values[AtomicS3State.receiptsKey])
        }
    }

    @Test
    fun anOlderSuccessfulListCannotClearNewerFailureWindow() {
        val storage = MemoryS3State()
        storage.values["flutter.StorageMode"] = "s3"
        storage.values["flutter.S3DegradedUntil"] = "new-window"
        val worker = AtomicS3State(storage)
        assertFalse(worker.clearFailure("old-window"))
        assertEquals("new-window", storage.values["flutter.S3DegradedUntil"])
        assertTrue(worker.clearFailure("new-window"))
        assertFalse(storage.values.containsKey("flutter.S3DegradedUntil"))
    }

    @Test
    fun corruptedDocumentsFailClosedWithoutMutation() {
        for (damaged in listOf("{broken", "{}", "{\"folders\":{\"/notes\":{\"uploads\":[4]}}}", "{\"directory\":\"/legacy\",\"uploads\":4}")) {
            val storage = MemoryS3State()
            storage.values[AtomicS3State.repairsKey] = damaged
            try {
                AtomicS3State(storage).mutateRepair(empty, "/notes", first, "upload", null, false)
                fail("damaged repairs accepted")
            } catch (_: Exception) { }
            assertEquals(damaged, storage.values[AtomicS3State.repairsKey])
        }
        val storage = MemoryS3State()
        storage.values[AtomicS3State.receiptsKey] = "{\"scope\":{\"id\":4}}"
        try {
            AtomicS3State(storage).confirmReceipt("other", first, "digest")
            fail("damaged receipts accepted")
        } catch (_: Exception) { }
        assertEquals("{\"scope\":{\"id\":4}}", storage.values[AtomicS3State.receiptsKey])
    }
}
