package com.example.shiroha_quiz.external

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** One proof operation's endpoint, including acquisition after withdrawal. */
internal class DeviceProofCloseOwner {
    private val closer = Executors.newSingleThreadExecutor { work ->
        Thread(work, "shiroha-native-proof-close")
    }
    private var requested = false
    private var close: DeviceCloseWork? = null
    private var finished = false
    private var failed = false

    @Synchronized fun adopt(action: () -> Unit) {
        check(close == null && !finished)
        close = DeviceCloseWork(closer, action)
        if (requested) close!!.request()
    }

    @Synchronized fun request() {
        requested = true
        close?.request()
    }

    /** Called only by the original proof worker, after its final acquisition. */
    fun settle() {
        val work = synchronized(this) {
            finished = true
            request()
            close
        }
        try {
            work?.join()
        } catch (_: Exception) {
            failed = true
        } finally {
            // Never abandon a queued/running original close on timeout or failure.
            closer.shutdown()
            try {
                if (!closer.awaitTermination(5, TimeUnit.SECONDS)) failed = true
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                failed = true
            }
        }
        if (failed) throw DeviceLinkFailure("settlement_unknown")
    }
}
