package org.buetow.quicklog

import java.io.File
import java.io.IOException

// MainActivity calls this on the main thread, as it does captureSendIntent,
// so a new share cannot overwrite the file between the comparison and delete.
internal fun clearSharedTextCacheIfEquals(
    file: File,
    expected: String,
    delete: (File) -> Boolean = File::delete,
): Boolean {
    if (!file.exists() || file.readText() != expected) return false
    if (!delete(file)) throw IOException("Could not clear the shared-text cache.")
    return true
}
