package org.buetow.quicklog

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class S3OperationLeaseTest {
    @Test
    fun foregroundAndHeadlessEnginesCannotOverlapAndDetachReleasesLease() {
        val foreground = Any()
        val headless = Any()
        try {
            assertTrue(S3OperationLease.acquire(foreground, "save"))
            assertFalse(S3OperationLease.acquire(headless, "scheduled"))
            S3OperationLease.release(headless, "save")
            S3OperationLease.release(foreground, "old-token")
            assertFalse(S3OperationLease.acquire(headless, "scheduled"))
            S3OperationLease.detach(foreground)
            assertTrue(S3OperationLease.acquire(headless, "scheduled"))
            assertFalse(S3OperationLease.acquire(foreground, "new-save"))
            S3OperationLease.release(headless, "scheduled")
            assertTrue(S3OperationLease.acquire(foreground, "new-save"))
        } finally {
            S3OperationLease.detach(foreground)
            S3OperationLease.detach(headless)
        }
    }
}
