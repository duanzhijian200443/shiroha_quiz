/// Offline framing only; validated text never establishes identity or authority.
library;

import 'dart:convert';
import 'dart:typed_data';

enum IpcMessageKind { request, response, protocolError }

enum IpcProtocolFailure {
  invalidFrame,
  unsupportedVersion,
  unsupportedMessage,
  unsupportedEncoding,
  unsupportedFeature,
  invalidLength,
  resourceLimit,
  invalidId,
  invalidUtf8,
  invalidPayload,
  truncated,
  closed,
}

final class IpcProtocolException implements Exception {
  const IpcProtocolException(this.failure);
  final IpcProtocolFailure failure;
  @override
  String toString() => 'IpcProtocolException(${failure.name})';
}

/// Separate from MCP and submission versions. No configurable weaker ceiling.
abstract final class IpcEnvelopeLimits {
  static const version = 1;
  static const headerBytes = 16;
  static const idBytes = 64;
  static const requestBytes = 6 * 1024 * 1024 + 32768;
  static const responseBytes = 6 * 32768 + 32768;
  static const errorBytes = 32;
  static const frameBytes = headerBytes + idBytes + requestBytes;
}

/// Opaque, untrusted UTF-8 text. No business JSON, Session or dispatch interface.
final class UntrustedIpcEnvelope {
  const UntrustedIpcEnvelope._(this.kind, this.requestId, this.payload);
  final IpcMessageKind kind;
  final String? requestId;
  final String payload;
  int get version => IpcEnvelopeLimits.version;
  @override
  String toString() => 'UntrustedIpcEnvelope(${kind.name})';
}

/// At most one completed envelope; repeat at offset + consumed for coalescing.
final class IpcDecodeStep {
  const IpcDecodeStep._(this.consumed, this.envelope);
  final int consumed;
  final UntrustedIpcEnvelope? envelope;
}

Never _reject(IpcProtocolFailure failure) =>
    throw IpcProtocolException(failure);

int _limit(IpcMessageKind kind) => switch (kind) {
      IpcMessageKind.request => IpcEnvelopeLimits.requestBytes,
      IpcMessageKind.response => IpcEnvelopeLimits.responseBytes,
      IpcMessageKind.protocolError => IpcEnvelopeLimits.errorBytes,
    };

bool _idUnit(int unit) =>
    (unit >= 65 && unit <= 90) ||
    (unit >= 97 && unit <= 122) ||
    (unit >= 48 && unit <= 57) ||
    unit == 95 ||
    unit == 45;

void _checkId(IpcMessageKind kind, String? id) {
  if (kind == IpcMessageKind.protocolError) {
    if (id != null) _reject(IpcProtocolFailure.invalidId);
  } else if (id == null ||
      id.isEmpty ||
      id.length > IpcEnvelopeLimits.idBytes ||
      !id.codeUnits.every(_idUnit)) {
    _reject(IpcProtocolFailure.invalidId);
  }
}

void _checkPayload(IpcMessageKind kind, String payload) {
  if (kind == IpcMessageKind.protocolError &&
      !IpcProtocolFailure.values.any((failure) => failure.name == payload)) {
    _reject(IpcProtocolFailure.invalidPayload);
  }
}

/// Compute bytes before allocation, rejecting surrogate replacement on encode.
int _utf8Length(String text, int limit) {
  if (text.isEmpty) _reject(IpcProtocolFailure.invalidLength);
  if (text.length > limit) _reject(IpcProtocolFailure.resourceLimit);
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes++;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= text.length ||
          text.codeUnitAt(i) < 0xdc00 ||
          text.codeUnitAt(i) > 0xdfff) {
        _reject(IpcProtocolFailure.invalidUtf8);
      }
      bytes += 4;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      _reject(IpcProtocolFailure.invalidUtf8);
    } else {
      bytes += 3;
    }
    if (bytes > limit) _reject(IpcProtocolFailure.resourceLimit);
  }
  return bytes;
}

// Input has already passed the exact Unicode/length scan. Write directly into
// the final frame, avoiding a second payload and the SDK encoder's scratch.
void _writeUtf8(String text, Uint8List frame, int offset) {
  for (final scalar in text.runes) {
    if (scalar < 0x80) {
      frame[offset++] = scalar;
    } else if (scalar < 0x800) {
      frame[offset++] = 0xc0 | (scalar >> 6);
      frame[offset++] = 0x80 | (scalar & 0x3f);
    } else if (scalar < 0x10000) {
      frame[offset++] = 0xe0 | (scalar >> 12);
      frame[offset++] = 0x80 | ((scalar >> 6) & 0x3f);
      frame[offset++] = 0x80 | (scalar & 0x3f);
    } else {
      frame[offset++] = 0xf0 | (scalar >> 18);
      frame[offset++] = 0x80 | ((scalar >> 12) & 0x3f);
      frame[offset++] = 0x80 | ((scalar >> 6) & 0x3f);
      frame[offset++] = 0x80 | (scalar & 0x3f);
    }
  }
}

abstract final class IpcEnvelopeCodec {
  static Uint8List encodeRequest(String requestId, String payload) =>
      _encode(IpcMessageKind.request, requestId, payload);
  static Uint8List encodeResponse(String requestId, String payload) =>
      _encode(IpcMessageKind.response, requestId, payload);
  static Uint8List encodeError(IpcProtocolFailure failure) =>
      _encode(IpcMessageKind.protocolError, null, failure.name);
  static Uint8List encode(UntrustedIpcEnvelope envelope) =>
      _encode(envelope.kind, envelope.requestId, envelope.payload);

  static Uint8List _encode(IpcMessageKind kind, String? id, String payload) {
    _checkId(kind, id);
    final length = _utf8Length(payload, _limit(kind));
    _checkPayload(kind, payload);
    final idLength = id?.length ?? 0;
    final frame = Uint8List(IpcEnvelopeLimits.headerBytes + idLength + length);
    frame.setRange(0, 4, const [83, 72, 73, 80]);
    frame[4] = IpcEnvelopeLimits.version;
    frame[5] = kind.index + 1;
    frame[6] = 1;
    frame[8] = idLength;
    ByteData.sublistView(frame).setUint32(12, length);
    if (id != null) frame.setRange(16, 16 + idLength, id.codeUnits);
    _writeUtf8(payload, frame, 16 + idLength);
    return frame;
  }
}

/// One incremental frame, no input views/output queue and no resynchronization.
final class IpcEnvelopeDecoder {
  final _header = Uint8List(IpcEnvelopeLimits.headerBytes);
  final _id = Uint8List(IpcEnvelopeLimits.idBytes);
  int _headerUsed = 0, _idUsed = 0, _bodyUsed = 0;
  int _idLength = 0, _payloadLength = 0;
  IpcMessageKind _kind = IpcMessageKind.request;
  Uint8List? _body;
  int _peakPayloadBytes = 0;
  bool _closed = false;
  bool get isClosed => _closed;
  int get bufferedBytes => _headerUsed + _idUsed + _bodyUsed;
  int get allocatedPayloadBytes => _body?.length ?? 0;
  int get peakPayloadBytes => _peakPayloadBytes;
  int get retainedByteCapacity =>
      _header.length + _id.length + allocatedPayloadBytes;

  IpcDecodeStep consume(Uint8List bytes, {int offset = 0}) {
    if (_closed) _reject(IpcProtocolFailure.closed);
    if (offset < 0 || offset > bytes.length) {
      _fail(IpcProtocolFailure.invalidFrame);
    }
    final start = offset;
    while (offset < bytes.length) {
      if (_headerUsed < _header.length) {
        _header[_headerUsed++] = bytes[offset++];
        if (_headerUsed < _header.length) continue;
        _admitHeader();
      }
      while (_idUsed < _idLength && offset < bytes.length) {
        final unit = bytes[offset++];
        if (!_idUnit(unit)) _fail(IpcProtocolFailure.invalidId);
        _id[_idUsed++] = unit;
      }
      if (_idUsed < _idLength) break;
      final body = _body ??= _allocatePayload();
      final available = bytes.length - offset;
      final needed = body.length - _bodyUsed;
      final count = available < needed ? available : needed;
      body.setRange(_bodyUsed, _bodyUsed + count, bytes, offset);
      offset += count;
      _bodyUsed += count;
      if (_bodyUsed < body.length) break;
      String payload;
      try {
        payload = utf8.decode(body, allowMalformed: false);
        // The SDK consumes one leading BOM; opaque payload text preserves it.
        if (body.length >= 3 &&
            body[0] == 0xef &&
            body[1] == 0xbb &&
            body[2] == 0xbf) {
          payload = '\uFEFF$payload';
        }
      } on FormatException {
        _fail(IpcProtocolFailure.invalidUtf8);
      }
      try {
        _checkPayload(_kind, payload);
      } on IpcProtocolException catch (error) {
        _fail(error.failure);
      }
      final id =
          _idLength == 0 ? null : String.fromCharCodes(_id, 0, _idLength);
      final envelope = UntrustedIpcEnvelope._(_kind, id, payload);
      _clear();
      return IpcDecodeStep._(offset - start, envelope);
    }
    return IpcDecodeStep._(offset - start, null);
  }

  void _admitHeader() {
    if (_header[0] != 83 ||
        _header[1] != 72 ||
        _header[2] != 73 ||
        _header[3] != 80) {
      _fail(IpcProtocolFailure.invalidFrame);
    }
    if (_header[4] != IpcEnvelopeLimits.version) {
      _fail(IpcProtocolFailure.unsupportedVersion);
    }
    if (_header[5] < 1 || _header[5] > 3) {
      _fail(IpcProtocolFailure.unsupportedMessage);
    }
    _kind = IpcMessageKind.values[_header[5] - 1];
    if (_header[6] != 1) _fail(IpcProtocolFailure.unsupportedEncoding);
    if (_header[7] != 0 ||
        _header[9] != 0 ||
        _header[10] != 0 ||
        _header[11] != 0) {
      _fail(IpcProtocolFailure.unsupportedFeature);
    }
    _idLength = _header[8];
    if ((_kind == IpcMessageKind.protocolError && _idLength != 0) ||
        (_kind != IpcMessageKind.protocolError &&
            (_idLength == 0 || _idLength > IpcEnvelopeLimits.idBytes))) {
      _fail(IpcProtocolFailure.invalidId);
    }
    _payloadLength = ByteData.sublistView(_header).getUint32(12);
    if (_payloadLength == 0 || _payloadLength > 0x7fffffff) {
      _fail(IpcProtocolFailure.invalidLength);
    }
    if (_payloadLength > _limit(_kind)) {
      _fail(IpcProtocolFailure.resourceLimit);
    }
  }

  Uint8List _allocatePayload() {
    if (_payloadLength > _peakPayloadBytes) _peakPayloadBytes = _payloadLength;
    return Uint8List(_payloadLength);
  }

  void finish() {
    if (_closed) _reject(IpcProtocolFailure.closed);
    if (bufferedBytes != 0) _fail(IpcProtocolFailure.truncated);
    close();
  }

  void close() {
    _closed = true;
    _clear();
  }

  void _clear() {
    _header.fillRange(0, _header.length, 0);
    _id.fillRange(0, _id.length, 0);
    _headerUsed = _idUsed = _bodyUsed = _idLength = _payloadLength = 0;
    _body = null;
  }

  Never _fail(IpcProtocolFailure failure) {
    close();
    _reject(failure);
  }
}
