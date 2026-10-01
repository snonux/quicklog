package org.buetow.quicklog

/** Fail-fast exclusion shared by the foreground and headless Flutter engines. */
internal object S3OperationLease {
    private var owner: Any? = null
    private var token: String? = null

    @Synchronized
    fun acquire(engine: Any, operation: String): Boolean {
        if (owner != null) return false
        owner = engine
        token = operation
        return true
    }

    @Synchronized
    fun release(engine: Any, operation: String) {
        if (owner === engine && token == operation) {
            owner = null
            token = null
        }
    }

    @Synchronized
    fun detach(engine: Any) {
        if (owner === engine) {
            owner = null
            token = null
        }
    }
}
