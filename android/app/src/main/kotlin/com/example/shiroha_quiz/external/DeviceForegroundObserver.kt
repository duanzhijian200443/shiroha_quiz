package com.example.shiroha_quiz.external

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.PowerManager

/** Dormant observation adapter. No receiver, Service or background task is registered. */
internal class DeviceForegroundObserver(private val activity: Activity,
                                        private val gate: DeviceForegroundGate) {
    private var resumed = false
    private var focused = false
    fun onResume() { resumed = true; publish() }
    fun onPause() { resumed = false; publish() }
    fun onWindowFocusChanged(value: Boolean) { focused = value; publish() }
    fun onStop() { resumed = false; focused = false; gate.close() }

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
        gate.observe(resumed, focused, power?.isInteractive == true,
            keyguard?.isKeyguardLocked == false,
            if (wifi && address != null) "$network/${address.hostAddress}" else null)
    }
}
