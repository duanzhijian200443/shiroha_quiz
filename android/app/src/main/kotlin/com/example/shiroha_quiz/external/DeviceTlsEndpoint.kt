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
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.*

/** Dormant raw endpoint. Business admission is intentionally absent in this delivery. */
internal class DeviceTlsEndpoint(private val keys: DeviceCredentials, private val gate: DeviceForegroundGate) {
    private var listener: SSLServerSocket? = null
    private var peer: SSLSocket? = null
    private var closed = false
    private var closeFailed = false
    private val keySelections = AtomicInteger()
    internal val keyManagerSelections: Int get() = keySelections.get()
    @Volatile internal var failureKinds: String = "none"; private set
    @Volatile internal var peerPolicyAccepted = false; private set
    @Volatile internal var peerPolicyAttempted = false; private set
    @Volatile internal var peerPinMatched = false; private set
    private val accepted = AtomicInteger()
    internal val acceptedSockets: Int get() = accepted.get()

    private fun observeFailure(error: Exception) {
        val kinds = mutableListOf<String>()
        var current: Throwable? = error
        while (current != null && kinds.size < 6) {
            kinds.add(when (current) {
                is DeviceLinkFailure -> current.code
                is SSLHandshakeException -> "tls_handshake"
                is SSLProtocolException -> "tls_protocol"
                is SSLException -> "tls"
                is java.security.InvalidKeyException -> "invalid_key"
                is java.security.SignatureException -> "signature"
                is java.security.ProviderException -> "provider"
                is java.security.cert.CertificateException -> "certificate"
                is java.net.SocketTimeoutException -> "timeout"
                is java.net.SocketException -> "socket"
                is java.io.IOException -> "io"
                else -> "native_failure"
            })
            current = current.cause
        }
        failureKinds = kinds.joinToString("/")
    }

    private fun failedClose(stage: String = "unknown") = synchronized(this) {
        closeFailed = true
        android.util.Log.w("AndroidDeviceClose", stage)
    }
    private fun closePeer(socket: SSLSocket) {
        try { socket.close() } catch (e: Exception) {
            failedClose(if (e is java.io.IOException) "peer-close-io" else "peer-close-native")
        }
    }

    @Synchronized fun listen(address: InetAddress, expectedClient: String?, epoch: Long, network: String,
                             port: Int = 0, enrollment: Boolean = false, acceptTimeout: Int = 5000): Int {
        keys.requireAuthorized()
        if (expectedClient == null && !enrollment) throw DeviceLinkFailure("credential_rejected")
        if (closed || listener != null || !gate.current(epoch, network) || !address.isSiteLocalAddress ||
            address.address.size != 4 || address.isAnyLocalAddress) throw DeviceLinkFailure("foreground_required")
        keys.installationId()
        // Existing incompatible keys require explicit recovery, never rotation.
        if (!keys.tlsDigestAuthorized()) throw DeviceLinkFailure("recovery_required")
        val manager = object : X509ExtendedKeyManager() {
            override fun getPrivateKey(alias: String?): PrivateKey? = if (alias == "device") {
                keySelections.incrementAndGet()
                keys.privateKey()
            } else null
            override fun getCertificateChain(alias: String?): Array<X509Certificate>? = if (alias == "device") arrayOf(keys.certificate()) else null
            override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null
            override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: java.net.Socket?): String? = null
            override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = if (keyType == "EC") arrayOf("device") else null
            override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: java.net.Socket?): String? = if (keyType == "EC") "device" else null
        }
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>?, authType: String?) {
                peerPolicyAttempted = true
                peerPinMatched = chain?.size == 1 && DeviceCredentials.digest(chain.single().encoded) == expectedClient
                // Enrollment validates possession/role/validity, not trust. Only
                // the original local confirmation + P15 may associate this leaf.
                val pin = expectedClient ?: chain?.singleOrNull()?.let { DeviceCredentials.digest(it.encoded) }
                    ?: throw DeviceLinkFailure("credential_rejected")
                DevicePeerPolicy.check(chain, pin, true)
                peerPolicyAccepted = true
            }
            override fun checkServerTrusted(chain: Array<X509Certificate>?, authType: String?) { throw DeviceLinkFailure("credential_rejected") }
        }
        val tls = SSLContext.getInstance("TLSv1.3")
        tls.init(arrayOf(manager), arrayOf(trust), null)
        val socket = tls.serverSocketFactory.createServerSocket() as SSLServerSocket
        listener = socket // Retain even a failed bind/close until owner settlement.
        try {
            socket.enabledProtocols = arrayOf("TLSv1.3")
            socket.needClientAuth = true
            socket.soTimeout = acceptTimeout
            socket.bind(InetSocketAddress(address, port), 2)
            return socket.localPort
        } catch (_: Exception) {
            try { socket.close() } catch (_: Exception) { failedClose() }
            if (closeFailed) throw DeviceLinkFailure("settlement_unknown")
            throw DeviceLinkFailure("unavailable")
        }
    }

    /** Joins the same accepted socket; never creates Application evidence from JSON. */
    fun acceptProof(epoch: Long, network: String, expectedClient: String): String =
        withChannel(epoch, network, expectedClient) { _, digest, _ -> digest }

    /** Original owner retains the socket through the supplied channel lifetime. */
    fun <T> withChannel(epoch: Long, network: String, expectedClient: String?,
                        action: (SSLSocket, String, Long) -> T): T {
        keys.requireAuthorized()
        val server = synchronized(this) {
            if (closed || !gate.current(epoch, network)) throw DeviceLinkFailure("unavailable")
            listener ?: throw DeviceLinkFailure("unavailable")
        }
        val socket = server.accept() as SSLSocket
        accepted.incrementAndGet()
        val handshakeEnds = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        var timer: ScheduledExecutorService? = null
        var deadline: ScheduledFuture<*>? = null
        try {
            synchronized(this) {
                if (closed || peer != null || !gate.current(epoch, network)) throw DeviceLinkFailure("foreground_required")
                peer = socket
            }
            timer = Executors.newSingleThreadScheduledExecutor()
            deadline = timer.schedule({ closePeer(socket) }, 5, TimeUnit.SECONDS)
            socket.soTimeout = 5000
            socket.startHandshake()
            val chain = socket.session.peerCertificates.map { it as X509Certificate }.toTypedArray()
            val digest = DeviceCredentials.digest(chain.single().encoded)
            DevicePeerPolicy.check(chain, expectedClient ?: digest, true)
            if (socket.isClosed || System.nanoTime() >= handshakeEnds ||
                socket.session.protocol != "TLSv1.3" || !gate.current(epoch, network)) {
                throw DeviceLinkFailure("credential_rejected")
            }
            deadline.cancel(false)
            return action(socket, digest, handshakeEnds)
        } catch (e: DeviceLinkFailure) { observeFailure(e); throw e }
          catch (e: Exception) { observeFailure(e); throw DeviceLinkFailure("credential_rejected") }
          finally {
            deadline?.cancel(false)
            timer?.shutdownNow()
            closePeer(socket)
            try {
                if (timer?.awaitTermination(5, TimeUnit.SECONDS) == false) failedClose("handshake-timer-join")
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                failedClose("handshake-timer-interrupted")
            }
            synchronized(this) {
                if (closeFailed) throw DeviceLinkFailure("settlement_unknown")
                if (peer === socket) peer = null
            }
        }
    }

    @Synchronized fun close() {
        closed = true
        peer?.let { closePeer(it) }
        try { listener?.close() } catch (_: Exception) { failedClose("listener-close") }
        // A later successful close never erases an earlier failure.
        if (closeFailed) throw DeviceLinkFailure("settlement_unknown")
    }
}
