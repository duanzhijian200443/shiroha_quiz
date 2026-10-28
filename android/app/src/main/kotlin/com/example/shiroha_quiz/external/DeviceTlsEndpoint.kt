package com.example.shiroha_quiz.external

import java.net.InetAddress
import java.net.InetSocketAddress
import java.security.AlgorithmParameters
import java.security.Principal
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.*

/** Dormant raw endpoint. Business admission is intentionally absent in this delivery. */
internal class DeviceTlsEndpoint(private val keys: DeviceCredentials, private val gate: DeviceForegroundGate) {
    private var listener: SSLServerSocket? = null
    private var peer: SSLSocket? = null
    private var closed = false

    @Synchronized fun listen(address: InetAddress, expectedClient: String, epoch: Long, network: String): Int {
        DeviceLinkAdmission.requireAuthorized()
        if (closed || listener != null || !gate.current(epoch, network) || !address.isSiteLocalAddress ||
            address.address.size != 4 || address.isAnyLocalAddress) throw DeviceLinkFailure("foreground_required")
        keys.installationId()
        val manager = object : X509ExtendedKeyManager() {
            override fun getPrivateKey(alias: String?): PrivateKey? = if (alias == "device") keys.privateKey() else null
            override fun getCertificateChain(alias: String?): Array<X509Certificate>? = if (alias == "device") arrayOf(keys.certificate()) else null
            override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null
            override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: java.net.Socket?): String? = null
            override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = if (keyType == "EC") arrayOf("device") else null
            override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: java.net.Socket?): String? = if (keyType == "EC") "device" else null
        }
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>?, authType: String?) = DevicePeerPolicy.check(chain, expectedClient, true)
            override fun checkServerTrusted(chain: Array<X509Certificate>?, authType: String?) { throw DeviceLinkFailure("credential_rejected") }
        }
        val tls = SSLContext.getInstance("TLSv1.3")
        tls.init(arrayOf(manager), arrayOf(trust), null)
        val socket = tls.serverSocketFactory.createServerSocket() as SSLServerSocket
        try {
            socket.enabledProtocols = arrayOf("TLSv1.3")
            socket.needClientAuth = true
            socket.soTimeout = 5000
            socket.bind(InetSocketAddress(address, 0), 2)
            listener = socket
            return socket.localPort
        } catch (_: Exception) { socket.close(); throw DeviceLinkFailure("unavailable") }
    }

    /** Joins the same accepted socket; never creates Application evidence from JSON. */
    fun acceptProof(epoch: Long, network: String, expectedClient: String): String {
        DeviceLinkAdmission.requireAuthorized()
        val server = synchronized(this) {
            if (closed || peer != null || !gate.current(epoch, network)) throw DeviceLinkFailure("unavailable")
            listener ?: throw DeviceLinkFailure("unavailable")
        }
        val socket = server.accept() as SSLSocket
        val timer = Executors.newSingleThreadScheduledExecutor()
        val deadline = timer.schedule({ try { socket.close() } catch (_: Exception) {} }, 5, TimeUnit.SECONDS)
        try {
            synchronized(this) {
                if (closed || peer != null || !gate.current(epoch, network)) throw DeviceLinkFailure("foreground_required")
                peer = socket
            }
            socket.soTimeout = 5000
            socket.startHandshake()
            val chain = socket.session.peerCertificates.map { it as X509Certificate }.toTypedArray()
            DevicePeerPolicy.check(chain, expectedClient, true)
            if (socket.session.protocol != "TLSv1.3" || !gate.current(epoch, network)) throw DeviceLinkFailure("credential_rejected")
            // Safe observation only. P15 integration and business routes are a later task.
            return DeviceCredentials.digest(chain.single().encoded)
        } catch (e: DeviceLinkFailure) { throw e }
          catch (_: Exception) { throw DeviceLinkFailure("credential_rejected") }
          finally {
            deadline.cancel(false)
            timer.shutdownNow()
            socket.close()
            synchronized(this) { peer = null }
        }
    }

    @Synchronized fun close() {
        closed = true
        try { peer?.close() } finally { listener?.close() }
    }
}
