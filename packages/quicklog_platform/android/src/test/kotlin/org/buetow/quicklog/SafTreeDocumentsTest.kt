package org.buetow.quicklog

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafTreeDocumentsTest {
    @Test
    fun noteNamesAreBareTimestampedMarkdownFiles() {
        assertTrue(isQuicklogNoteName("ql-260507-143045.md"))
        for (name in listOf(
            "../ql-260507-143045.md",
            "/ql-260507-143045.md",
            "folder/ql-260507-143045.md",
            "ql-260507-143045.md/../other",
            "ql-260507-143045.md.txt",
            "other.md",
        )) {
            assertFalse(name, isQuicklogNoteName(name))
        }
    }

    /**
     * v0.4.0 saved pictures into the tree as `ql-img-*` documents. Image
     * support is gone, the documents are not: they must never pass for a
     * note, or list/read/update/delete would start acting on them.
     */
    @Test
    fun imageFilesLeftByV040AreNotNoteNames() {
        for (name in listOf(
            "ql-img-260507-143045-123.jpg",
            "ql-img-260507-143045-123.png",
            "ql-img-260507-143045-123.heic",
            // A type v0.4.0 never wrote, and no extension at all.
            "ql-img-260507-143045-123.bmp",
            "ql-img-260507-143045-123",
            // Dressed up as Markdown: only a loosened pattern accepts these.
            "ql-img-260507-143045-123.md",
            "ql-img-260507-143045.md",
            // Contain a whole note name: only a contains-match accepts these.
            "ql-img-ql-260507-143045.md",
            "ql-260507-143045.md-img.jpg",
        )) {
            assertFalse(name, isQuicklogNoteName(name))
        }
    }
}
