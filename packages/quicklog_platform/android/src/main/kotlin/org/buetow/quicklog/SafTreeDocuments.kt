package org.buetow.quicklog

import android.content.ContentResolver
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import java.io.FileNotFoundException
import java.io.IOException

/** Android transport for the provider-independent safe note workflow. */
internal class SafTreeDocuments(private val resolver: ContentResolver) {
    private var currentTree: Uri? = null
    private var currentWorkflow: SafNoteWorkflow? = null

    private fun workflow(raw: String, write: Boolean): SafNoteWorkflow {
        val tree = Uri.parse(raw)
        require(tree.scheme == ContentResolver.SCHEME_CONTENT && DocumentsContract.isTreeUri(tree)) {
            "A document tree URI is required."
        }
        val granted = resolver.persistedUriPermissions.any {
            it.uri == tree && it.isReadPermission && (!write || it.isWritePermission)
        }
        if (!granted) throw SecurityException("Access to the selected folder has expired. Select it again.")
        if (currentTree != tree || currentWorkflow == null) {
            currentTree = tree
            currentWorkflow = SafNoteWorkflow(ProviderGateway(tree))
        }
        return currentWorkflow!!
    }

    fun list(raw: String): List<String> = workflow(raw, write = false).list()
    fun read(raw: String, name: String): String = workflow(raw, write = false).read(name)
    fun firstLine(raw: String, name: String): String = workflow(raw, write = false).firstLine(name)
    fun create(raw: String, name: String, text: String) = workflow(raw, write = true).create(name, text)
    fun update(raw: String, name: String, text: String) = workflow(raw, write = true).update(name, text)
    fun delete(raw: String, name: String) = workflow(raw, write = true).delete(name)

    /**
     * Writes a new image attachment [name] into the tree. Images are never
     * overwritten: when the provider stores the new document under another
     * name (it de-duplicates clashes as "name (1)"), the copy is removed and
     * the call fails, so a note never links to a file that is not there.
     */
    fun writeImage(raw: String, name: String, mimeType: String, bytes: ByteArray) {
        workflow(raw, write = true)
        val tree = Uri.parse(raw)
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val created = DocumentsContract.createDocument(resolver, parent, mimeType, name)
            ?: throw IOException("Cannot create the image file.")
        try {
            val actual = resolver.query(
                created, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null,
            )?.use { if (it.moveToFirst()) it.getString(0) else null }
            if (actual != name) throw IOException("An image named $name already exists.")
            val output = resolver.openOutputStream(created, "w")
                ?: throw IOException("Cannot write the image file.")
            output.use { it.write(bytes) }
        } catch (e: Exception) {
            try {
                DocumentsContract.deleteDocument(resolver, created)
            } catch (_: Exception) {
                // The original error is the one worth reporting.
            }
            throw e
        }
    }

    private inner class ProviderGateway(private val tree: Uri) : SafDocumentGateway {
        override val recoverMovedRename: Boolean
            get() = Build.VERSION.SDK_INT == Build.VERSION_CODES.P &&
                tree.authority == "com.android.externalstorage.documents"

        private fun documentUri(id: String): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)

        override fun list(): List<SafDocument> {
            val parentId = DocumentsContract.getTreeDocumentId(tree)
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
            val columns = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_FLAGS,
            )
            val cursor = resolver.query(childrenUri, columns, null, null, null)
                ?: throw IOException("Cannot list the selected folder.")
            cursor.use {
                val result = mutableListOf<SafDocument>()
                while (it.moveToNext()) {
                    val id = it.getString(0) ?: continue
                    val name = it.getString(1) ?: continue
                    if (it.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) continue
                    val flags = it.getInt(3)
                    result.add(SafDocument(id, name, flags and DocumentsContract.Document.FLAG_SUPPORTS_RENAME != 0))
                }
                val extras = it.extras
                requireCompleteListing(
                    extras.getBoolean(DocumentsContract.EXTRA_LOADING, false),
                    extras.getString(DocumentsContract.EXTRA_ERROR),
                )
                return result
            }
        }

        private fun metadata(uri: Uri): SafDocument {
            val columns = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_FLAGS,
            )
            val cursor = resolver.query(uri, columns, null, null, null)
                ?: throw IOException("Cannot inspect the document provider result.")
            cursor.use {
                if (!it.moveToFirst()) throw IOException("Document provider returned no metadata.")
                val id = it.getString(0) ?: throw IOException("Document provider returned no document id.")
                val name = it.getString(1) ?: throw IOException("Document provider returned no filename.")
                val flags = it.getInt(2)
                return SafDocument(id, name, flags and DocumentsContract.Document.FLAG_SUPPORTS_RENAME != 0)
            }
        }

        override fun create(name: String): SafDocument {
            val parent = documentUri(DocumentsContract.getTreeDocumentId(tree))
            val created = DocumentsContract.createDocument(resolver, parent, "text/markdown", name)
                ?: throw IOException("Cannot create a staged note.")
            return metadata(created)
        }

        override fun read(document: SafDocument): String {
            val uri = documentUri(document.id)
            // A provider may keep the same document id after an external rename.
            // Check that a cached id still names the requested note without
            // querying the entire directory for every list subtitle.
            if (metadata(uri).name != document.name) throw FileNotFoundException("Note was renamed.")
            val input = resolver.openInputStream(uri)
                ?: throw IOException("Cannot read the note.")
            return input.bufferedReader(Charsets.UTF_8).use { it.readText() }
        }

        override fun write(document: SafDocument, text: String) {
            // Only newly created staging documents are written. Never open an
            // existing ql document with a truncating mode.
            val output = resolver.openOutputStream(documentUri(document.id), "w")
                ?: throw IOException("Cannot write the staged note.")
            output.use { it.write(text.toByteArray(Charsets.UTF_8)) }
        }

        override fun rename(document: SafDocument, name: String): SafDocument? {
            val renamed = DocumentsContract.renameDocument(resolver, documentUri(document.id), name)
                ?: return null
            val returnedId = try {
                DocumentsContract.getDocumentId(renamed)
            } catch (_: IllegalArgumentException) {
                document.id
            }
            return try {
                metadata(renamed)
            } catch (e: Exception) {
                throw SafRenameOutcomeException(
                    SafDocument(returnedId, name, document.canRename),
                    "The provider renamed the document but its metadata could not be read (id $returnedId).",
                    e,
                )
            }
        }

        override fun delete(document: SafDocument): Boolean =
            DocumentsContract.deleteDocument(resolver, documentUri(document.id))
    }
}
