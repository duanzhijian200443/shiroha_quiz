package com.example.shiroha_quiz

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.example.shiroha_quiz.external.DeviceFoundationChannel
import com.example.shiroha_quiz.external.DeviceLinkAdmission
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.LinkProperties
import android.os.Build

class MainActivity : FlutterActivity() {
    private var device: DeviceFoundationChannel? = null
    private var connectivity: ConnectivityManager? = null
    private val network = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = observe()
        override fun onLost(network: Network) = observe()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = observe()
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = observe()
    }
    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = observe()
    }
    private fun observe() { runOnUiThread { device?.observer?.publish() } }
    private fun requireAndroidReadAdmission() {
        if (!BuildConfig.DEBUG || !BuildConfig.ANDROID_READ_VALIDATION || Build.VERSION.SDK_INT < 29 ||
            packageName != "com.example.shiroha_quiz.androidread" || isFinishing || isDestroyed)
            DeviceLinkAdmission.requireAuthorized()
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!BuildConfig.DEBUG || !BuildConfig.ANDROID_READ_VALIDATION || Build.VERSION.SDK_INT < 29 ||
            packageName != "com.example.shiroha_quiz.androidread") return
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiroha/android_device_foundation")
        device = DeviceFoundationChannel(this, channel, ::requireAndroidReadAdmission)
        channel.setMethodCallHandler(device)
        connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        connectivity?.registerDefaultNetworkCallback(network)
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_USER_PRESENT)
        }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screen, filter, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(screen, filter)
    }
    override fun onStart() { super.onStart(); device?.observer?.onStart() }
    override fun onResume() { super.onResume(); device?.observer?.onResume() }
    override fun onPause() { device?.observer?.onPause(); super.onPause() }
    override fun onStop() { device?.observer?.onStop(); super.onStop() }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus); device?.observer?.onWindowFocusChanged(hasFocus)
    }
    override fun onDestroy() {
        if (device != null) {
            connectivity?.unregisterNetworkCallback(network); unregisterReceiver(screen)
            device?.dispose()
        }
        super.onDestroy()
    }
}
