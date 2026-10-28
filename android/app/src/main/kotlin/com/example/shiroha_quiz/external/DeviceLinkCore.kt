package com.example.shiroha_quiz.external

import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** Fixed safe categories only. Never retain a platform exception or payload. */
class DeviceLinkFailure(val code: String) : Exception(code)

/** Source-only delivery: no production caller may acquire keys or a listener. */
object DeviceLinkAdmission {
    const val runtimeAvailable = false
    fun requireAuthorized() {
        throw DeviceLinkFailure("runtime_not_authorized")
    }
}

/** Admission observation, never a P0 identity/Session or durable Grant. */
class DeviceForegroundGate {
    var sequence: Long = 0; private set
    var eligible: Boolean = false; private set
    var network: String? = null; private set
    private var closed = false

    @Synchronized
    fun observe(resumed: Boolean, focused: Boolean, interactive: Boolean,
                unlocked: Boolean, networkId: String?): Long {
        sequence++
        network = networkId
        eligible = !closed && resumed && focused && interactive && unlocked && networkId != null
        return sequence
    }

    @Synchronized fun current(epoch: Long, networkId: String): Boolean =
        !closed && eligible && epoch == sequence && networkId == network

    @Synchronized fun close() { closed = true; eligible = false; sequence++ }
}

class DeviceLinkFrame(val kind: Int, val payload: ByteArray) {
    override fun toString() = "DeviceLinkFrame(REDACTED)"
}

/** Raw framing only. Control/MCP JSON grants no identity and is parsed above TLS. */
object DeviceLinkFrames {
    const val CONTROL = 1
    const val MCP = 2
    const val CONTROL_MAX = 16 * 1024
    const val REQUEST_MAX = 6324224
    const val RESPONSE_MAX = 512 * 1024
    private val magic = byteArrayOf(83, 72, 65, 68)

    fun length(header: ByteArray, response: Boolean): Int {
        if (header.size != 12 || !header.copyOfRange(0, 4).contentEquals(magic) ||
            header[4].toInt() != 1 || header[6].toInt() != 0 || header[7].toInt() != 0) {
            throw DeviceLinkFailure("protocol_violation")
        }
        val max = when (header[5].toInt()) {
            CONTROL -> CONTROL_MAX
            MCP -> if (response) RESPONSE_MAX else REQUEST_MAX
            else -> throw DeviceLinkFailure("protocol_violation")
        }
        val length = ByteBuffer.wrap(header, 8, 4).int
        if (length <= 0 || length > max) throw DeviceLinkFailure("resource_limit")
        return length
    }

    private fun exact(input: InputStream, bytes: ByteArray) {
        var offset = 0
        while (offset < bytes.size) {
            val count = input.read(bytes, offset, bytes.size - offset)
            if (count <= 0) throw DeviceLinkFailure("connection_closed")
            offset += count
        }
    }

    fun read(input: InputStream, response: Boolean = false): DeviceLinkFrame {
        val header = ByteArray(12)
        exact(input, header)
        val size = length(header, response) // Validate BEFORE body allocation/read.
        val payload = ByteArray(size)
        exact(input, payload)
        validateUtf8(payload)
        return DeviceLinkFrame(header[5].toInt(), payload)
    }

    fun write(output: OutputStream, frame: DeviceLinkFrame, response: Boolean = true) {
        val header = ByteBuffer.allocate(12).put(magic).put(1).put(frame.kind.toByte())
            .putShort(0).putInt(frame.payload.size).array()
        length(header, response)
        validateUtf8(frame.payload)
        output.write(header)
        output.write(frame.payload)
        output.flush()
    }

    private fun validateUtf8(bytes: ByteArray) {
        try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes))
        } catch (_: Exception) { throw DeviceLinkFailure("protocol_violation") }
    }
}
