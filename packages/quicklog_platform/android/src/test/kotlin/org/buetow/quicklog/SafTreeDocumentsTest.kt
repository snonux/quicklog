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
}
