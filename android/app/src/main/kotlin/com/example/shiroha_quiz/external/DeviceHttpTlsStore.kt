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
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

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
    private val leafCertFile = AtomicFile(File(directory, "leaf.der"))
    private val leafKeyFile = AtomicFile(File(directory, "leaf-key.bin"))
    private val leafMetaFile = AtomicFile(File(directory, "leaf-meta.bin"))

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
        if (caDer.isEmpty() || caDer.size > 4096) throw DeviceLinkFailure("protocol_violation")
        writeAtomic(caCertFile, caDer)
    }

    @Synchronized
    fun readCaCertificate(): ByteArray? {
        credentials.requireAuthorized()
        return readBounded(caCertFile, 4096)
    }

    /**
     * Generates a software EC P-256 Server Leaf key pair, seals its PKCS#8
     * private key at rest with AndroidKeyStore AES-256-GCM (`http-leaf-key`),
     * wipes local intermediate arrays on a best-effort basis, and returns only
     * the 65-byte uncompressed public point for `ExternalCertificateDer.buildTbs`.
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
        val ecPublic = keyPair.public as? ECPublicKey
            ?: throw DeviceLinkFailure("credential_store_corrupt")
        val pkcs8 = keyPair.private.encoded
            ?: throw DeviceLinkFailure("credential_store_corrupt")
        var encrypted: ByteArray? = null
        try {
            encrypted = credentials.seal(pkcs8, "http-leaf-key")
            writeAtomic(leafKeyFile, encrypted)
            return uncompressedPoint(ecPublic)
        } finally {
            pkcs8.fill(0)
            encrypted?.fill(0)
        }
    }

    @Synchronized
    fun storeLeafCertificate(ipv4: String, expiresAtUtcMs: Long, leafDer: ByteArray) {
        credentials.requireAuthorized()
        if (ipv4.length !in 7..15 || leafDer.isEmpty() || leafDer.size > 4096 || expiresAtUtcMs <= 0L) {
            throw DeviceLinkFailure("protocol_violation")
        }
        writeAtomic(leafCertFile, leafDer)
        val out = ByteArrayOutputStream()
        DataOutputStream(out).use {
            it.writeByte(1)
            it.writeUTF(ipv4)
            it.writeLong(expiresAtUtcMs)
        }
        writeAtomic(leafMetaFile, out.toByteArray())
    }

    /**
     * Loads the stored Root CA DER, current IP-bound Server Leaf DER, metadata,
     * and decrypted PKCS#8 leaf private key for in-process Dart TLS startup.
     * Callers must wipe the returned ByteArray copy on a best-effort basis once
     * loaded into Dart's TLS context; complete zeroing of runtime memory copies
     * is explicitly not claimed.
     */
    @Synchronized
    fun openLeafMaterial(): Map<String, Any> {
        credentials.requireAuthorized()
        val caDer = readBounded(caCertFile, 4096)
            ?: throw DeviceLinkFailure("pairing_required")
        val leafDer = readBounded(leafCertFile, 4096)
            ?: throw DeviceLinkFailure("pairing_required")
        val metaBytes = readBounded(leafMetaFile, 256)
            ?: throw DeviceLinkFailure("credential_store_corrupt")
        val encryptedKey = readBounded(leafKeyFile, 4096)
            ?: throw DeviceLinkFailure("credential_store_corrupt")
        val ipv4: String
        val expiresAtUtcMs: Long
        try {
            val input = DataInputStream(ByteArrayInputStream(metaBytes))
            if (input.readUnsignedByte() != 1) throw DeviceLinkFailure("credential_store_corrupt")
            ipv4 = input.readUTF()
            expiresAtUtcMs = input.readLong()
            if (input.read() != -1) throw DeviceLinkFailure("credential_store_corrupt")
        } catch (e: DeviceLinkFailure) {
            throw e
        } catch (_: Exception) {
            throw DeviceLinkFailure("credential_store_corrupt")
        }
        val privateKey = store().getKey(caAlias, null) as? PrivateKey
            ?: throw DeviceLinkFailure("pairing_required")
        val pkcs8 = try {
            credentials.open(encryptedKey, "http-leaf-key")
        } finally {
            encryptedKey.fill(0)
        }
        return mapOf(
            "caDer" to caDer,
            "leafDer" to leafDer,
            "leafPrivateKeyPkcs8" to pkcs8,
            "ipv4" to ipv4,
            "expiresAtUtcMs" to expiresAtUtcMs,
            "nonExportableCa" to true,
            "caSecurityLevel" to keySecurityLevel(privateKey),
        )
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
