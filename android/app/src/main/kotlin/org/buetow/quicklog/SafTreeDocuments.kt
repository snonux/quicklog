package org.buetow.quicklog

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import java.io.IOException

private val noteName = Regex("ql-[0-9]{6}-[0-9]{6}\\.md")

internal fun isQuicklogNoteName(name: String): Boolean = noteName.matches(name)

/** Document-provider operations for a previously persisted SAF tree grant. */
internal class SafTreeDocuments(private val resolver: ContentResolver) {

    private fun tree(raw: String, write: Boolean): Uri {
        val uri = Uri.parse(raw)
        require(uri.scheme == ContentResolver.SCHEME_CONTENT && DocumentsContract.isTreeUri(uri)) {
            "A document tree URI is required."
        }
        val granted = resolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && (!write || it.isWritePermission)
        }
        if (!granted) throw SecurityException("Access to the selected folder has expired. Select it again.")
        return uri
    }

    private fun checkedName(name: String): String {
        require(isQuicklogNoteName(name)) { "Invalid note filename." }
        return name
    }

    private fun children(tree: Uri): List<Pair<String, Uri>> {
        val parentId = DocumentsContract.getTreeDocumentId(tree)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val result = mutableListOf<Pair<String, Uri>>()
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        val cursor = resolver.query(childrenUri, columns, null, null, null)
            ?: throw IOException("Cannot list the selected folder.")
        cursor.use {
            while (it.moveToNext()) {
                val name = it.getString(1) ?: continue
                if (it.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) continue
                val id = it.getString(0) ?: continue
                result.add(name to DocumentsContract.buildDocumentUriUsingTree(tree, id))
            }
        }
        return result
    }

    private fun find(tree: Uri, name: String): Uri? =
        children(tree).firstOrNull { it.first == name }?.second

    fun list(rawTree: String): List<String> {
        val tree = tree(rawTree, write = false)
        return children(tree).map { it.first }.filter(::isQuicklogNoteName)
    }

    fun read(rawTree: String, name: String): String {
        checkedName(name)
        val tree = tree(rawTree, write = false)
        val document = find(tree, name) ?: throw NoteMissingException()
        val input = resolver.openInputStream(document) ?: throw IOException("Cannot read the note.")
        return input.bufferedReader(Charsets.UTF_8).use { it.readText() }
    }

    fun create(rawTree: String, name: String, text: String) {
        checkedName(name)
        val tree = tree(rawTree, write = true)
        if (find(tree, name) != null) throw IOException("A note with this timestamp already exists.")
        val parent = DocumentsContract.buildDocumentUriUsingTree(
            tree,
            DocumentsContract.getTreeDocumentId(tree),
        )
        val document = DocumentsContract.createDocument(resolver, parent, "text/markdown", name)
            ?: throw IOException("Cannot create the note.")
        // Some providers change the requested name. A mismatched name cannot
        // serve as a Quicklog note identity, so report it instead of claiming
        // that the expected file was saved. Leave that newly created document
        // alone: a provider may have reused an existing document URI, and a
        // cleanup delete here could remove the user's content.
        val actualName = resolver.query(
            document,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
        if (actualName != name) throw IOException("The document provider changed the note filename.")
        val output = resolver.openOutputStream(document, "w")
            ?: throw IOException("Cannot write the new note.")
        output.use { it.write(text.toByteArray(Charsets.UTF_8)) }
    }

    fun update(rawTree: String, name: String, text: String) {
        checkedName(name)
        val tree = tree(rawTree, write = true)
        val document = find(tree, name) ?: throw NoteMissingException()
        // Both modes request truncation. Never fall back to plain "w" for an
        // existing note: providers may append or retain a stale suffix.
        val output = try {
            resolver.openOutputStream(document, "rwt")
        } catch (_: IllegalArgumentException) {
            resolver.openOutputStream(document, "wt")
        } ?: throw IOException("Cannot update the note.")
        output.use { it.write(text.toByteArray(Charsets.UTF_8)) }
    }

    fun delete(rawTree: String, name: String) {
        checkedName(name)
        val tree = tree(rawTree, write = true)
        val document = find(tree, name) ?: return
        if (!DocumentsContract.deleteDocument(resolver, document)) {
            throw IOException("Cannot delete the note.")
        }
    }
}

internal class NoteMissingException : IOException("The note no longer exists.")
