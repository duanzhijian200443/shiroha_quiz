package com.example.shiroha_quiz.external

import android.Manifest
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.app.Activity
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** App-owned local platform adapter with separate HTTP and legacy admission. */
internal class DeviceFoundationChannel(private val context: Context,
    private val channel: MethodChannel? = null,
    private val admission: () -> Unit = DeviceLinkAdmission::requireAuthorized,
    private val httpOnly: Boolean = false) : MethodChannel.MethodCallHandler {
    private fun admitted() {
        if (disposed) throw DeviceLinkFailure("runtime_not_authorized")
        admission()
    }
    @Volatile private var disposed = false
    private val credentials = DeviceCredentials(context, ::admitted)
    private val httpTls = DeviceHttpTlsStore(context, credentials)
    private val associations = DeviceAssociationFile(context, credentials, http = httpOnly)
    private val gate = DeviceForegroundGate()
    private val main = Handler(Looper.getMainLooper())
    private val io = java.util.concurrent.ThreadPoolExecutor(4, 4, 0,
        java.util.concurrent.TimeUnit.SECONDS, java.util.concurrent.ArrayBlockingQueue(8))
    private val control = java.util.concurrent.Executors.newSingleThreadExecutor()
    @Volatile private var link: DeviceNativeLink? = null
    @Volatile private var observation: Map<String, Any?> = emptyMap()
    val observer = (context as? Activity)?.let { DeviceForegroundObserver(it, gate, { next ->
        observation = if (httpOnly) next + mapOf(
            "backgroundRead" to DeviceReadService.backgroundRunning(context, readServiceSession),
            "notificationsAllowed" to DeviceReadService.notifications(context),
        ) else next
        if (!gate.eligible || (link != null && next["network"] != originalNetwork)) link?.withdraw()
        emit("foreground", observation)
    }, flutterResumed = false) }
    private var originalNetwork: String? = null
    private var nextLease = 0L
    private var activeToken = 0L
    private var lease: DeviceAssociationFile.Lease? = null
    // The control executor owns reservation, start, stop and disposal.
    @Volatile private var readServiceSession: DeviceReadService.Session? = null
    private var notificationRequested = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "legacyValidation") {
            result.success(!httpOnly && try { admitted(); true } catch (_: Exception) { false })
            return
        }
        if (call.method == "status") {
            val available = try { admitted(); true } catch (_: Exception) { false }
            if (available) observer?.publish()
            result.success(mapOf("runtimeAvailable" to available, "http" to httpOnly,
                "observation" to observation))
            return
        }
        if (call.method == "flutterLifecycle") {
            observer?.onFlutterResumed(call.argument<Boolean>("resumed") == true)
            result.success(true); return
        }
        if (httpOnly && call.method !in httpMethods) {
            result.error("runtime_not_authorized", "runtime_not_authorized", null)
            return
        }
        if (call.method == "httpNotificationSettings" || call.method == "httpCopyToken") {
            try {
                admitted()
                requireLocalForeground()
                if (call.method == "httpNotificationSettings") requestNotifications()
                else copyToken(call.argument<String>("token"))
                result.success(true)
            } catch (e: DeviceLinkFailure) {
                result.error(e.code, e.code, null)
            } catch (_: Exception) {
                result.error("runtime_not_authorized", "runtime_not_authorized", null)
            }
            return
        }
        // linkClose joins channels on control; their original close must remain
        // runnable while that join is in progress.
        val executor = if (call.method in setOf("read", "write", "peerClosed", "channelClose")) io else control
        try { executor.execute { handle(call, object : MethodChannel.Result {
            override fun success(value: Any?) {
                main.post {
                    try {
                        result.success(value)
                    } finally {
                        if (call.method == "httpLeafOpen") {
                            ((value as? Map<*, *>)?.get("leafPrivateKeyPkcs8") as? ByteArray)?.fill(0)
                        }
                    }
                }
            }
            override fun error(code: String, message: String?, details: Any?) { main.post { result.error(code, message, details) } }
            override fun notImplemented() { main.post { result.notImplemented() } }
        }) } } catch (_: java.util.concurrent.RejectedExecutionException) {
            result.error("resource_limit", "resource_limit", null)
        }
    }

    private fun emit(name: String, value: Map<String, Any?>) { main.post { channel?.invokeMethod(name, value) } }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            // Original-owner close remains available after admission withdrawal.
            if (call.method !in setOf(
                    "associationClose",
                    "linkClose",
                    "linkRelease",
                    "channelClose",
                    "readServiceStop"
                )
            ) admitted()
            when (call.method) {
                "identity" -> {
                    if (httpOnly) requireLocalForeground()
                    else if (!gate.eligible) throw DeviceLinkFailure("foreground_required")
                    if (call.argument<Boolean>("initialize") == true) credentials.initialize()
                    if (httpOnly) {
                        result.success(mapOf("deviceId" to credentials.deviceId(),
                            "installationId" to credentials.installationId()))
                        return
                    }
                    if (!credentials.tlsDigestAuthorized()) throw DeviceLinkFailure("recovery_required")
                    result.success(mapOf("deviceId" to credentials.deviceId(),
                        "installationId" to credentials.installationId(),
                        "certificateDigest" to DeviceCredentials.digest(credentials.certificate().encoded),
                        "expiresAt" to credentials.certificate().notAfter.time))
                }
                "linkOpen" -> {
                    if (link != null) throw DeviceLinkFailure("resource_limit")
                    val address = call.argument<String>("address") ?: throw DeviceLinkFailure("protocol_violation")
                    val enrollment = call.argument<Boolean>("enrollment") == true
                    val peer = call.argument<String>("peer")
                    if (enrollment != (peer == null)) throw DeviceLinkFailure("protocol_violation")
                    originalNetwork = gate.network
                    val opened = DeviceNativeLink(credentials, gate, address, peer, enrollment,
                        call.argument<Number>("periodEndsMs")?.toLong() ?: 0,
                        call.argument<Number>("preparationEndsMs")?.toLong() ?: 0,
                        call.argument<Boolean>("businessResume") == true, ::emit)
                    link = opened
                    result.success(mapOf("port" to opened.port, "link" to opened.id))
                }
                "attest" -> result.success(requireLink().attest(token(call),
                    call.argument<String>("peer") ?: "", call.argument<String>("installationId") ?: ""))
                "established" -> {
                    requireLink().established(token(call), call.argument<Boolean>("closeControl") == true)
                    result.success(true)
                }
                "proofStarted" -> { requireLink().proofStarted(token(call)); result.success(true) }
                "read" -> result.success(requireLink().read(token(call)))
                "peerClosed" -> result.success(requireLink().peerClosed(token(call)))
                "write" -> {
                    val payload = call.argument<ByteArray>("payload") ?: throw DeviceLinkFailure("protocol_violation")
                    try { requireLink().write(token(call), call.argument<Int>("kind") ?: 0, payload); result.success(true) }
                    finally { payload.fill(0) }
                }
                "channelClose" -> { requireLink().closeChannel(token(call)); result.success(true) }
                "linkClose" -> { requireOriginalLink(call).close(); result.success(true) }
                "linkEnabled" -> { requireOriginalLink(call).completePreparation(); result.success(true) }
                "linkRelease" -> {
                    requireOriginalLink(call).requireReleased()
                    link = null; originalNetwork = null; result.success(true)
                }
                "associationBegin" -> {
                    if (lease != null) throw DeviceLinkFailure("busy")
                    val opened = associations.begin()
                    lease = opened
                    activeToken = ++nextLease
                    result.success(mapOf("lease" to activeToken, "plaintext" to opened.plaintext()))
                }
                "associationCommit" -> {
                    val active = requireLease(call)
                    val bytes = call.argument<ByteArray>("plaintext") ?: throw DeviceLinkFailure("protocol_violation")
                    try { active.commit(bytes); result.success(true) } finally { bytes.fill(0) }
                }
                "associationClose" -> {
                    requireLease(call).close()
                    lease = null
                    result.success(true)
                }
                "httpCaEnsure" -> result.success(httpTls.ensureCaKey())
                "httpCaSignTbs" -> {
                    val tbs = call.argument<ByteArray>("tbs")
                        ?: throw DeviceLinkFailure("protocol_violation")
                    try {
                        result.success(httpTls.signTbsWithCa(tbs))
                    } finally {
                        tbs.fill(0)
                    }
                }
                "httpCaStore" -> {
                    val caDer = call.argument<ByteArray>("caDer")
                        ?: throw DeviceLinkFailure("protocol_violation")
                    httpTls.storeCaCertificate(caDer)
                    result.success(true)
                }
                "httpCaRead" -> result.success(httpTls.readCaCertificate())
                "httpLeafGenerateKey" -> result.success(httpTls.generateAndSealLeafKey())
                "httpLeafStore" -> {
                    val ipv4 = call.argument<String>("ipv4")
                        ?: throw DeviceLinkFailure("protocol_violation")
                    val expiresAtUtcMs = call.argument<Number>("expiresAtUtcMs")?.toLong() ?: 0L
                    val leafDer = call.argument<ByteArray>("leafDer")
                        ?: throw DeviceLinkFailure("protocol_violation")
                    httpTls.storeLeafCertificate(ipv4, expiresAtUtcMs, leafDer)
                    result.success(true)
                }
                "httpLeafOpen" -> result.success(httpTls.openLeafMaterial())
                "httpLeafDiscard" -> {
                    httpTls.discardPreparedLeaf()
                    result.success(true)
                }
                "readServiceStart" -> {
                    startReadService()
                    result.success(true)
                }
                "readServiceActivate" -> {
                    val ends = call.argument<Number>("endsElapsedMs")?.toLong()
                    val continueWhileLocked = call.argument<Boolean>("continueWhileLocked") == true
                    activateReadService(ends, continueWhileLocked)
                    result.success(true)
                }
                "readServiceStop" -> {
                    stopReadService()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: DeviceLinkFailure) { result.error(e.code, e.code, null) }
          catch (_: Exception) { result.error("credential_store_unavailable", "credential_store_unavailable", null) }
    }

    private fun requireLink() = link ?: throw DeviceLinkFailure("connection_closed")
    private fun requireOriginalLink(call: MethodCall): DeviceNativeLink {
        val original = requireLink()
        if (call.argument<String>("link") != original.id) throw DeviceLinkFailure("stale_revision")
        return original
    }
    private fun token(call: MethodCall) = call.argument<String>("channel") ?: throw DeviceLinkFailure("protocol_violation")

    private fun requireLocalForeground() {
        val current = observation
        if (!listOf("visible", "resumed", "focused", "interactive", "unlocked")
                .all { current[it] == true }
        ) throw DeviceLinkFailure("foreground_required")
    }

    private fun requestNotifications() {
        val activity = context as? Activity ?: throw DeviceLinkFailure("foreground_required")
        DeviceReadService.prepareNotifications(context)
        if (Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            (!notificationRequested ||
                activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))
        ) {
            notificationRequested = true
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 464)
        } else {
            activity.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName))
        }
    }

    private fun copyToken(token: String?) {
        if (token == null || !Regex("shq_[a-zA-Z0-9_-]{43}").matches(token)) {
            throw DeviceLinkFailure("protocol_violation")
        }
        val clip = ClipData.newPlainText("Shiroha MCP Token", token)
        clip.description.extras = PersistableBundle().apply {
            putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
        }
        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
    }

    private fun activateReadService(ends: Long?, continueWhileLocked: Boolean) {
        val session = readServiceSession ?: throw DeviceLinkFailure("connection_closed")
        val ready = java.util.concurrent.CountDownLatch(1)
        val activated = java.util.concurrent.atomic.AtomicBoolean(false)
        val posted = main.post {
            try {
                admitted()
                if (gate.eligible && session.service?.activate(ends, continueWhileLocked) == true) {
                    observer?.publish()
                    activated.set(true)
                }
            } catch (_: Exception) { /* The original owner still joins stop. */ }
            finally { ready.countDown() }
        }
        if (!posted || !ready.await(3, java.util.concurrent.TimeUnit.SECONDS) ||
            !activated.get() || !DeviceReadService.backgroundRunning(context, session)
        ) throw DeviceLinkFailure("notification_not_ready")
    }
    private fun startReadService() {
        if (!gate.eligible) throw DeviceLinkFailure("foreground_required")
        if (readServiceSession != null) throw DeviceLinkFailure("busy")
        val ready = java.util.concurrent.CountDownLatch(1)
        val readyOk = java.util.concurrent.atomic.AtomicBoolean(false)
        val session = DeviceReadService.Session(
            ready = { ok ->
                readyOk.set(ok)
                ready.countDown()
            },
            withdrawn = { emit("readServiceWithdrawn", mapOf("reason" to "service_stop")) },
        )
        readServiceSession = session
        try {
            // Service callbacks and global Service ownership are main-thread confined.
            val posted = main.post {
                try {
                    admitted()
                    if (!gate.eligible) throw DeviceLinkFailure("foreground_required")
                    DeviceReadService.prepareNotifications(context)
                    if (!DeviceReadService.notifications(context)) {
                        throw DeviceLinkFailure("notification_permission_required")
                    }
                    DeviceReadService.start(context, session)
                } catch (error: Exception) {
                    session.startFailure = (error as? DeviceLinkFailure)?.code ?: "service_start_failed"
                    session.ready(false)
                }
            }
            if (!posted || !ready.await(3, java.util.concurrent.TimeUnit.SECONDS) || !readyOk.get()) {
                throw DeviceLinkFailure(session.startFailure ?: "service_start_failed")
            }
            val limit = android.os.SystemClock.elapsedRealtime() + 1500
            while (!DeviceReadService.runningNotification(context) &&
                android.os.SystemClock.elapsedRealtime() < limit
            ) {
                admitted()
                Thread.sleep(25)
            }
            admitted()
            if (!gate.eligible) throw DeviceLinkFailure("foreground_required")
            if (!session.running || !DeviceReadService.runningNotification(context)) {
                throw DeviceLinkFailure("notification_not_ready")
            }
        } catch (error: Exception) {
            // Keep the original reservation if cleanup is uncertain.
            stopReadService()
            throw if (error is DeviceLinkFailure) error else DeviceLinkFailure("service_start_failed")
        }
    }

    private fun stopReadService() {
        val session = readServiceSession ?: return
        val stopped = java.util.concurrent.CountDownLatch(1)
        val clean = java.util.concurrent.atomic.AtomicBoolean(false)
        val posted = main.post {
            DeviceReadService.finish(context, session) { settled ->
                clean.set(settled)
                stopped.countDown()
            }
        }
        val finished = try {
            posted && stopped.await(6, java.util.concurrent.TimeUnit.SECONDS) && clean.get()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!finished) throw DeviceLinkFailure("commit_unknown")
        readServiceSession = null
    }

    fun withdraw() { link?.withdraw() }
    fun dispose() {
        disposed = true; gate.close(); withdraw()
        if (httpOnly) emit("readServiceWithdrawn", mapOf("reason" to "owner_closed"))
        control.execute {
            try { stopReadService() } catch (_: Exception) { /* Keep any unsettled Service owner. */ }
            httpTls.discardPreparedLeaf()
            try { link?.close(); lease?.close() } catch (_: Exception) { /* Retain failed custody until process exit. */ }
            io.shutdown(); control.shutdown()
        }
    }

    private fun requireLease(call: MethodCall): DeviceAssociationFile.Lease {
        val token = call.argument<Number>("lease")?.toLong()
        if (token != activeToken) throw DeviceLinkFailure("stale_revision")
        return lease ?: throw DeviceLinkFailure("stale_revision")
    }

    private companion object {
        val httpMethods = setOf(
            "identity", "associationBegin", "associationCommit", "associationClose",
            "httpCaEnsure", "httpCaSignTbs", "httpCaStore", "httpCaRead",
            "httpLeafGenerateKey", "httpLeafStore", "httpLeafOpen", "httpLeafDiscard",
            "readServiceStart", "readServiceActivate", "readServiceStop",
            "httpNotificationSettings", "httpCopyToken",
        )
    }
}
