package com.example.shiroha_quiz.external

import android.content.Context
import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.os.PowerManager
import android.app.KeyguardManager
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Platform adapter installed only by MainActivity's explicit READ admission. */
internal class DeviceFoundationChannel(private val context: Context,
    private val channel: MethodChannel? = null,
    private val admission: () -> Unit = DeviceLinkAdmission::requireAuthorized) : MethodChannel.MethodCallHandler {
    private fun admitted() {
        if (disposed) throw DeviceLinkFailure("runtime_not_authorized")
        admission()
    }
    private var disposed = false
    private val credentials = DeviceCredentials(context, ::admitted)
    private val associations = DeviceAssociationFile(context, credentials)
    private val gate = DeviceForegroundGate({ android.os.SystemClock.elapsedRealtime() }, {
        (context.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.isInteractive == true &&
            (context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)?.isKeyguardLocked == false
    })
    private val main = Handler(Looper.getMainLooper())
    private val io = java.util.concurrent.ThreadPoolExecutor(4, 4, 0,
        java.util.concurrent.TimeUnit.SECONDS, java.util.concurrent.ArrayBlockingQueue(8))
    private val control = java.util.concurrent.Executors.newSingleThreadExecutor()
    @Volatile private var link: DeviceNativeLink? = null
    private var observation: Map<String, Any?> = emptyMap()
    val observer = (context as? Activity)?.let { DeviceForegroundObserver(it, gate, { next ->
        observation = next
        if ((!gate.eligible && !gate.backgroundRead) || (link != null && next["network"] != originalNetwork)) link?.withdraw()
        finishNotificationPreparation()
        emit("foreground", next)
    }, flutterResumed = false) }
    private var originalNetwork: String? = null
    private var nextLease = 0L
    private var activeToken = 0L
    private var lease: DeviceAssociationFile.Lease? = null
    @Volatile private var readSession: DeviceReadService.Session? = null
    private var notificationResult: MethodChannel.Result? = null
    private var permissionAnswered = false
    private val notificationTimeout = Runnable { failNotificationPreparation() }

    private fun failNotificationPreparation() {
        val result = notificationResult ?: return
        notificationResult = null
        main.removeCallbacks(notificationTimeout)
        readSession?.let { session -> DeviceReadService.finish(context, session) { settled ->
            if (settled && readSession === session) readSession = null
        } }
        result.error("background_read_unavailable", "background_read_unavailable", null)
    }
    private fun finishNotificationPreparation() {
        try { prepareNotificationService() } catch (_: Exception) { failNotificationPreparation() }
    }
    private fun prepareNotificationService() {
        if (!permissionAnswered || notificationResult == null) return
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            failNotificationPreparation(); return
        }
        // Permission dialogs temporarily remove focus. Wait for the ORIGINAL
        // Activity's real foreground observation, never manufacture it.
        if (!gate.eligible || readSession != null) return
        if (!DeviceReadService.notifications(context)) { failNotificationPreparation(); return }
        lateinit var session: DeviceReadService.Session
        session = DeviceReadService.Session({ success -> main.post {
            if (readSession !== session) return@post
            val result = notificationResult
            if (result != null && success && readSession?.running == true && gate.eligible) {
                notificationResult = null; main.removeCallbacks(notificationTimeout); result.success(true)
            } else failNotificationPreparation()
        } }, {
            if (readSession === session) {
                gate.withdrawBackground(); link?.withdraw()
                main.post {
                    if (readSession === session) channel?.invokeMethod("backgroundStopped", emptyMap<String, Any?>())
                }
            }
        })
        readSession = session
        try { DeviceReadService.start(context, session) } catch (_: Exception) { failNotificationPreparation() }
    }
    fun permissionResult(requestCode: Int) {
        if (requestCode == 46444) { permissionAnswered = true; observer?.publish() }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "backgroundWithdraw") {
            gate.withdrawBackground(); link?.withdraw()
            result.success(true); return
        }
        if (call.method == "backgroundPrepare") {
            try {
                admitted()
                if (!gate.eligible || notificationResult != null || readSession != null) throw DeviceLinkFailure("foreground_required")
                DeviceReadService.prepareNotifications(context)
                notificationResult = result
                main.postDelayed(notificationTimeout, 30000)
                permissionAnswered = Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                if (!permissionAnswered) (context as Activity).requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 46444)
                else finishNotificationPreparation()
            } catch (_: Exception) {
                if (notificationResult === result) failNotificationPreparation()
                else result.error("background_read_unavailable", "background_read_unavailable", null)
            }
            return
        }
        if (call.method == "backgroundStop") {
            gate.withdrawBackground(); link?.withdraw()
            failNotificationPreparation()
            val session = readSession
            if (session == null) result.success(true)
            else DeviceReadService.finish(context, session) { settled ->
                if (settled) { if (readSession === session) readSession = null; result.success(true) }
                else result.error("settlement_unknown", "settlement_unknown", null)
            }
            return
        }
        if (call.method == "status") {
            val available = try { admitted(); true } catch (_: Exception) { false }
            if (available) observer?.publish()
            result.success(mapOf("runtimeAvailable" to available, "observation" to observation))
            return
        }
        if (call.method == "flutterLifecycle") {
            observer?.onFlutterResumed(call.argument<Boolean>("resumed") == true)
            result.success(true); return
        }
        // linkClose joins channels on control; their original close must remain
        // runnable while that join is in progress.
        val executor = if (call.method in setOf("read", "write", "peerClosed", "channelClose")) io else control
        try { executor.execute { handle(call, object : MethodChannel.Result {
            override fun success(value: Any?) { main.post { result.success(value) } }
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
            if (call.method !in setOf("associationClose", "linkClose", "linkRelease", "channelClose")) admitted()
            when (call.method) {
                "identity" -> {
                    if (!gate.eligible) throw DeviceLinkFailure("foreground_required")
                    if (call.argument<Boolean>("initialize") == true) credentials.initialize()
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
                "linkEnabled" -> {
                    val original = requireOriginalLink(call)
                    original.completePreparation()
                    if (call.argument<Boolean>("backgroundRead") == true) {
                        val session = readSession ?: throw DeviceLinkFailure("background_read_unavailable")
                        gate.allowBackground(original.periodEndsMs) { session.running && !session.ended && DeviceReadService.runningNotification(context) }
                        session.service?.activated(original.periodEndsMs)
                        main.post { observer?.publish() }
                    }
                    result.success(true)
                }
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
    fun withdraw() { link?.withdraw() }
    fun dispose() {
        disposed = true; gate.close(); withdraw()
        failNotificationPreparation()
        readSession?.let { DeviceReadService.finish(context, it) }; readSession = null
        control.execute {
            try { link?.close(); lease?.close() } catch (_: Exception) { /* Retain failed custody until process exit. */ }
            io.shutdown(); control.shutdown()
        }
    }

    private fun requireLease(call: MethodCall): DeviceAssociationFile.Lease {
        val token = call.argument<Number>("lease")?.toLong()
        if (token != activeToken) throw DeviceLinkFailure("stale_revision")
        return lease ?: throw DeviceLinkFailure("stale_revision")
    }
}
