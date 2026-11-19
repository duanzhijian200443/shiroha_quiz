package com.example.shiroha_quiz.external

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/** JVM-only synthetic fixture. No Android class, key, file, socket or App use. */
fun main(args: Array<String>) {
    var count = 0
    fun accepts(value: Boolean) { check(value); count++ }
    fun rejects(work: () -> Unit) {
        try { work() } catch (_: DeviceLinkFailure) { count++; return }
        error("expected_rejection")
    }
    accepts(!DeviceLinkAdmission.runtimeAvailable)
    rejects { DeviceLinkAdmission.requireAuthorized() }
    var closeTime = 0L
    val closeDeadline = DeviceCloseDeadline { closeTime }
    accepts(closeDeadline.remainingNanos() == 0L)
    rejects { closeDeadline.requireControl(true) }
    accepts(closeDeadline.begin())
    accepts(closeDeadline.remainingNanos() == 5_000_000_000L)
    closeDeadline.requireControl(true)
    rejects { closeDeadline.requireControl(false) }
    closeTime = 4_000_000_000
    accepts(!closeDeadline.begin())
    accepts(closeDeadline.remainingNanos() == 1_000_000_000L)
    closeDeadline.requireControl(true)
    closeTime = 5_000_000_000
    accepts(closeDeadline.remainingNanos() == 0L)
    rejects { closeDeadline.requireControl(true) }
    for (readFirst in listOf(true, false)) {
        val trace = DeviceProfile2CloseTrace()
        val withdrawal = DeviceProfile2CloseTrace.Mark.withdrawal
        val stage = DeviceProfile2CloseTrace.ReadStage.frame
        if (!readFirst) trace.mark(withdrawal)
        trace.readFailed(stage, java.net.SocketException("unsanitized-message"))
        trace.mark(withdrawal)
        trace.mark(DeviceProfile2CloseTrace.Mark.closeCall)
        trace.mark(DeviceProfile2CloseTrace.Mark.socketCloseRequested)
        trace.mark(DeviceProfile2CloseTrace.Mark.socketCloseStarted)
        trace.readFailed(DeviceProfile2CloseTrace.ReadStage.afterFrame, DeviceLinkFailure("connection_closed"))
        accepts(trace.snapshot() == mapOf(
            "withdrawal" to if (readFirst) 2 else 1,
            "readFailure" to if (readFirst) 1 else 2,
            "closeCall" to 3, "socketCloseRequested" to 4, "socketCloseStarted" to 5,
            "readStage" to "frame", "readError" to "socket"
        ))
    }
    val closeExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    try {
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val caller = Thread.currentThread()
        val calls = java.util.concurrent.atomic.AtomicInteger()
        val close = DeviceCloseWork(closeExecutor) {
            check(Thread.currentThread() !== caller)
            calls.incrementAndGet()
            entered.countDown()
            release.await()
        }
        close.request()
        accepts(entered.await(1, java.util.concurrent.TimeUnit.SECONDS))
        repeat(8) { close.request() }
        accepts(calls.get() == 1)
        val joined = java.util.concurrent.CompletableFuture.runAsync { close.join() }
        accepts(!joined.isDone)
        release.countDown()
        joined.get(2, java.util.concurrent.TimeUnit.SECONDS)
        close.join()
        accepts(calls.get() == 1 && !close.failed)
        val failedClose = DeviceCloseWork(closeExecutor) { throw java.io.IOException() }
        rejects { failedClose.join() }
        rejects { failedClose.join() }
    } finally { closeExecutor.shutdownNow() }
    // Exercise the exact Debug Activity owner, not only the shared close primitive.
    // A lifecycle withdrawal before endpoint acquisition must retain the late close.
    val proofOwner = DeviceProofCloseOwner()
    proofOwner.request()
    val proofEntered = java.util.concurrent.CountDownLatch(1)
    val proofRelease = java.util.concurrent.CountDownLatch(1)
    val proofCalls = java.util.concurrent.atomic.AtomicInteger()
    val proofCaller = Thread.currentThread()
    proofOwner.adopt {
        check(Thread.currentThread() !== proofCaller)
        proofCalls.incrementAndGet()
        proofEntered.countDown()
        proofRelease.await()
    }
    try {
        accepts(proofEntered.await(1, java.util.concurrent.TimeUnit.SECONDS))
        // Repeated lifecycle callbacks return while the original close is blocked.
        repeat(8) { proofOwner.request() }
        val proofJoined = java.util.concurrent.CompletableFuture.runAsync { proofOwner.settle() }
        try {
            proofJoined.get(100, java.util.concurrent.TimeUnit.MILLISECONDS)
            error("released_before_original_close")
        } catch (_: java.util.concurrent.TimeoutException) { accepts(true) }
        proofRelease.countDown()
        proofJoined.get(2, java.util.concurrent.TimeUnit.SECONDS)
        proofOwner.settle()
        accepts(proofCalls.get() == 1)
    } finally { proofRelease.countDown() }
    val failedProof = DeviceProofCloseOwner()
    failedProof.adopt { throw java.io.IOException() }
    failedProof.request()
    rejects { failedProof.settle() }
    rejects { failedProof.settle() }
    // Preparation failed before any endpoint existed: no close or worker to leak.
    DeviceProofCloseOwner().settle()
    val gate = DeviceForegroundGate()
    val first = gate.observe(true, true, true, true, "wifi-1")
    accepts(gate.current(first, "wifi-1"))
    accepts(gate.observe(true, true, true, true, "wifi-1") == first)
    accepts(gate.current(first, "wifi-1"))
    accepts(!gate.current(first, "wifi-2"))
    gate.observe(true, false, true, true, "wifi-1")
    accepts(!gate.current(first, "wifi-1"))
    val again = gate.observe(true, true, true, true, "wifi-1")
    accepts(gate.current(again, "wifi-1"))
    accepts(!gate.current(first, "wifi-1"))
    gate.close()
    val late = gate.observe(true, true, true, true, "wifi-1")
    accepts(!gate.current(late, "wifi-1"))
    var backgroundNow = 1L
    var screenSafe = true
    var supported = true
    fun backgroundGate(): Pair<DeviceForegroundGate, Long> {
        val background = DeviceForegroundGate({ backgroundNow }, { screenSafe })
        val epoch = background.observe(true, true, true, true, "wifi-1")
        background.allowBackground(100) { supported }
        return Pair(background, epoch)
    }
    val (background, epoch) = backgroundGate()
    background.observe(false, false, true, true, "wifi-1")
    accepts(background.backgroundRead && !background.eligible)
    accepts(background.current(epoch, "wifi-1"))
    accepts(background.sequence == epoch)
    background.observe(true, true, true, true, "wifi-1")
    accepts(background.current(epoch, "wifi-1"))
    backgroundNow = 100
    accepts(!background.current(epoch, "wifi-1"))
    accepts(!background.backgroundRead)
    backgroundNow = 1
    for (reason in listOf("lock", "network", "support", "physical-screen", "close")) {
        val (original, originalEpoch) = backgroundGate()
        when(reason) {
            "lock" -> original.observe(false, false, true, false, "wifi-1")
            "network" -> original.observe(false, false, true, true, "wifi-2")
            "support" -> supported = false
            "physical-screen" -> screenSafe = false
            "close" -> original.close()
        }
        accepts(!original.current(originalEpoch, "wifi-1"))
        supported = true; screenSafe = true
        original.observe(true, true, true, true, "wifi-1")
        accepts(!original.current(originalEpoch, "wifi-1"))
    }
    val denied = DeviceForegroundGate({ backgroundNow })
    denied.observe(false, false, true, true, "wifi-1")
    rejects { denied.allowBackground(100) { true } }
    denied.observe(true, true, true, true, "wifi-1")
    rejects { denied.allowBackground(100) { false } }
    rejects { denied.allowBackground(1) { true } }
    val unknownSupport = DeviceForegroundGate({ backgroundNow })
    val unknownEpoch = unknownSupport.observe(true, true, true, true, "wifi-1")
    var diagnosticKnown = true
    unknownSupport.allowBackground(100) { if (!diagnosticKnown) error("synthetic") else true }
    diagnosticKnown = false
    accepts(!unknownSupport.current(unknownEpoch, "wifi-1"))
    var lockScreen: Boolean? = true
    fun lockContinuation(bind: Boolean = true): Pair<DeviceForegroundGate, Long> {
        lockScreen = true
        backgroundNow = 1
        supported = true
        val candidate = DeviceForegroundGate({ backgroundNow }, { lockScreen })
        val ownerEpoch = candidate.observe(true, true, true, true, "wifi-1")
        candidate.allowBackground(100, keepWhileLocked = true) { supported }
        if (bind) candidate.retainAuthenticatedChannel(ownerEpoch, "wifi-1", "original")
        return candidate to ownerEpoch
    }
    val (locked, lockedEpoch) = lockContinuation()
    lockScreen = false
    // The synchronous socket gate sees the lock even before the observer does.
    accepts(locked.current(lockedEpoch, "wifi-1", "original"))
    accepts(!locked.current(lockedEpoch, "wifi-1"))
    accepts(!locked.current(lockedEpoch, "wifi-1", "replacement"))
    rejects { locked.retainAuthenticatedChannel(lockedEpoch, "wifi-1", "late") }
    accepts(locked.observe(false, false, false, false, "wifi-1") == lockedEpoch)
    accepts(locked.listenerCurrent(lockedEpoch, "wifi-1"))
    locked.releaseChannel("replacement")
    accepts(locked.current(lockedEpoch, "wifi-1", "original"))
    locked.releaseChannel("original")
    accepts(!locked.backgroundRead)
    lockScreen = true
    locked.observe(true, true, true, true, "wifi-1")
    accepts(!locked.current(lockedEpoch, "wifi-1", "original"))

    for (keepLocked in listOf(false, true)) {
        backgroundNow = 1
        lockScreen = true
        val runtime = DeviceForegroundGate({ backgroundNow }, { lockScreen })
        val ownerEpoch = runtime.observe(true, true, true, true, "wifi-1")
        runtime.allowBackground(null, keepWhileLocked = keepLocked) { supported }
        if (keepLocked) runtime.retainAuthenticatedChannel(ownerEpoch, "wifi-1", "original")
        backgroundNow += 172800000
        runtime.observe(false, false, true, true, "wifi-1")
        accepts(runtime.current(ownerEpoch, "wifi-1"))
        lockScreen = false
        accepts(!runtime.current(ownerEpoch, "wifi-1"))
        accepts(runtime.current(ownerEpoch, "wifi-1", "original") == keepLocked)
        runtime.withdrawBackground()
        lockScreen = true
        runtime.observe(true, true, true, true, "wifi-1")
        accepts(!runtime.current(ownerEpoch, "wifi-1", "original"))
    }

    val (pendingLock, pendingEpoch) = lockContinuation(bind = false)
    lockScreen = false
    accepts(!pendingLock.current(pendingEpoch, "wifi-1"))
    rejects { pendingLock.retainAuthenticatedChannel(pendingEpoch, "wifi-1", "late") }
    for (trigger in listOf("expiry", "network", "support", "unobserved-screen", "stop")) {
        val (original, ownerEpoch) = lockContinuation()
        lockScreen = false
        when (trigger) {
            "expiry" -> backgroundNow = 100
            "network" -> original.observe(false, false, false, false, "wifi-2")
            "support" -> supported = false
            "unobserved-screen" -> lockScreen = null
            "stop" -> original.withdrawBackground()
        }
        accepts(!original.current(ownerEpoch, "wifi-1", "original"))
        accepts(!original.backgroundRead)
    }
    // The service's callback custody is JVM-only; no Service is instantiated.
    val serviceCustody = DeviceReadService.Session({}, {})
    val serviceResults = mutableListOf<Boolean>()
    serviceCustody.stopped.add { serviceResults.add(it) }
    serviceCustody.settled(false)
    accepts(serviceCustody.stopFailed && serviceResults == listOf(false))
    serviceCustody.settled(true) // Late platform destruction cannot erase timeout.
    accepts(serviceCustody.stopFailed && serviceResults == listOf(false))
    diagnosticKnown = true
    accepts(!unknownSupport.current(unknownEpoch, "wifi-1"))
    val out = ByteArrayOutputStream()
    DeviceLinkFrames.write(out, DeviceLinkFrame(1, "{}".toByteArray()))
    val frame = DeviceLinkFrames.read(ByteArrayInputStream(out.toByteArray()))
    accepts(frame.kind == 1 && frame.payload.contentEquals("{}".toByteArray()))
    var elapsed = 0L
    val timeouts = mutableListOf<Int>()
    val idleInput = object : ByteArrayInputStream(out.toByteArray()) {
        override fun read(): Int { elapsed += 3000000000; return super.read() }
    }
    accepts(DeviceLinkFrames.readTimed(idleInput, { timeouts.add(it) }, { elapsed }).kind == 1)
    accepts(timeouts == listOf(0, 2000, 10000))
    elapsed = 0
    val fragmented = object : ByteArrayInputStream(out.toByteArray()) {
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            elapsed += 600000000
            return super.read(bytes, offset, 1)
        }
    }
    rejects { DeviceLinkFrames.readTimed(fragmented, {}, { elapsed }) }
    val header = out.toByteArray().copyOfRange(0, 12)
    header[4] = 2
    rejects { DeviceLinkFrames.length(header, false) }
    header[4] = 1; header[6] = 1
    rejects { DeviceLinkFrames.length(header, false) }
    header[6] = 0
    ByteBuffer.wrap(header, 8, 4).putInt(-1)
    rejects { DeviceLinkFrames.length(header, false) }
    ByteBuffer.wrap(header, 8, 4).putInt(0)
    rejects { DeviceLinkFrames.length(header, false) }
    rejects { DeviceLinkFrames.read(ByteArrayInputStream(byteArrayOf(83, 72))) }
    rejects { DeviceLinkFrames.write(ByteArrayOutputStream(), DeviceLinkFrame(1, byteArrayOf(0xc0.toByte(), 0x80.toByte()))) }
    ByteBuffer.wrap(header, 8, 4).putInt(DeviceLinkFrames.CONTROL_MAX + 1)
    rejects { DeviceLinkFrames.read(ByteArrayInputStream(header)) }
    // Reads only the explicit repository-owned public fixture, never credentials.
    val json = java.io.File(args.single()).readText()
    fun value(name: String): String = Regex("\"$name\"\\s*:\\s*\"([^\"]+)\"").find(json)!!.groupValues[1]
    fun bytes(hex: String): ByteArray = hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    fun certificate(name: String): java.security.cert.X509Certificate =
        java.security.cert.CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(bytes(value(name)))) as java.security.cert.X509Certificate
    val now = java.util.Date.from(java.time.Instant.parse("2026-10-28T00:00:00Z"))
    val server = certificate("server")
    DevicePeerPolicy.check(arrayOf(server), value("serverDigest"), false, now)
    accepts(true)
    rejects { DevicePeerPolicy.check(arrayOf(server), "0".repeat(64), false, now) }
    rejects { DevicePeerPolicy.check(arrayOf(server), value("serverDigest"), true, now) }
    rejects { DevicePeerPolicy.check(arrayOf(certificate("client")), value("clientDigest"), false, now) }
    rejects { DevicePeerPolicy.check(arrayOf(certificate("expired")), value("expiredDigest"), false, now) }
    rejects { DevicePeerPolicy.check(arrayOf(server, server), value("serverDigest"), false, now) }
    println("PASS: $count JVM synthetic checks; public certificates only; no Android runtime or network")
}
