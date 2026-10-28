package com.example.shiroha_quiz.external

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.security.auth.x500.X500Principal

/** Native key custody. Construction has no I/O. S0 engine.* is never consulted. */
internal class DeviceCredentials(private val context: Context) {
    private val identityAlias = "shiroha.external.android.v1.device"
    private val storageAlias = "shiroha.external.android.v1.storage"
    private fun store(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun initialize() {
        DeviceLinkAdmission.requireAuthorized()
        try {
            val keys = store()
            // Partial initialization is recovery, never overwrite or automatic repair.
            if (keys.containsAlias(identityAlias) || keys.containsAlias(storageAlias) ||
                File(context.noBackupFilesDir, "shiroha-external-v1").exists()) {
                throw DeviceLinkFailure("recovery_required")
            }
            val now = System.currentTimeMillis()
            val serial = ByteArray(16).also { SecureRandom().nextBytes(it) }
            val generator = KeyPairGenerator.getInstance("EC", "AndroidKeyStore")
            generator.initialize(KeyGenParameterSpec.Builder(identityAlias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setUserAuthenticationRequired(false)
                .setCertificateSubject(X500Principal("CN=Shiroha Android Device"))
                .setCertificateSerialNumber(BigInteger(1, serial).max(BigInteger.ONE))
                .setCertificateNotBefore(Date(now - 300000))
                .setCertificateNotAfter(Date(now + 730L * 86400000)).build())
            generator.generateKeyPair()
            val cipherKey = KeyGenerator.getInstance("AES", "AndroidKeyStore")
            cipherKey.init(KeyGenParameterSpec.Builder(storageAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
            cipherKey.generateKey()
            certificate().also { it.verify(it.publicKey); it.checkValidity() }
            val directory = File(context.noBackupFilesDir, "shiroha-external-v1")
            if (!directory.mkdirs()) throw DeviceLinkFailure("credential_store_unavailable")
            val record = java.io.ByteArrayOutputStream()
            java.io.DataOutputStream(record).use {
                it.writeByte(1)
                it.writeUTF(java.util.UUID.randomUUID().toString())
                it.writeUTF(deviceId())
            }
            val clear = record.toByteArray()
            val encrypted = seal(clear, "installation")
            val file = AtomicFile(File(directory, "installation.bin"))
            val stream = file.startWrite()
            try { stream.write(encrypted); file.finishWrite(stream) }
            catch (_: Exception) { file.failWrite(stream); throw DeviceLinkFailure("commit_unknown") }
            finally { clear.fill(0); encrypted.fill(0) }
            installationId() // Require readback and exact key binding before reporting success.
        } catch (e: DeviceLinkFailure) { throw e }
          catch (_: Exception) { throw DeviceLinkFailure("credential_store_unavailable") }
    }

    fun certificate(): X509Certificate {
        DeviceLinkAdmission.requireAuthorized()
        return try { store().getCertificate(identityAlias) as? X509Certificate
            ?: throw DeviceLinkFailure("pairing_required") }
        catch (e: DeviceLinkFailure) { throw e }
        catch (_: Exception) { throw DeviceLinkFailure("credential_store_unavailable") }
    }

    fun privateKey(): PrivateKey {
        DeviceLinkAdmission.requireAuthorized()
        return try { store().getKey(identityAlias, null) as? PrivateKey
            ?: throw DeviceLinkFailure("pairing_required") }
        catch (e: DeviceLinkFailure) { throw e }
        catch (_: Exception) { throw DeviceLinkFailure("credential_store_unavailable") }
    }

    fun deviceId(): String = digest(certificate().publicKey.encoded)

    fun installationId(): String {
        DeviceLinkAdmission.requireAuthorized()
        try {
            val file = AtomicFile(File(context.noBackupFilesDir, "shiroha-external-v1/installation.bin"))
            val encrypted = file.openRead().use { input ->
                val out = java.io.ByteArrayOutputStream()
                var value = input.read()
                while (value != -1) {
                    if (out.size() >= 1024) throw DeviceLinkFailure("credential_store_corrupt")
                    out.write(value); value = input.read()
                }
                out.toByteArray()
            }
            val clear = open(encrypted, "installation")
            try {
                val input = java.io.DataInputStream(java.io.ByteArrayInputStream(clear))
                if (input.readUnsignedByte() != 1) throw DeviceLinkFailure("credential_store_corrupt")
                val id = input.readUTF()
                if (java.util.UUID.fromString(id).version() != 4 || input.readUTF() != deviceId() || input.read() != -1)
                    throw DeviceLinkFailure("credential_store_corrupt")
                return id
            } finally { clear.fill(0); encrypted.fill(0) }
        } catch (e: DeviceLinkFailure) { throw e }
          catch (_: Exception) { throw DeviceLinkFailure("credential_store_corrupt") }
    }

    private fun cipher(mode: Int, iv: ByteArray? = null, purpose: String): Cipher {
        DeviceLinkAdmission.requireAuthorized()
        val key = store().getKey(storageAlias, null) as? SecretKey
            ?: throw DeviceLinkFailure("pairing_required")
        return Cipher.getInstance("AES/GCM/NoPadding").apply {
            if (iv == null) init(mode, key) else init(mode, key, GCMParameterSpec(128, iv))
            updateAAD("shiroha-external-$purpose-v1".toByteArray(Charsets.US_ASCII))
        }
    }

    fun seal(bytes: ByteArray, purpose: String = "associations"): ByteArray {
        DeviceLinkAdmission.requireAuthorized()
        if (bytes.isEmpty() || bytes.size > 65536) throw DeviceLinkFailure("resource_limit")
        return try {
            val cipher = cipher(Cipher.ENCRYPT_MODE, purpose = purpose)
            byteArrayOf(1) + cipher.iv + cipher.doFinal(bytes)
        } catch (e: DeviceLinkFailure) { throw e }
          catch (_: Exception) { throw DeviceLinkFailure("credential_store_unavailable") }
    }

    fun open(bytes: ByteArray, purpose: String = "associations"): ByteArray {
        DeviceLinkAdmission.requireAuthorized()
        if (bytes.size !in 30..65565 || bytes[0].toInt() != 1) throw DeviceLinkFailure("credential_store_corrupt")
        return try { cipher(Cipher.DECRYPT_MODE, bytes.copyOfRange(1, 13), purpose).doFinal(bytes, 13, bytes.size - 13) }
        catch (e: DeviceLinkFailure) { throw e }
        catch (_: Exception) { throw DeviceLinkFailure("credential_store_corrupt") }
    }

    companion object {
        fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it) }
    }
}

/** One owner and one outstanding lease. No directories/files are created at construction. */
internal class DeviceAssociationFile(context: Context, private val credentials: DeviceCredentials) {
    private val directory = File(context.noBackupFilesDir, "shiroha-external-v1")
    private val file = AtomicFile(File(directory, "associations.bin"))
    private var occupied = false
    private var poisoned = false
    private var revision = 0L

    inner class Lease internal constructor(private val version: Long, private val original: ByteArray?,
                                          private val clear: ByteArray?) {
        private var ended = false
        private var attempted = false
        fun plaintext(): ByteArray? = synchronized(this@DeviceAssociationFile) {
            checkCurrent(); clear?.copyOf()
        }
        private fun checkCurrent() {
            if (ended || poisoned || version != revision) throw DeviceLinkFailure("stale_revision")
        }
        fun commit(bytes: ByteArray) = synchronized(this@DeviceAssociationFile) {
            DeviceLinkAdmission.requireAuthorized()
            checkCurrent()
            if (attempted) throw DeviceLinkFailure("stale_revision")
            attempted = true
            val current = readEncrypted()
            if (!equal(current, original)) { poisoned = true; throw DeviceLinkFailure("stale_revision") }
            val encrypted = credentials.seal(bytes)
            var stream: java.io.FileOutputStream? = null
            try {
                if (!directory.exists() && !directory.mkdirs()) throw DeviceLinkFailure("credential_store_unavailable")
                stream = file.startWrite()
                stream.write(encrypted)
                file.finishWrite(stream)
                stream = null
                if (!equal(readEncrypted(), encrypted)) throw DeviceLinkFailure("commit_unknown")
                revision++
            } catch (_: Exception) {
                poisoned = true
                stream?.let { try { file.failWrite(it) } catch (_: Exception) { } }
                throw DeviceLinkFailure("commit_unknown")
            } finally { encrypted.fill(0) }
        }
        fun close() = synchronized(this@DeviceAssociationFile) {
            if (!ended) { ended = true; clear?.fill(0); occupied = false }
        }
    }

    @Synchronized fun begin(): Lease {
        DeviceLinkAdmission.requireAuthorized()
        if (poisoned) throw DeviceLinkFailure("recovery_required")
        if (occupied) throw DeviceLinkFailure("busy")
        credentials.installationId()
        occupied = true
        return try {
            val original = readEncrypted()
            Lease(revision, original, original?.let { credentials.open(it) })
        } catch (e: DeviceLinkFailure) { occupied = false; poisoned = true; throw e }
          catch (_: Exception) { occupied = false; poisoned = true; throw DeviceLinkFailure("credential_store_unavailable") }
    }

    private fun readEncrypted(): ByteArray? {
        if (!file.baseFile.exists() && File(file.baseFile.path + ".new").exists())
            throw DeviceLinkFailure("recovery_required")
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        return file.openRead().use {
            // Bound before allocation, including unexpected restored/corrupt files.
            val out = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(4096)
            while (true) {
                val count = it.read(chunk)
                if (count < 0) break
                if (count == 0) throw DeviceLinkFailure("credential_store_unavailable")
                if (out.size() + count > 65565) throw DeviceLinkFailure("resource_limit")
                out.write(chunk, 0, count)
            }
            out.toByteArray()
        }
    }
    private fun equal(a: ByteArray?, b: ByteArray?): Boolean =
        if (a == null || b == null) a == null && b == null else MessageDigest.isEqual(a, b)
}
