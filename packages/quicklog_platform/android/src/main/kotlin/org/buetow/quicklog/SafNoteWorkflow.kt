package org.buetow.quicklog

import java.io.IOException
import java.io.FileNotFoundException
import java.util.UUID

internal data class SafDocument(val id: String, val name: String, val canRename: Boolean)

/** Rename reached the provider, but its resulting name could not be trusted. */
internal class SafRenameOutcomeException(
    val moved: SafDocument,
    message: String,
    cause: Throwable? = null,
) : IOException(message, cause)

/** Small provider boundary so failure and recovery paths can be tested without Android. */
internal interface SafDocumentGateway {
    val recoverMovedRename: Boolean get() = false
    fun list(): List<SafDocument>
    fun create(name: String): SafDocument
    fun read(document: SafDocument): String
    fun write(document: SafDocument, text: String)
    fun rename(document: SafDocument, name: String): SafDocument?
    fun delete(document: SafDocument): Boolean
}

internal fun requireCompleteListing(loading: Boolean, error: String?) {
    if (!error.isNullOrBlank()) throw IOException("Document provider: $error")
    if (loading) throw IOException("The selected folder is still loading. Try again.")
}

private val noteNamePattern = Regex("ql-[0-9]{6}-[0-9]{6}\\.md")

internal fun isQuicklogNoteName(name: String): Boolean =
    noteNamePattern.matches(name)

/** Keeps old bytes recoverable when a provider cannot replace documents atomically. */
internal class SafNoteWorkflow(private val gateway: SafDocumentGateway) {
    private var listedNotes: Map<String, SafDocument>? = null
    private val backupPattern = Regex("^\\.quicklog-backup-[0-9a-f-]+-(ql-[0-9]{6}-[0-9]{6}\\.md)$")

    private fun requireName(name: String) {
        require(isQuicklogNoteName(name)) { "Invalid note filename." }
    }

    private fun renamed(document: SafDocument, name: String): SafDocument {
        if (!document.canRename) throw IOException("This document provider cannot safely rename $name.")
        val before = if (gateway.recoverMovedRename) gateway.list() else null
        if (before?.any { it.name == name } == true) throw IOException("A document named $name already exists.")
        val bytes = before?.let { gateway.read(document) }
        val result = try {
            gateway.rename(document, name)
                ?: throw IOException("The document provider could not rename $name.")
        } catch (e: FileNotFoundException) {
            // Android 9's external-storage provider can move the file and then
            // throw while looking up its old path for the media-store update.
            // Accept that outcome only after verifying a new, unique document
            // with the requested name and unchanged bytes, with the old id gone.
            // Document ids remain opaque: never manufacture a new id from a path.
            if (before == null) throw e
            val after = try { gateway.list() } catch (_: Exception) { throw e }
            val candidate = after.singleOrNull { it.name == name }
            if (candidate == null || before.any { it.id == candidate.id } ||
                after.any { it.id == document.id } || gateway.read(candidate) != bytes) {
                throw e
            }
            candidate
        }
        if (result.name != name) {
            throw SafRenameOutcomeException(result, "The document provider renamed $name to ${result.name}.")
        }
        return result
    }

    private fun rejectDuplicates(docs: List<SafDocument>) {
        val duplicate = docs.filter { isQuicklogNoteName(it.name) }
            .groupBy { it.name }.entries.firstOrNull { it.value.size > 1 }
        if (duplicate != null) {
            throw IOException("The selected folder contains multiple documents named ${duplicate.key}. Resolve them before using this note.")
        }
    }

    private fun scan(): List<SafDocument> {
        var docs = gateway.list()
        rejectDuplicates(docs)
        val backups = docs.mapNotNull { doc ->
            backupPattern.matchEntire(doc.name)?.groupValues?.get(1)?.let { it to doc }
        }.groupBy({ it.first }, { it.second })
        for ((name, copies) in backups) {
            if (docs.any { it.name == name } || copies.size != 1) {
                val backupNames = copies.joinToString { it.name }
                throw IOException("An interrupted edit left $backupNames for $name. Resolve it in the selected folder.")
            }
            // A crash between the two renames leaves the old note under its
            // backup name. Restore it before reporting a listing or missing id.
            renamed(copies.single(), name)
            docs = gateway.list()
            rejectDuplicates(docs)
        }
        listedNotes = docs.filter { isQuicklogNoteName(it.name) }.associateBy { it.name }
        return docs
    }

    private fun restoreAfterBackupRenameFailure(
        name: String,
        original: SafDocument,
        outcome: SafRenameOutcomeException?,
    ) {
        // The returned document ID is useful even if the provider's metadata
        // query failed after a successful rename. Prefer fresh metadata when
        // available, but try the returned ID directly if listing also fails.
        val moved = outcome?.moved
        val docs = try { gateway.list() } catch (_: Exception) { emptyList() }
        // Another document using the canonical name is ambiguous. Leave both
        // untouched so a rollback cannot overwrite the wrong one.
        if (docs.any { it.name == name }) return
        val candidate = moved?.let { returned ->
            docs.firstOrNull { it.id == returned.id } ?: returned
        } ?: docs.firstOrNull { it.id == original.id }
        if (candidate != null) renamed(candidate, name)
    }

    fun list(): List<String> = scan().map { it.name }.filter(::isQuicklogNoteName).distinct()

    fun read(name: String): String {
        requireName(name)
        // Editors and delete previews must see a fresh provider snapshot.
        // A sync peer may have added a second document with this display name
        // since list() populated the subtitle cache.
        val current = scan().firstOrNull { it.name == name } ?: throw NoteMissingException()
        return gateway.read(current)
    }

    fun firstLine(name: String): String {
        requireName(name)
        val cached = listedNotes?.get(name)
        if (cached != null) {
            try {
                return gateway.read(cached).substringBefore('\n')
            } catch (_: IOException) {
                listedNotes = null
            }
        }
        val current = scan().firstOrNull { it.name == name } ?: throw NoteMissingException()
        return gateway.read(current).substringBefore('\n')
    }

    private fun stage(name: String, text: String): SafDocument {
        val stageName = ".quicklog-pending-${UUID.randomUUID()}-$name"
        val document = gateway.create(stageName)
        if (document.name != stageName) throw IOException("Provider changed staging filename; check $stageName.")
        if (!document.canRename) throw IOException("Provider cannot publish staged note; check $stageName.")
        try {
            gateway.write(document, text)
            if (gateway.read(document) != text) throw IOException("Provider did not save the full note.")
        } catch (e: SecurityException) {
            throw e
        } catch (e: Exception) {
            throw IOException("Note write failed; staged data may remain as $stageName.", e)
        }
        return document
    }

    fun create(name: String, text: String) {
        requireName(name)
        listedNotes = null
        if (scan().any { it.name == name }) throw IOException("A note with this timestamp already exists.")
        val staged = stage(name, text)
        listedNotes = null
        if (scan().any { it.name == name }) throw IOException("A note with this timestamp already exists; staged data remains as ${staged.name}.")
        val published = renamed(staged, name)
        try {
            if (gateway.read(published) != text) throw IOException("Provider did not preserve the new note.")
        } catch (e: Exception) {
            try {
                renamed(published, staged.name)
            } catch (rollback: Exception) {
                e.addSuppressed(rollback)
            }
            throw IOException("Cannot verify the new note; staged data may remain as ${staged.name}.", e)
        }
        listedNotes = null
    }

    fun update(name: String, text: String) {
        requireName(name)
        listedNotes = null
        val original = scan().firstOrNull { it.name == name } ?: throw NoteMissingException()
        if (!original.canRename) throw IOException("This document provider cannot safely update the note.")
        val oldText = gateway.read(original)
        val staged = stage(name, text)
        listedNotes = null
        val latest = scan().firstOrNull { it.name == name } ?: throw NoteMissingException()
        if (latest.id != original.id || gateway.read(latest) != oldText) {
            throw IOException("The note changed while editing; staged data remains as ${staged.name}.")
        }
        val backupName = ".quicklog-backup-${UUID.randomUUID()}-$name"
        val backup = try {
            renamed(latest, backupName)
        } catch (e: Exception) {
            try {
                restoreAfterBackupRenameFailure(name, latest, e as? SafRenameOutcomeException)
            } catch (rollback: Exception) {
                e.addSuppressed(rollback)
            }
            listedNotes = null
            val moved = (e as? SafRenameOutcomeException)?.moved
            val location = moved?.let { "${it.name} (document ${it.id})" } ?: backupName
            throw IOException("Backup rename failed; original content remains at $name or $location.", e)
        }
        listedNotes = null
        try {
            val published = renamed(staged, name)
            if (gateway.read(published) != text) throw IOException("Provider did not preserve the edited note.")
            if (!gateway.delete(backup)) throw IOException("Provider could not remove the backup.")
        } catch (e: Exception) {
            // Do not overwrite a possibly published new note. If the canonical
            // name is absent, restore the backup; otherwise preserve both for
            // manual recovery. The next scan will also restore a lone backup.
            try {
                if (gateway.list().none { it.name == name }) renamed(backup, name)
            } catch (rollback: Exception) {
                e.addSuppressed(rollback)
            }
            throw IOException("Update failed; original content is in $backupName or $name.", e)
        } finally {
            listedNotes = null
        }
    }

    fun delete(name: String) {
        requireName(name)
        listedNotes = null
        val current = scan().firstOrNull { it.name == name } ?: return
        if (!gateway.delete(current)) throw IOException("Cannot delete the note.")
        listedNotes = null
    }
}

internal class NoteMissingException : IOException("The note no longer exists.")
