package com.example.shiroha_quiz.external

import android.app.Activity
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.os.SystemClock
import android.util.AtomicFile
import android.widget.TextView
import com.example.shiroha_quiz.BuildConfig
import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/** Task-only proof of the SAME native implementation. No Flutter, P15 or database. */
class DeviceNativeProofActivity : Activity() {
    private val gate = DeviceForegroundGate()
    private lateinit var observer: DeviceForegroundObserver
    private lateinit var display: TextView
    private var operation: String? = null
    private var address: InetAddress? = null
    private var clientPin: String? = null
    private var initialize = false
    private var started = false
    private val withdrawn = AtomicBoolean(false)
    @Volatile private var endpoint: DeviceTlsEndpoint? = null
    @Volatile private var cleanupFailed = false
    private var deadline = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        display = TextView(this).apply { text = "Native validation: preparing"; textSize = 18f }
        setContentView(display)
        observer = DeviceForegroundObserver(this, gate)
        try {
            if (!BuildConfig.ANDROID_READ_VALIDATION ||
                packageName != "com.example.shiroha_quiz.androidread" ||
                applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0 ||
                android.os.Build.VERSION.SDK_INT < 29 || savedInstanceState != null) {
                throw DeviceLinkFailure("runtime_not_authorized")
            }
            val id = intent.getStringExtra("operation") ?: throw DeviceLinkFailure("protocol_violation")
            if (UUID.fromString(id).toString() != id) throw DeviceLinkFailure("protocol_violation")
            val host = intent.getStringExtra("address") ?: throw DeviceLinkFailure("protocol_violation")
            if (!Regex("[0-9]{1,3}(\\.[0-9]{1,3}){3}").matches(host)) throw DeviceLinkFailure("protocol_violation")
            val ip = InetAddress.getByName(host)
            if (ip.address.size != 4 || !ip.isSiteLocalAddress || ip.isAnyLocalAddress) {
                throw DeviceLinkFailure("protocol_violation")
            }
            val pin = intent.getStringExtra("clientPin") ?: throw DeviceLinkFailure("protocol_violation")
            if (!Regex("[0-9a-f]{64}").matches(pin)) throw DeviceLinkFailure("protocol_violation")
            operation = id
            address = ip
            clientPin = pin
            initialize = intent.getBooleanExtra("initialize", false)
            deadline = SystemClock.elapsedRealtime() + 120000
        } catch (_: Exception) {
            withdrawn.set(true)
            display.text = "Native validation: unavailable"
        }
    }

    override fun onResume() { super.onResume(); observer.onResume() }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!::observer.isInitialized) return
        observer.onWindowFocusChanged(hasFocus)
        if (!hasFocus && started) withdraw()
        if (hasFocus && !started && !withdrawn.get() && gate.eligible) begin()
    }
    override fun onPause() { observer.onPause(); withdraw(); super.onPause() }
    override fun onStop() { observer.onStop(); withdraw(); super.onStop() }
    override fun onDestroy() { withdraw(); super.onDestroy() }

    private fun withdraw() {
        withdrawn.set(true)
        try { endpoint?.close() } catch (_: Exception) { cleanupFailed = true }
        // The original worker retains the reservation until accept/late close settles.
    }

    private fun begin() {
        started = true
        val id = operation ?: return
        val ip = address ?: return
        val pin = clientPin ?: return
        val epoch = gate.sequence
        val network = gate.network ?: return
        if (!network.endsWith("/${ip.hostAddress}") || !reserve()) {
            display.text = "Native validation: unavailable"
            return
        }
        Thread({
            var result = "unavailable"
            var stage = "admission"
            var settled = false
            var nonExportable = false
            var tlsDigestAuthorized = false
            var installationStable = false
            var selected = 0
            try {
                fun requireAdmission() {
                    if (withdrawn.get() || SystemClock.elapsedRealtime() >= deadline ||
                        !gate.current(epoch, network)) throw DeviceLinkFailure("foreground_required")
                }
                val keys = DeviceCredentials(this, ::requireAdmission)
                requireAdmission()
                stage = "initialization"
                if (initialize) keys.initialize()
                stage = "identity"
                val installation = keys.installationId()
                val encoded = keys.privateKey().encoded
                if (encoded != null) { encoded.fill(0); throw DeviceLinkFailure("credential_rejected") }
                nonExportable = true
                tlsDigestAuthorized = keys.tlsDigestAuthorized()
                if (!tlsDigestAuthorized) throw DeviceLinkFailure("recovery_required")
                val native = DeviceTlsEndpoint(keys, gate)
                endpoint = native
                requireAdmission()
                stage = "listen"
                val port = native.listen(ip, pin, epoch, network)
                // Private local bootstrap material; never printed to diagnostics/model tools.
                publish(id, "bootstrap", JSONObject()
                    .put("operation", id).put("port", port)
                    .put("deviceId", keys.deviceId())
                    .put("certificateDigest", DeviceCredentials.digest(keys.certificate().encoded))
                    .put("installationId", installation))
                stage = "handshake"
                val actual = native.acceptProof(epoch, network, pin)
                requireAdmission()
                installationStable = keys.installationId() == installation
                if (actual != pin || !installationStable || native.keyManagerSelections == 0) {
                    throw DeviceLinkFailure("credential_rejected")
                }
                result = "accepted"
            } catch (failure: DeviceLinkFailure) {
                result = failure.code
            } catch (_: Exception) {
                result = if (withdrawn.get()) "foreground_required" else "unavailable"
            } finally {
                withdrawn.set(true)
                try { endpoint?.close() } catch (_: Exception) { cleanupFailed = true }
                selected = endpoint?.keyManagerSelections ?: 0
                settled = !cleanupFailed
                if (!settled) result = "settlement_unknown"
                try {
                    publish(id, "result", JSONObject()
                        .put("operation", id).put("result", result).put("stage", stage).put("settled", settled)
                        .put("nonExportable", nonExportable).put("installationStable", installationStable)
                        .put("tlsDigestAuthorized", tlsDigestAuthorized)
                        .put("keyManagerSelections", selected)
                        .put("peerPolicyAccepted", endpoint?.peerPolicyAccepted ?: false)
                        .put("peerPolicyAttempted", endpoint?.peerPolicyAttempted ?: false)
                        .put("peerPinMatched", endpoint?.peerPinMatched ?: false)
                        .put("acceptedSockets", endpoint?.acceptedSockets ?: 0)
                        .put("failureKinds", endpoint?.failureKinds ?: "none")
                        .put("observationCurrent", gate.current(epoch, network)))
                } catch (_: Exception) {
                    settled = false
                }
                release(settled)
                val safeResult = result
                runOnUiThread { display.text = "Native validation: $safeResult" }
            }
        }, "shiroha-native-proof").start()
    }

    private fun publish(id: String, kind: String, value: JSONObject) {
        val root = File(cacheDir, "native-proof-v1")
        if (!root.exists() && !root.mkdir()) throw DeviceLinkFailure("unavailable")
        val file = File(root, "$id.$kind.json")
        if (file.exists() || File(file.path + ".new").exists() || File(file.path + ".bak").exists()) {
            throw DeviceLinkFailure("unavailable")
        }
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try {
            stream.write(value.toString().toByteArray(Charsets.UTF_8))
            atomic.finishWrite(stream)
        } catch (_: Exception) {
            atomic.failWrite(stream)
            throw DeviceLinkFailure("unavailable")
        }
    }

    companion object {
        private var occupied = false
        private var failedSettlement = false
        @Synchronized private fun reserve(): Boolean {
            if (occupied || failedSettlement) return false
            occupied = true
            return true
        }
        @Synchronized private fun release(clean: Boolean) {
            if (!clean) failedSettlement = true
            // Failed settlement keeps the original reservation until process teardown.
            if (clean) occupied = false
        }
    }
}
