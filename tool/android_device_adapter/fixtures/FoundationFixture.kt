package com.example.shiroha_quiz.external

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/** JVM-only synthetic fixture. No Android class, key, file, socket or App use. */
fun main(args: Array<String>) {
    var count = 0
    fun accepts(value: Boolean) { check(value); count++ }
    fun rejects(work: () -> Unit) {
        try { work() } catch (_: DeviceLinkFailure) { count++; return }
        error("expected_rejection")
    }
    accepts(!DeviceLinkAdmission.runtimeAvailable)
    rejects { DeviceLinkAdmission.requireAuthorized() }
    val gate = DeviceForegroundGate()
    val first = gate.observe(true, true, true, true, "wifi-1")
    accepts(gate.current(first, "wifi-1"))
    accepts(!gate.current(first, "wifi-2"))
    gate.observe(true, false, true, true, "wifi-1")
    accepts(!gate.current(first, "wifi-1"))
    val again = gate.observe(true, true, true, true, "wifi-1")
    accepts(gate.current(again, "wifi-1"))
    gate.close()
    val late = gate.observe(true, true, true, true, "wifi-1")
    accepts(!gate.current(late, "wifi-1"))
    val out = ByteArrayOutputStream()
    DeviceLinkFrames.write(out, DeviceLinkFrame(1, "{}".toByteArray()))
    val frame = DeviceLinkFrames.read(ByteArrayInputStream(out.toByteArray()))
    accepts(frame.kind == 1 && frame.payload.contentEquals("{}".toByteArray()))
    val header = out.toByteArray().copyOfRange(0, 12)
    header[4] = 2
    rejects { DeviceLinkFrames.length(header, false) }
    header[4] = 1; header[6] = 1
    rejects { DeviceLinkFrames.length(header, false) }
    header[6] = 0
    ByteBuffer.wrap(header, 8, 4).putInt(-1)
    rejects { DeviceLinkFrames.length(header, false) }
    ByteBuffer.wrap(header, 8, 4).putInt(0)
    rejects { DeviceLinkFrames.length(header, false) }
    rejects { DeviceLinkFrames.read(ByteArrayInputStream(byteArrayOf(83, 72))) }
    rejects { DeviceLinkFrames.write(ByteArrayOutputStream(), DeviceLinkFrame(1, byteArrayOf(0xc0.toByte(), 0x80.toByte()))) }
    ByteBuffer.wrap(header, 8, 4).putInt(DeviceLinkFrames.CONTROL_MAX + 1)
    rejects { DeviceLinkFrames.read(ByteArrayInputStream(header)) }
    // Reads only the explicit repository-owned public fixture, never credentials.
    val json = java.io.File(args.single()).readText()
    fun value(name: String): String = Regex("\"$name\"\\s*:\\s*\"([^\"]+)\"").find(json)!!.groupValues[1]
    fun bytes(hex: String): ByteArray = hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    fun certificate(name: String): java.security.cert.X509Certificate =
        java.security.cert.CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(bytes(value(name)))) as java.security.cert.X509Certificate
    val now = java.util.Date.from(java.time.Instant.parse("2026-10-28T00:00:00Z"))
    val server = certificate("server")
    DevicePeerPolicy.check(arrayOf(server), value("serverDigest"), false, now)
    accepts(true)
    rejects { DevicePeerPolicy.check(arrayOf(server), "0".repeat(64), false, now) }
    rejects { DevicePeerPolicy.check(arrayOf(server), value("serverDigest"), true, now) }
    rejects { DevicePeerPolicy.check(arrayOf(certificate("client")), value("clientDigest"), false, now) }
    rejects { DevicePeerPolicy.check(arrayOf(certificate("expired")), value("expiredDigest"), false, now) }
    rejects { DevicePeerPolicy.check(arrayOf(server, server), value("serverDigest"), false, now) }
    println("PASS: $count JVM synthetic checks; public certificates only; no Android runtime or network")
}
