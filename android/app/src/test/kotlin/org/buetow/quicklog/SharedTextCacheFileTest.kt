package org.buetow.quicklog

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SharedTextCacheFileTest {
    @get:Rule val folder = TemporaryFolder()

    @Test fun deletesOnlyMatchingContent() {
        val file = folder.newFile("share.txt")
        file.writeText("new share")

        assertFalse(clearSharedTextCacheIfEquals(file, "handled share"))
        assertEquals("new share", file.readText())

        assertTrue(clearSharedTextCacheIfEquals(file, "new share"))
        assertFalse(file.exists())
    }

    @Test fun missingCacheReturnsFalse() {
        val file = folder.root.resolve("missing.txt")
        assertFalse(clearSharedTextCacheIfEquals(file, "handled share"))
    }

    @Test fun failedDeleteKeepsTheShareAndReportsAnError() {
        val file = folder.newFile("share.txt")
        file.writeText("handled share")

        assertThrows(IOException::class.java) {
            clearSharedTextCacheIfEquals(file, "handled share") { false }
        }
        assertEquals("handled share", file.readText())
    }
}
