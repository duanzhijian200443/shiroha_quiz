package com.example.shiroha_quiz.external

import java.security.AlgorithmParameters
import java.security.interfaces.ECPublicKey
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec

/** No system trust-store mutation or trust-all fallback. Exactly one pinned leaf. */
internal object DevicePeerPolicy {
    fun digest(bytes: ByteArray): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }
    fun check(chain: Array<X509Certificate>?, expectedDigest: String, client: Boolean, now: java.util.Date = java.util.Date()) {
        if (!Regex("[0-9a-f]{64}").matches(expectedDigest) || chain == null || chain.size != 1)
            throw DeviceLinkFailure("credential_rejected")
        try {
            val cert = chain.single()
            if (digest(cert.encoded) != expectedDigest) throw DeviceLinkFailure("credential_rejected")
            cert.checkValidity(now)
            if (cert.hasUnsupportedCriticalExtension() || cert.basicConstraints >= 0)
                throw DeviceLinkFailure("credential_rejected")
            val key = cert.publicKey as? ECPublicKey ?: throw DeviceLinkFailure("credential_rejected")
            val parameters = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
                .getParameterSpec(ECParameterSpec::class.java)
            if (key.params.curve != parameters.curve || key.params.generator != parameters.generator ||
                key.params.order != parameters.order || key.params.cofactor != parameters.cofactor)
                throw DeviceLinkFailure("credential_rejected")
            if (cert.sigAlgOID != "1.2.840.10045.4.3.2") throw DeviceLinkFailure("credential_rejected")
            cert.verify(key)
            cert.keyUsage?.let { if (it.isEmpty() || !it[0]) throw DeviceLinkFailure("credential_rejected") }
            val usage = cert.extendedKeyUsage
            val required = if (client) "1.3.6.1.5.5.7.3.2" else "1.3.6.1.5.5.7.3.1"
            if ((client && usage == null) || (usage != null && (usage.size != 1 || usage.single() != required)))
                throw DeviceLinkFailure("credential_rejected")
        } catch (e: DeviceLinkFailure) { throw e }
          catch (_: Exception) { throw DeviceLinkFailure("credential_rejected") }
    }
}
