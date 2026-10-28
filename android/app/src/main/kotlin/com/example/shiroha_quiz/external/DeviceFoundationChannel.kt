package com.example.shiroha_quiz.external

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Explicit, unregistered platform adapter. MainActivity does not install it. */
internal class DeviceFoundationChannel(context: Context) : MethodChannel.MethodCallHandler {
    private val credentials = DeviceCredentials(context)
    private val associations = DeviceAssociationFile(context, credentials)
    private var nextLease = 0L
    private var activeToken = 0L
    private var lease: DeviceAssociationFile.Lease? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "status") {
            result.success(mapOf("runtimeAvailable" to DeviceLinkAdmission.runtimeAvailable))
            return
        }
        try {
            DeviceLinkAdmission.requireAuthorized()
            when (call.method) {
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

    private fun requireLease(call: MethodCall): DeviceAssociationFile.Lease {
        val token = call.argument<Number>("lease")?.toLong()
        if (token != activeToken) throw DeviceLinkFailure("stale_revision")
        return lease ?: throw DeviceLinkFailure("stale_revision")
    }
}
