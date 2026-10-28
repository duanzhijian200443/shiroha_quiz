package com.example.shiroha_quiz.external

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.PowerManager

/** Dormant observation adapter. No receiver, Service or background task is registered. */
internal class DeviceForegroundObserver(private val activity: Activity,
                                        private val gate: DeviceForegroundGate,
                                        private val changed: ((Map<String, Any?>) -> Unit)? = null,
                                        private var flutterResumed: Boolean = true) {
    private var resumed = false
    private var focused = false
    private var visible = false
    private var observationSequence = 0L
    fun onStart() { visible = true; publish() }
    fun onResume() { resumed = true; publish() }
    fun onPause() { resumed = false; publish() }
    fun onWindowFocusChanged(value: Boolean) { focused = value; publish() }
    fun onStop() { visible = false; resumed = false; focused = false; publish() }
    fun onFlutterResumed(value: Boolean) { flutterResumed = value; publish() }

    fun publish() {
        val power = activity.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        val connectivity = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val network = connectivity?.activeNetwork
        val capabilities = network?.let { connectivity.getNetworkCapabilities(it) }
        val wifi = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
            !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        val address = network?.let { connectivity.getLinkProperties(it) }?.linkAddresses
            ?.map { it.address }?.firstOrNull { it.address.size == 4 && it.isSiteLocalAddress }
        val networkId = if (wifi && address != null) "$network/${address.hostAddress}" else null
        val interactive = power?.isInteractive == true
        val unlocked = keyguard?.isKeyguardLocked == false
        gate.observe(resumed && flutterResumed, focused, interactive, unlocked, networkId)
        changed?.invoke(mapOf("sequence" to ++observationSequence,
            "elapsedMs" to android.os.SystemClock.elapsedRealtime(),
            "resumed" to (resumed && flutterResumed), "focused" to focused,
            "interactive" to interactive, "unlocked" to unlocked,
            "visible" to visible, "network" to networkId,
            "address" to if (wifi) address?.hostAddress else null))
    }
}
