package com.example.shiroha_quiz.external

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec

/**
 * Hybrid TLS native custody for Android Streamable HTTP MCP.
 *
 * Security boundaries (no overclaims):
 * 1. The local Root CA signing key is generated inside AndroidKeyStore
 *    (`shiroha.external.android.http.v1.ca`) and is non-exportable. Its actual
 *    hardware backing (strongbox / tee / software / hardware_legacy) varies by
 *    device and is reported honestly via KeyInfo rather than assumed TEE.
 * 2. X.509 TBS building, assembly, and structural inspection stay in Dart's
 *    `ExternalCertificateDer`; this class never introduces a second X.509
 *    certificate framework.
 * 3. The IP-bound Server Leaf EC P-256 private key (PKCS#8 DER) is sealed at
 *    rest with `DeviceCredentials.seal(..., "http-leaf-key")` (AES-256-GCM
 *    backed by AndroidKeyStore) under `noBackupFilesDir/shiroha-external-v1/http`.
 *    Passing decrypted leaf key bytes into Dart's TLS context at runtime makes
 *    best-effort local ByteArray wipes, without claiming complete zeroing of
 *    JVM/Dart/BoringSSL memory copies.
 * 4. Construction performs no I/O and never consults S0 secure credential
 *    storage.
 */
internal class DeviceHttpTlsStore(
    private val context: Context,
    private val credentials: DeviceCredentials,
) {
    private val caAlias = "shiroha.external.android.http.v1.ca"
    private val directory = File(context.noBackupFilesDir, "shiroha-external-v1/http")
    private val caCertFile = AtomicFile(File(directory, "ca.der"))
    private val leafFile = AtomicFile(File(directory, "leaf.bin"))
    private val legacyLeafCertFile = AtomicFile(File(directory, "leaf.der"))
    private val legacyLeafKeyFile = AtomicFile(File(directory, "leaf-key.bin"))
    private val legacyLeafMetaFile = AtomicFile(File(directory, "leaf-meta.bin"))
    private var pendingLeaf: PendingLeaf? = null

    private class PendingLeaf(val publicKey: ByteArray, val sealedKey: ByteArray)
    private class LeafMaterial(
        val ipv4: String,
        val expiresAtUtcMs: Long,
        val certificate: ByteArray,
        val sealedKey: ByteArray,
    )

    private companion object {
        const val MAX_CERT_BYTES = 4096
        const val MAX_LEAF_BYTES = 2 * MAX_CERT_BYTES + 256
    }

    private fun store(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    /**
     * Ensures the non-exportable AndroidKeyStore Root CA signing key exists and
     * returns its 65-byte uncompressed P-256 public point plus honest KeyInfo
     * security level classification.
     */
    @Synchronized
    fun ensureCaKey(): Map<String, Any> {
        credentials.requireAuthorized()
        credentials.installationId()
        try {
            val keys = store()
            if (!keys.containsAlias(caAlias)) {
                val generator = KeyPairGenerator.getInstance(
                    KeyProperties.KEY_ALGORITHM_EC,
                    "AndroidKeyStore",
                )
                generator.initialize(
                    KeyGenParameterSpec.Builder(caAlias, KeyProperties.PURPOSE_SIGN)
                        .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                        .setDigests(KeyProperties.DIGEST_SHA256)
                        .setUserAuthenticationRequired(false)
                        .build()
                )
                generator.generateKeyPair()
            }
            val cert = keys.getCertificate(caAlias)
                ?: throw DeviceLinkFailure("credential_store_corrupt")
            val ecPublic = cert.publicKey as? ECPublicKey
                ?: throw DeviceLinkFailure("credential_store_corrupt")
            val privateKey = keys.getKey(caAlias, null) as? PrivateKey
                ?: throw DeviceLinkFailure("credential_store_corrupt")
            return mapOf(
                "publicKey" to uncompressedPoint(ecPublic),
                "nonExportable" to true,
                "securityLevel" to keySecurityLevel(privateKey),
                "caStored" to caCertFile.baseFile.exists(),
            )
        } catch (e: DeviceLinkFailure) {
            throw e
        } catch (_: Exception) {
            throw DeviceLinkFailure("credential_store_unavailable")
        }
    }

    /**
     * Signs an exact X.509 TBS byte sequence using the non-exportable
     * AndroidKeyStore Root CA key (`SHA256withECDSA`), returning ASN.1 DER
     * signature bytes for assembly & strict validation in `ExternalCertificateDer`.
     */
    @Synchronized
    fun signTbsWithCa(tbs: ByteArray): ByteArray {
        credentials.requireAuthorized()
        if (tbs.isEmpty() || tbs.size > 4096) throw DeviceLinkFailure("protocol_violation")
        return try {
            val privateKey = store().getKey(caAlias, null) as? PrivateKey
                ?: throw DeviceLinkFailure("pairing_required")
            Signature.getInstance("SHA256withECDSA").run {
                initSign(privateKey)
                update(tbs)
                sign()
            }
        } catch (e: DeviceLinkFailure) {
            throw e
        } catch (_: Exception) {
            throw DeviceLinkFailure("credential_store_unavailable")
        }
    }

    @Synchronized
    fun storeCaCertificate(caDer: ByteArray) {
        credentials.requireAuthorized()
        if (caDer.isEmpty() || caDer.size > MAX_CERT_BYTES) {
            throw DeviceLinkFailure("protocol_violation")
        }
        val key = store().getCertificate(caAlias)?.publicKey
            ?: throw DeviceLinkFailure("pairing_required")
        val certificate = parseCertificate(caDer)
        if (!key.encoded.contentEquals(certificate.publicKey.encoded)) {
            throw DeviceLinkFailure("protocol_violation")
        }
        certificate.verify(key)
        writeAtomic(caCertFile, caDer)
    }

    @Synchronized
    fun readCaCertificate(): ByteArray? {
        credentials.requireAuthorized()
        return readBounded(caCertFile, 4096)
    }

    /**
     * Prepares an encrypted leaf key in memory. The published identity is
     * replaced only after a matching certificate and metadata are available.
     */
    @Synchronized
    fun generateAndSealLeafKey(): ByteArray {
        credentials.requireAuthorized()
        credentials.installationId()
        val keyPair = try {
            KeyPairGenerator.getInstance("EC").run {
                initialize(ECGenParameterSpec("secp256r1"))
                generateKeyPair()
            }
        } catch (_: Exception) {
            throw DeviceLinkFailure("credential_store_unavailable")
        }
        val publicKey = keyPair.public as? ECPublicKey
            ?: throw DeviceLinkFailure("credential_store_corrupt")
        val point = uncompressedPoint(publicKey)
        val pkcs8 = keyPair.private.encoded
            ?: throw DeviceLinkFailure("credential_store_corrupt")
        try {
            val sealed = credentials.seal(pkcs8, "http-leaf-key")
            discardPreparedLeaf()
            pendingLeaf = PendingLeaf(publicKey.encoded, sealed)
            return point
        } finally {
            pkcs8.fill(0)
        }
    }

    @Synchronized
    fun discardPreparedLeaf() {
        pendingLeaf?.sealedKey?.fill(0)
        pendingLeaf = null
    }

    @Synchronized
    fun storeLeafCertificate(ipv4: String, expiresAtUtcMs: Long, leafDer: ByteArray) {
        credentials.requireAuthorized()
        val pending = pendingLeaf ?: throw DeviceLinkFailure("pairing_required")
        if (ipv4.length !in 7..15 || expiresAtUtcMs <= 0L ||
            leafDer.isEmpty() || leafDer.size > MAX_CERT_BYTES
        ) {
            throw DeviceLinkFailure("protocol_violation")
        }
        val caDer = readCaCertificate() ?: throw DeviceLinkFailure("pairing_required")
        val leaf = LeafMaterial(ipv4, expiresAtUtcMs, leafDer, pending.sealedKey)
        val certificate = checkLeaf(leaf, caDer)
        if (!pending.publicKey.contentEquals(certificate.publicKey.encoded)) {
            throw DeviceLinkFailure("protocol_violation")
        }
        val out = ByteArrayOutputStream()
        DataOutputStream(out).use {
            it.writeByte(1)
            it.writeUTF(ipv4)
            it.writeLong(expiresAtUtcMs)
            it.writeInt(leafDer.size)
            it.write(leafDer)
            it.writeInt(pending.sealedKey.size)
            it.write(pending.sealedKey)
        }
        writeAtomic(leafFile, out.toByteArray())
        discardPreparedLeaf()
    }

    /**
     * Reads one published generation and releases only a matching PKCS#8 key.
     * The caller wipes its returned key bytes after TLS loading.
     */
    @Synchronized
    fun openLeafMaterial(): Map<String, Any> {
        credentials.requireAuthorized()
        val caDer = readCaCertificate() ?: throw DeviceLinkFailure("pairing_required")
        val leaf = readLeaf()
        val certificate = checkLeaf(leaf, caDer)
        val privateKey = store().getKey(caAlias, null) as? PrivateKey
            ?: throw DeviceLinkFailure("pairing_required")
        val securityLevel = keySecurityLevel(privateKey)
        val pkcs8 = try {
            credentials.open(leaf.sealedKey, "http-leaf-key")
        } finally {
            leaf.sealedKey.fill(0)
        }
        try {
            // Also guards old, independently written leaf files left by H1.
            requireKeyMatch(pkcs8, certificate)
            return mapOf(
                "caDer" to caDer,
                "leafDer" to leaf.certificate,
                "leafPrivateKeyPkcs8" to pkcs8,
                "ipv4" to leaf.ipv4,
                "expiresAtUtcMs" to leaf.expiresAtUtcMs,
                "nonExportableCa" to true,
                "caSecurityLevel" to securityLevel,
            )
        } catch (_: Exception) {
            pkcs8.fill(0)
            throw DeviceLinkFailure("credential_store_corrupt")
        }
    }

    private fun readLeaf(): LeafMaterial {
        val bundled = readBounded(leafFile, MAX_LEAF_BYTES)
        try {
            if (bundled != null) {
                val input = DataInputStream(ByteArrayInputStream(bundled))
                if (input.readUnsignedByte() != 1) throw DeviceLinkFailure("credential_store_corrupt")
                val leaf = LeafMaterial(input.readUTF(), input.readLong(), readPart(input), readPart(input))
                if (input.read() != -1) throw DeviceLinkFailure("credential_store_corrupt")
                return leaf
            }

            // A missing bundle may be an older store. A present invalid bundle
            // fails closed; the older files are never a corruption fallback.
            val cert = readBounded(legacyLeafCertFile, MAX_CERT_BYTES)
                ?: throw DeviceLinkFailure("pairing_required")
            val meta = readBounded(legacyLeafMetaFile, 256)
                ?: throw DeviceLinkFailure("credential_store_corrupt")
            val input = DataInputStream(ByteArrayInputStream(meta))
            if (input.readUnsignedByte() != 1) throw DeviceLinkFailure("credential_store_corrupt")
            val ipv4 = input.readUTF()
            val expiresAt = input.readLong()
            if (input.read() != -1) throw DeviceLinkFailure("credential_store_corrupt")
            val key = readBounded(legacyLeafKeyFile, MAX_CERT_BYTES)
                ?: throw DeviceLinkFailure("credential_store_corrupt")
            return LeafMaterial(ipv4, expiresAt, cert, key)
        } catch (error: DeviceLinkFailure) {
            throw error
        } catch (_: Exception) {
            throw DeviceLinkFailure("credential_store_corrupt")
        }
    }

    private fun readPart(input: DataInputStream): ByteArray {
        val size = input.readInt()
        if (size !in 1..MAX_CERT_BYTES) throw DeviceLinkFailure("credential_store_corrupt")
        return ByteArray(size).also { input.readFully(it) }
    }

    private fun parseCertificate(der: ByteArray): X509Certificate {
        val input = ByteArrayInputStream(der)
        val certificate = CertificateFactory.getInstance("X.509")
            .generateCertificate(input) as X509Certificate
        if (input.available() != 0) throw DeviceLinkFailure("credential_store_corrupt")
        return certificate
    }

    private fun checkLeaf(leaf: LeafMaterial, caDer: ByteArray): X509Certificate {
        try {
            val ca = parseCertificate(caDer)
            val installedCa = store().getCertificate(caAlias)?.publicKey
                ?: throw DeviceLinkFailure("pairing_required")
            val certificate = parseCertificate(leaf.certificate)
            val addressMatches = certificate.subjectAlternativeNames?.any {
                it.size == 2 && it[0] == 7 && it[1] == leaf.ipv4
            } == true
            if (!installedCa.encoded.contentEquals(ca.publicKey.encoded) ||
                certificate.issuerX500Principal != ca.subjectX500Principal ||
                certificate.notAfter.time != leaf.expiresAtUtcMs ||
                !addressMatches
            ) throw DeviceLinkFailure("credential_store_corrupt")
            certificate.verify(installedCa)
            return certificate
        } catch (error: DeviceLinkFailure) {
            throw error
        } catch (_: Exception) {
            throw DeviceLinkFailure("credential_store_corrupt")
        }
    }

    private fun requireKeyMatch(pkcs8: ByteArray, certificate: X509Certificate) {
        val privateKey = KeyFactory.getInstance("EC")
            .generatePrivate(PKCS8EncodedKeySpec(pkcs8))
        val challenge = "shiroha-http-leaf-key-match-v1".toByteArray(Charsets.US_ASCII)
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(privateKey)
        signature.update(challenge)
        val proof = signature.sign()
        signature.initVerify(certificate.publicKey)
        signature.update(challenge)
        if (!signature.verify(proof)) throw DeviceLinkFailure("credential_store_corrupt")
    }

    private fun keySecurityLevel(privateKey: PrivateKey): String {
        val info = KeyFactory.getInstance(privateKey.algorithm, "AndroidKeyStore")
            .getKeySpec(privateKey, KeyInfo::class.java)
        if (Build.VERSION.SDK_INT >= 31) {
            return when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "strongbox"
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "tee"
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> "software"
                KeyProperties.SECURITY_LEVEL_UNKNOWN_SECURE -> "hardware_unknown"
                else -> "unknown"
            }
        }
        @Suppress("DEPRECATION")
        return if (info.isInsideSecureHardware) "hardware_legacy" else "software"
    }

    private fun uncompressedPoint(publicKey: ECPublicKey): ByteArray {
        val x = toFixed32(publicKey.w.affineX.toByteArray())
        val y = toFixed32(publicKey.w.affineY.toByteArray())
        return ByteArray(65).also { out ->
            out[0] = 0x04
            System.arraycopy(x, 0, out, 1, 32)
            System.arraycopy(y, 0, out, 33, 32)
        }
    }

    private fun toFixed32(raw: ByteArray): ByteArray {
        var start = 0
        while (start < raw.size - 1 && raw[start] == 0.toByte()) {
            start++
        }
        val length = raw.size - start
        if (length > 32) throw DeviceLinkFailure("credential_store_corrupt")
        val out = ByteArray(32)
        System.arraycopy(raw, start, out, 32 - length, length)
        return out
    }

    private fun writeAtomic(target: AtomicFile, bytes: ByteArray) {
        if (!directory.exists() && !directory.mkdirs()) {
            throw DeviceLinkFailure("credential_store_unavailable")
        }
        val stream = target.startWrite()
        try {
            stream.write(bytes)
            target.finishWrite(stream)
        } catch (_: Exception) {
            target.failWrite(stream)
            throw DeviceLinkFailure("commit_unknown")
        }
        try {
            if (readBounded(target, bytes.size)?.contentEquals(bytes) != true) {
                throw DeviceLinkFailure("commit_unknown")
            }
        } catch (_: Exception) {
            throw DeviceLinkFailure("commit_unknown")
        }
    }

    private fun readBounded(target: AtomicFile, maxLength: Int): ByteArray? {
        if (!target.baseFile.exists() && !File(target.baseFile.path + ".bak").exists()) {
            return null
        }
        return target.openRead().use { input ->
            val out = ByteArrayOutputStream()
            val chunk = ByteArray(1024)
            while (true) {
                val read = input.read(chunk)
                if (read < 0) break
                if (out.size() + read > maxLength) {
                    throw DeviceLinkFailure("credential_store_corrupt")
                }
                out.write(chunk, 0, read)
            }
            out.toByteArray()
        }
    }
}
