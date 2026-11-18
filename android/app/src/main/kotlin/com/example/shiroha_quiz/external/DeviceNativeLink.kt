package com.example.shiroha_quiz.external

import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import android.os.SystemClock
import javax.net.ssl.SSLSocket

/** Native socket custody only. No Profile, P0, Grant or business implementation. */
internal class DeviceNativeLink(
    private val keys: DeviceCredentials,
    private val gate: DeviceForegroundGate,
    address: String,
    private val expectedClient: String?,
    enrollment: Boolean,
    val periodEndsMs: Long?,
    preparationEndsMs: Long,
    businessResume: Boolean,
    private val event: (String, Map<String, Any?>) -> Unit,
) {
    val id = UUID.randomUUID().toString()
    private val epoch = gate.sequence
    private val network = gate.network ?: throw DeviceLinkFailure("foreground_required")
    private val endpoint = DeviceTlsEndpoint(keys, gate)
    private val workers = Executors.newFixedThreadPool(2)
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private val closer = Executors.newSingleThreadExecutor()
    private val listenerClose = DeviceCloseWork(closer) { endpoint.stopAccepting() }
    private val endpointClose = DeviceCloseWork(closer) { endpoint.close() }
    private val observedMs = SystemClock.elapsedRealtime()
    @Volatile private var admissionEndsMs = if (businessResume) periodEndsMs
        else minOf(periodEndsMs ?: preparationEndsMs, preparationEndsMs)
    private var business = businessResume
    private var expiry: java.util.concurrent.ScheduledFuture<*>? = null
    private val channels = mutableMapOf<String, Channel>()
    @Volatile private var closed = false
    @Volatile private var failed = false
    val port: Int

    init {
        if ((periodEndsMs == null && (enrollment || businessResume)) ||
            (periodEndsMs != null && (periodEndsMs <= observedMs ||
                periodEndsMs - observedMs > TimeUnit.HOURS.toMillis(8))) ||
            (!businessResume && (preparationEndsMs <= observedMs || preparationEndsMs - observedMs > 120000)) ||
            enrollment && businessResume)
            throw DeviceLinkFailure("foreground_required")
        if (!gate.current(epoch, network) || network.substringAfter('/') != address)
            throw DeviceLinkFailure("foreground_required")
        try {
            port = endpoint.listen(InetAddress.getByName(address), expectedClient, epoch, network,
                port = 46443, enrollment = enrollment, acceptTimeout = 0)
            scheduleExpiry()
            repeat(2) { workers.execute { accept() } }
        } catch (error: Exception) {
            closed = true
            try { endpoint.close() } catch (_: Exception) { failed = true }
            workers.shutdownNow(); timer.shutdownNow(); closer.shutdownNow()
            if (failed) throw DeviceLinkFailure("settlement_unknown")
            throw error
        }
    }

    private fun scheduleExpiry() {
        expiry?.cancel(false)
        expiry = admissionEndsMs?.let { ends ->
            timer.schedule(::expireAdmission, (ends - SystemClock.elapsedRealtime()).coerceAtLeast(0),
                TimeUnit.MILLISECONDS)
        }
    }
    private fun admissionExpired(): Boolean =
        admissionEndsMs?.let { SystemClock.elapsedRealtime() >= it } == true

    @Synchronized private fun expireAdmission() {
        if (closed) return
        if (admissionExpired()) withdraw() else scheduleExpiry()
    }

    @Synchronized fun completePreparation() {
        if (closed || business || expectedClient == null || admissionExpired() ||
            !gate.current(epoch, network) || synchronized(channels) { channels.isNotEmpty() })
            throw DeviceLinkFailure("foreground_required")
        business = true
        admissionEndsMs = periodEndsMs
        scheduleExpiry()
    }

    private fun accept() {
        while (!closed && gate.listenerCurrent(epoch, network)) {
            var original: Channel? = null
            try {
                endpoint.withChannel(epoch, network, expectedClient) { socket, digest, establishmentEnds ->
                    val channel = Channel(socket, digest)
                    synchronized(channels) {
                        if (closed || !gate.current(epoch, network)) throw DeviceLinkFailure("connection_closed")
                        channels[channel.id] = channel
                        original = channel
                    }
                    val deadline = timer.schedule({ channel.withdraw() },
                        (establishmentEnds - System.nanoTime()).coerceAtLeast(0), TimeUnit.NANOSECONDS)
                    channel.establishment = deadline
                    event("connected", mapOf("channel" to channel.id, "peer" to digest,
                        "installationId" to keys.installationId(), "epoch" to epoch,
                        "network" to network))
                    channel.stopped.await()
                }
            } catch (error: Exception) {
                if (error is DeviceLinkFailure && error.code == "settlement_unknown") failed = true
                if (closed || !gate.listenerCurrent(epoch, network)) break
                // A refused extra/early peer never acquires the incumbent slot.
            } finally {
                original?.let { channel ->
                    channel.withdraw()
                    try { channel.closeWork.join() } catch (_: Exception) { failed = true }
                    channel.settled.countDown()
                    event("disconnected", mapOf("channel" to channel.id, "settled" to !failed,
                        "backgroundRead" to gate.backgroundRead))
                }
            }
        }
    }

    private fun channel(id: String): Channel = synchronized(channels) {
        channels[id] ?: throw DeviceLinkFailure("connection_closed")
    }

    fun attest(id: String, peer: String, installation: String): Boolean {
        val channel = channel(id)
        try { channel.current() } catch (_: DeviceLinkFailure) { return false }
        return !closed && !channel.closed && gate.current(epoch, network, id) &&
            channel.peer == peer && keys.installationId() == installation &&
            !channel.socket.isClosed && channel.socket.session.protocol == "TLSv1.3"
    }

    fun established(id: String, closeControl: Boolean = false, keepWhileLocked: Boolean = false) {
        if (keepWhileLocked && !business) throw DeviceLinkFailure("protocol_violation")
        channel(id).established(business && closeControl, keepWhileLocked)
    }
    fun proofStarted(id: String) {
        val channel = channel(id)
        channel.current()
        if (channel.proofDeadline != null) throw DeviceLinkFailure("protocol_violation")
        channel.proofEnds = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        channel.proofDeadline = timer.schedule({ channel.withdraw() }, 30, TimeUnit.SECONDS)
    }

    fun read(id: String): Map<String, Any?> {
        val channel = channel(id)
        if (!channel.reading.compareAndSet(false, true)) throw DeviceLinkFailure("resource_limit")
        try {
            channel.current(control = true)
            val frame = DeviceLinkFrames.readTimed(channel.socket)
            channel.current(control = frame.kind == 1)
            return mapOf("kind" to frame.kind, "payload" to frame.payload)
        } catch (error: Exception) {
            channel.withdraw()
            throw error
        } finally { channel.reading.set(false) }
    }

    fun write(id: String, kind: Int, payload: ByteArray) {
        val channel = channel(id)
        // One writer and at most one waiting frame (heartbeat coalesced above).
        if (channel.queued.incrementAndGet() > 2) {
            channel.queued.decrementAndGet()
            throw DeviceLinkFailure("resource_limit")
        }
        try {
            synchronized(channel.writer) {
                channel.current(control = kind == 1)
                val deadline = timer.schedule({ channel.withdraw() }, 5, TimeUnit.SECONDS)
                try {
                    DeviceLinkFrames.write(channel.socket.outputStream, DeviceLinkFrame(kind, payload))
                    channel.current(control = kind == 1)
                } finally { deadline.cancel(false) }
            }
        } catch (error: Exception) {
            channel.withdraw()
            throw error
        } finally { channel.queued.decrementAndGet() }
    }

    fun peerClosed(id: String): Boolean {
        val channel = channel(id)
        if (!channel.reading.compareAndSet(false, true)) throw DeviceLinkFailure("resource_limit")
        try {
            channel.current(control = true)
            channel.socket.soTimeout = 5000
            val ended = channel.socket.inputStream.read() == -1
            channel.current(control = true)
            return ended
        } finally { channel.reading.set(false) }
    }

    fun closeChannel(id: String) {
        val original = channel(id)
        original.withdraw()
        if (!original.settled.await(5, TimeUnit.SECONDS) || original.failed || failed)
            throw DeviceLinkFailure("settlement_unknown")
        original.joinIo()
        synchronized(channels) { channels.remove(id) }
    }

    /** Synchronous invalidation is safe from Activity/network callbacks. */
    fun withdraw() {
        closed = true
        listenerClose.request()
        synchronized(channels) { channels.values.toList() }.forEach { it.beginClosing() }
    }

    fun close() {
        withdraw()
        workers.shutdown()
        if (!workers.awaitTermination(6, TimeUnit.SECONDS)) {
            failed = true
            synchronized(channels) { channels.values.toList() }.forEach { it.withdraw() }
        }
        timer.shutdownNow()
        if (!timer.awaitTermination(6, TimeUnit.SECONDS)) failed = true
        try { listenerClose.join() } catch (_: Exception) { failed = true }
        endpointClose.request()
        try { endpointClose.join() } catch (_: Exception) { failed = true }
        // Keep this executor alive until every original accept worker has
        // joined, including a channel racing the admission withdrawal.
        closer.shutdown()
        if (!closer.awaitTermination(6, TimeUnit.SECONDS)) failed = true
        synchronized(channels) { channels.values.toList() }.forEach { it.joinIo() }
        if (failed) throw DeviceLinkFailure("settlement_unknown")
    }
    fun requireReleased() {
        if (!closed || failed || synchronized(channels) { channels.isNotEmpty() })
            throw DeviceLinkFailure("settlement_unknown")
    }

    private inner class Channel(val socket: SSLSocket, val peer: String) {
        val id = UUID.randomUUID().toString()
        val stopped = CountDownLatch(1)
        val settled = CountDownLatch(1)
        val reading = AtomicBoolean()
        val queued = java.util.concurrent.atomic.AtomicInteger()
        val writer = Any()
        private val certificateExpires = minOf(keys.certificate().notAfter.time,
            (socket.session.peerCertificates.single() as java.security.cert.X509Certificate).notAfter.time)
        private val certificateEnds = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(
            (certificateExpires - System.currentTimeMillis()).coerceAtLeast(0))
        @Volatile var closed = false
        @Volatile var closeControl = false
        private val closing = DeviceCloseDeadline()
        private var closingDeadline: java.util.concurrent.ScheduledFuture<*>? = null
        val failed: Boolean get() = closeWork.failed
        val closeWork = DeviceCloseWork(closer) {
            try { socket.close() } finally { stopped.countDown() }
        }
        var establishment: java.util.concurrent.ScheduledFuture<*>? = null
        @Volatile var proofEnds = Long.MAX_VALUE
        var proofDeadline: java.util.concurrent.ScheduledFuture<*>? = null
        @Synchronized fun established(closeControl: Boolean, keepWhileLocked: Boolean) {
            current()
            // Serialize pinning with original withdrawal. A channel that was
            // already closed cannot become the retained lock-screen channel.
            if (keepWhileLocked) gate.retainAuthenticatedChannel(epoch, network, id)
            this.closeControl = closeControl
            establishment?.cancel(false)
        }
        @Synchronized fun current(control: Boolean = false) {
            if (closeControl && (this@DeviceNativeLink.closed || !gate.current(epoch, network, id))) beginClosing()
            if (closing.started) {
                if (closed || !closeControl) throw DeviceLinkFailure("connection_closed")
                closing.requireControl(control)
                return
            }
            if (closed || this@DeviceNativeLink.closed || !gate.current(epoch, network, id) ||
                admissionExpired() ||
                System.nanoTime() >= proofEnds ||
                System.currentTimeMillis() >= certificateExpires || System.nanoTime() >= certificateEnds)
                throw DeviceLinkFailure("connection_closed")
        }
        @Synchronized fun beginClosing() {
            if (closed || closing.started) return
            if (!closeControl) {
                withdraw()
                return
            }
            closing.begin()
            closingDeadline = timer.schedule({ withdraw() }, 5, TimeUnit.SECONDS)
        }
        @Synchronized fun withdraw() {
            closed = true
            gate.releaseChannel(id)
            establishment?.cancel(false)
            proofDeadline?.cancel(false)
            closingDeadline?.cancel(false)
            closeWork.request()
        }
        fun joinIo() {
            val ends = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (reading.get() || queued.get() != 0) {
                if (System.nanoTime() >= ends) throw DeviceLinkFailure("settlement_unknown")
                // This is an original-owner drain, never a reconnect/retry loop.
                Thread.sleep(1)
            }
            if (failed) throw DeviceLinkFailure("settlement_unknown")
        }
    }
}
