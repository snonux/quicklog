package org.buetow.quicklog

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SafNoteWorkflowTest {
    private val note = "ql-260507-143045.md"

    private class FakeGateway : SafDocumentGateway {
        data class Record(var name: String, var text: String = "", var renameable: Boolean = true)
        val records = linkedMapOf<String, Record>()
        var nextId = 0
        var listCalls = 0
        var failWrite = false
        var shortWrite = false
        var failPublish = false
        var corruptPublished = false
        var alterBackupName = false
        var failBackupMetadata = false
        var rotateIdOnBackup = false
        var failNextList = false
        var listingError: String? = null
        var loading = false

        fun add(name: String, text: String, renameable: Boolean = true): SafDocument {
            val id = (++nextId).toString()
            records[id] = Record(name, text, renameable)
            return SafDocument(id, name, renameable)
        }

        override fun list(): List<SafDocument> {
            listCalls++
            if (failNextList) {
                failNextList = false
                throw IOException("directory temporarily unavailable")
            }
            requireCompleteListing(loading, listingError)
            return records.map { (id, value) -> SafDocument(id, value.name, value.renameable) }
        }

        override fun create(name: String): SafDocument = add(name, "")

        override fun read(document: SafDocument): String =
            records[document.id]?.takeIf { it.name == document.name }?.text
                ?: throw java.io.FileNotFoundException()

        override fun write(document: SafDocument, text: String) {
            records[document.id]!!.text = if (failWrite || shortWrite) text.take(2) else text
            if (failWrite) throw IOException("short write")
        }

        override fun rename(document: SafDocument, name: String): SafDocument? {
            if (failPublish && document.name.startsWith(".quicklog-pending-") && name.startsWith("ql-")) {
                return null
            }
            val record = records[document.id] ?: throw java.io.FileNotFoundException()
            record.name = if (alterBackupName && name.startsWith(".quicklog-backup-")) "$name-changed" else name
            if (corruptPublished && document.name.startsWith(".quicklog-pending-") && name.startsWith("ql-")) {
                record.text = record.text.take(2)
            }
            val returnedId = if (rotateIdOnBackup && name.startsWith(".quicklog-backup-")) {
                records.remove(document.id)
                (++nextId).toString().also { records[it] = record }
            } else {
                document.id
            }
            if (failBackupMetadata && name.startsWith(".quicklog-backup-")) {
                if (rotateIdOnBackup) failNextList = true
                throw SafRenameOutcomeException(
                    SafDocument(returnedId, name, record.renameable),
                    "Post-rename metadata unavailable",
                    IOException("metadata failed"),
                )
            }
            return SafDocument(returnedId, record.name, record.renameable)
        }

        override fun delete(document: SafDocument): Boolean = records.remove(document.id) != null

        fun textAt(name: String): String? = records.values.firstOrNull { it.name == name }?.text
    }

    private fun expectIo(block: () -> Unit) {
        try {
            block()
            fail("Expected IOException")
        } catch (_: IOException) {
            // Expected provider or recovery failure.
        }
    }

    @Test
    fun createPublishesOnlyAfterCompleteStagedWrite() {
        val provider = FakeGateway()
        val workflow = SafNoteWorkflow(provider)
        workflow.create(note, "whole note")
        assertEquals("whole note", provider.textAt(note))
        assertEquals(listOf(note), workflow.list())
        assertFalse(provider.records.values.any { it.name.startsWith(".quicklog-pending-") })
    }

    @Test
    fun failedCreateLeavesOnlyRecoverableStage() {
        val provider = FakeGateway().apply { failWrite = true }
        expectIo { SafNoteWorkflow(provider).create(note, "whole note") }
        assertEquals(null, provider.textAt(note))
        assertTrue(provider.records.values.any {
            it.name.startsWith(".quicklog-pending-") && it.name.endsWith(note) && it.text == "wh"
        })
    }

    @Test
    fun silentShortWriteAndFailedPublishNeverExposeQlName() {
        val short = FakeGateway().apply { shortWrite = true }
        expectIo { SafNoteWorkflow(short).create(note, "whole note") }
        assertEquals(null, short.textAt(note))
        assertTrue(short.records.values.any { it.text == "wh" })

        val rejected = FakeGateway().apply { failPublish = true }
        expectIo { SafNoteWorkflow(rejected).create(note, "whole note") }
        assertEquals(null, rejected.textAt(note))
        assertTrue(rejected.records.values.any { it.text == "whole note" })
    }

    @Test
    fun successfulUpdateReplacesContentAndRemovesBackup() {
        val provider = FakeGateway()
        provider.add(note, "original")
        SafNoteWorkflow(provider).update(note, "replacement")
        assertEquals("replacement", provider.textAt(note))
        assertEquals(1, provider.records.size)
    }

    @Test
    fun corruptPublishedUpdateKeepsOldBackupAndBlocksAmbiguousListing() {
        val provider = FakeGateway().apply { corruptPublished = true }
        provider.add(note, "original")
        expectIo { SafNoteWorkflow(provider).update(note, "replacement") }
        assertEquals("re", provider.textAt(note))
        assertTrue(provider.records.values.any {
            it.name.startsWith(".quicklog-backup-") && it.text == "original"
        })
        expectIo { SafNoteWorkflow(provider).list() }
    }

    @Test
    fun failedStageWriteAndUnsupportedRenameNeverTouchOriginal() {
        val provider = FakeGateway()
        provider.add(note, "original")
        provider.failWrite = true
        expectIo { SafNoteWorkflow(provider).update(note, "replacement") }
        assertEquals("original", provider.textAt(note))

        val unsupported = FakeGateway()
        unsupported.add(note, "original", renameable = false)
        expectIo { SafNoteWorkflow(unsupported).update(note, "replacement") }
        assertEquals("original", unsupported.textAt(note))
        assertEquals(1, unsupported.records.size)
    }

    @Test
    fun failedPublishRollsBackOriginalAndKeepsStage() {
        val provider = FakeGateway().apply { failPublish = true }
        provider.add(note, "original")
        expectIo { SafNoteWorkflow(provider).update(note, "replacement") }
        assertEquals("original", provider.textAt(note))
        assertTrue(provider.records.values.any {
            it.name.startsWith(".quicklog-pending-") && it.name.endsWith(note) && it.text == "replacement"
        })
    }

    @Test
    fun interruptedRenameRestoresLoneBackupAndRejectsAmbiguousState() {
        val provider = FakeGateway()
        provider.add(".quicklog-backup-1234abcd-$note", "original")
        assertEquals(listOf(note), SafNoteWorkflow(provider).list())
        assertEquals("original", provider.textAt(note))
        provider.add(".quicklog-backup-abcd5678-$note", "older")
        expectIo { SafNoteWorkflow(provider).list() }
        assertEquals("original", provider.textAt(note))
    }

    @Test
    fun incompleteListingFailsAndCachedReadsAvoidRepeatedDirectoryQueries() {
        val provider = FakeGateway()
        provider.add(note, "heading\nbody")
        val workflow = SafNoteWorkflow(provider)
        assertEquals(listOf(note), workflow.list())
        val listed = provider.listCalls
        repeat(5) { assertEquals("heading", workflow.firstLine(note)) }
        assertEquals(listed, provider.listCalls)
        provider.loading = true
        expectIo { workflow.list() }
        provider.loading = false
        provider.listingError = "network unavailable"
        expectIo { workflow.list() }
    }

    @Test
    fun staleCachedDocumentFallsBackToFreshDirectoryLookup() {
        val provider = FakeGateway()
        val old = provider.add(note, "old")
        val workflow = SafNoteWorkflow(provider)
        workflow.list()
        provider.records[old.id]!!.name = "renamed.md"
        provider.add(note, "replacement")
        assertEquals("replacement", workflow.firstLine(note))
        assertTrue(provider.listCalls >= 2)
    }

    @Test
    fun fullReadRejectsDuplicateAddedAfterListing() {
        val provider = FakeGateway()
        provider.add(note, "first")
        val workflow = SafNoteWorkflow(provider)
        assertEquals(listOf(note), workflow.list())
        provider.add(note, "second")
        expectIo { workflow.read(note) }
        assertEquals(listOf("first", "second"), provider.records.values.map { it.text })
    }

    @Test
    fun duplicateCanonicalNamesFailBeforeAnySelectionOrMutation() {
        val provider = FakeGateway()
        provider.add(note, "first")
        provider.add(note, "second")
        val workflow = SafNoteWorkflow(provider)
        expectIo { workflow.list() }
        expectIo { workflow.read(note) }
        expectIo { workflow.update(note, "replacement") }
        expectIo { workflow.delete(note) }
        expectIo { workflow.create(note, "third") }
        assertEquals(listOf("first", "second"), provider.records.values.map { it.text })
        assertEquals(2, provider.records.size)
    }

    @Test
    fun changedBackupNameIsRolledBackUsingReturnedDocumentId() {
        val provider = FakeGateway().apply { alterBackupName = true }
        provider.add(note, "original")
        expectIo { SafNoteWorkflow(provider).update(note, "replacement") }
        assertEquals("original", provider.textAt(note))
        assertFalse(provider.records.values.any { it.name.startsWith(".quicklog-backup-") })
    }

    @Test
    fun postRenameMetadataFailureRollsBackUsingReturnedDocumentId() {
        val provider = FakeGateway().apply {
            failBackupMetadata = true
            rotateIdOnBackup = true
        }
        provider.add(note, "original")
        expectIo { SafNoteWorkflow(provider).update(note, "replacement") }
        assertEquals("original", provider.textAt(note))
        assertFalse(provider.records.values.any { it.name.startsWith(".quicklog-backup-") })
    }
}
