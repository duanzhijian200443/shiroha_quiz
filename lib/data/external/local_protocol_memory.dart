/// Pure memory wire candidate; no endpoint, TLS, discovery or MCP entrypoint.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../application/capabilities/capability.dart';
import '../../application/external/external_invocation_core.dart';
import '../../application/external/external_trust_core.dart';

enum MemoryConnectionState { awaitingAck, ready, closed }

enum MemoryFrameKind { control, business }

enum MemoryFrameFailure {
  length,
  resourceLimit,
  truncated,
  utf8,
  json,
  depth,
  message,
  closed
}

final class MemoryFrameException implements Exception {
  const MemoryFrameException(this.failure);
  final MemoryFrameFailure failure;
  @override
  String toString() => 'MemoryFrameException(${failure.name})';
}

final class MemoryHello {
  const MemoryHello(this.version, this.installation, this.generation);
  final int version;
  final String installation;
  final int generation;
}

final class MemoryProtocolHub {
  MemoryProtocolHub(
      {required this.trust,
      required this.invocations,
      required this.installation,
      this.version = 1,
      this.maxConnections = 8}) {
    if (installation.isEmpty ||
        installation.length > 128 ||
        version < 1 ||
        maxConnections < 1) {
      throw ArgumentError('Invalid candidate configuration');
    }
  }
  final ExternalTrustCore trust;
  final ExternalInvocationCore invocations;
  final String installation;
  final int version;
  final int maxConnections;
  final _connections = <MemoryProtocolConnection>{};
  int get connectionCount => _connections.length;

  MemoryProtocolConnection connect(Object authenticationAttempt) {
    if (_connections.length >= maxConnections) {
      throw const ExternalCoreException(ExternalFailure.resourceLimit);
    }
    // Every reconnect authenticates again. No clientInfo identity path exists.
    final peer = trust.authenticate(authenticationAttempt);
    final connection = MemoryProtocolConnection._(
        this, peer, MemoryHello(version, installation, trust.generation));
    _connections.add(connection);
    return connection;
  }
}

final class MemoryProtocolConnection {
  MemoryProtocolConnection._(this._hub, this._peer, this.hello);
  final MemoryProtocolHub _hub;
  final ExternalPeer _peer;
  final MemoryHello hello;
  MemoryConnectionState _state = MemoryConnectionState.awaitingAck;
  MemoryConnectionState get state => _state;
  ExternalFailure? _failure;
  ExternalFailure? get failure => _failure;
  ExternalSession? _session;

  void acknowledge(MemoryHello ack) {
    if (_state != MemoryConnectionState.awaitingAck) {
      _reject(ExternalFailure.invalidState);
    }
    if (ack.version != hello.version) _reject(ExternalFailure.protocolVersion);
    if (ack.installation != hello.installation) {
      _reject(ExternalFailure.installationMismatch);
    }
    if (ack.generation != hello.generation ||
        ack.generation != _hub.trust.generation) {
      _reject(ExternalFailure.staleGeneration);
    }
    try {
      _session = _hub.trust.openSession(_peer);
    } on ExternalCoreException catch (error) {
      _reject(error.failure);
    }
    _state = MemoryConnectionState.ready;
  }

  Never _reject(ExternalFailure failure) {
    _failure = failure;
    close();
    throw ExternalCoreException(failure);
  }

  void close() {
    _state = MemoryConnectionState.closed;
    _hub._connections.remove(this);
  }

  Future<ExternalInvocationResult<O>> invoke<I, O>({
    required ExternalAuthorizedContext context,
    required ExternalOperation<I, O> operation,
    required String requestId,
    required I input,
    required ExternalCallControl control,
    String? submissionKey,
  }) {
    final session = _session;
    if (_state != MemoryConnectionState.ready || session == null) {
      return Future.value(ExternalInvocationResult(
        phase: ExternalInvocationPhase.admission,
        status: CapabilityExecutionStatus.notStarted,
        effect: CapabilityEffect.none,
        failure: ExternalFailure.notReady,
        submissionKey: submissionKey,
      ));
    }
    return _hub.invocations.invoke(
        session: session,
        context: context,
        operation: operation,
        requestId: requestId,
        input: input,
        control: control,
        responseAvailable: () => _state == MemoryConnectionState.ready,
        submissionKey: submissionKey);
  }
}

/// Exact candidate envelopes, explicitly untrusted. They have no Principal or
/// authorization fields and are never dispatched by this decoder.
final class MemoryMessage {
  MemoryMessage._(this.kind, this.fields);
  final MemoryFrameKind kind;
  final Map<String, Object?> fields;
}

/// Header: one kind byte + unsigned big-endian 32-bit payload length.
/// High-bit, zero and over-limit lengths reject before body allocation.
/// Candidate limits only; this is not a frozen production wire format.
final class MemoryFrameDecoder {
  MemoryFrameDecoder(
      {this.controlLimit = 4096,
      this.businessLimit = 1048576,
      this.maxDepth = 16,
      this.maxFramesPerFeed = 16}) {
    if (controlLimit < 1 ||
        businessLimit < 1 ||
        controlLimit > 0x7fffffff ||
        businessLimit > 0x7fffffff ||
        maxDepth < 1 ||
        maxFramesPerFeed < 1) {
      throw ArgumentError('Invalid candidate limits');
    }
  }
  final int controlLimit;
  final int businessLimit;
  final int maxDepth;
  final int maxFramesPerFeed;
  final _header = Uint8List(5);
  int _headerUsed = 0;
  Uint8List? _body;
  int _bodyUsed = 0;
  bool _closed = false;
  int get allocatedBodyBytes => _body?.length ?? 0;
  int get bufferedBytes => _headerUsed + _bodyUsed;
  bool get isClosed => _closed;

  List<MemoryMessage> feed(Uint8List bytes) {
    if (_closed) throw const MemoryFrameException(MemoryFrameFailure.closed);
    final messages = <MemoryMessage>[];
    var offset = 0;
    try {
      while (offset < bytes.length) {
        if (messages.length >= maxFramesPerFeed) {
          _fail(MemoryFrameFailure.resourceLimit);
        }
        if (_body == null) {
          while (_headerUsed < 5 && offset < bytes.length) {
            _header[_headerUsed++] = bytes[offset++];
          }
          if (_headerUsed < 5) break;
          if (_header[0] > 1) _fail(MemoryFrameFailure.message);
          final length = ByteData.sublistView(_header).getUint32(1);
          if (length == 0 || length > 0x7fffffff) {
            _fail(MemoryFrameFailure.length);
          }
          final limit = _header[0] == 0 ? controlLimit : businessLimit;
          if (length > limit) _fail(MemoryFrameFailure.resourceLimit);
          _body = Uint8List(length);
        }
        final body = _body!;
        final available = bytes.length - offset;
        final needed = body.length - _bodyUsed;
        final copied = available < needed ? available : needed;
        body.setRange(_bodyUsed, _bodyUsed + copied, bytes, offset);
        _bodyUsed += copied;
        offset += copied;
        if (_bodyUsed == body.length) {
          final kind = MemoryFrameKind.values[_header[0]];
          messages.add(_decode(kind, body));
          _body = null;
          _bodyUsed = 0;
          _headerUsed = 0;
        }
      }
      return List.unmodifiable(messages);
    } on MemoryFrameException {
      rethrow;
    } catch (_) {
      _fail(MemoryFrameFailure.json);
    }
  }

  void finish() {
    if (_closed) throw const MemoryFrameException(MemoryFrameFailure.closed);
    if (_headerUsed != 0 || _body != null) _fail(MemoryFrameFailure.truncated);
    _closed = true;
  }

  Never _fail(MemoryFrameFailure failure) {
    _closed = true;
    _body = null;
    _bodyUsed = 0;
    _headerUsed = 0;
    throw MemoryFrameException(failure);
  }

  MemoryMessage _decode(MemoryFrameKind kind, Uint8List body) {
    String source;
    try {
      source = utf8.decode(body, allowMalformed: false);
    } catch (_) {
      _fail(MemoryFrameFailure.utf8);
    }
    // Bounded lexical pass, following generatedDecode's existing approach.
    // Per-object sets reject duplicate keys before jsonDecode folds them.
    // The SDK decodes key escapes and remains the final JSON syntax authority;
    // this pass does not parse values or mint any trusted authority.
    final stack = <Set<String>?>[];
    for (var i = 0; i < source.length; i++) {
      final unit = source.codeUnitAt(i);
      if (unit == 34) {
        final start = i++;
        while (i < source.length && source.codeUnitAt(i) != 34) {
          if (source.codeUnitAt(i) == 92) i++;
          i++;
        }
        if (i >= source.length) _fail(MemoryFrameFailure.json);
        var next = i + 1;
        while (next < source.length && ' \r\n\t'.contains(source[next])) {
          next++;
        }
        if (next < source.length && source.codeUnitAt(next) == 58) {
          if (stack.isEmpty || stack.last == null) {
            _fail(MemoryFrameFailure.json);
          }
          String key;
          try {
            key = jsonDecode(source.substring(start, i + 1)) as String;
          } on FormatException {
            _fail(MemoryFrameFailure.json);
          }
          if (!stack.last!.add(key)) _fail(MemoryFrameFailure.json);
        }
      } else if (unit == 123 || unit == 91) {
        stack.add(unit == 123 ? <String>{} : null);
        if (stack.length > maxDepth) _fail(MemoryFrameFailure.depth);
      } else if (unit == 125 || unit == 93) {
        if (stack.isEmpty || (unit == 125) != (stack.last != null)) {
          _fail(MemoryFrameFailure.json);
        }
        stack.removeLast();
      }
    }
    if (stack.isNotEmpty) _fail(MemoryFrameFailure.json);
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      _fail(MemoryFrameFailure.json);
    }
    if (decoded is! Map<String, dynamic>) {
      _fail(MemoryFrameFailure.message);
    }
    final type = decoded['type'];
    final required = switch ((kind, type)) {
      (MemoryFrameKind.control, 'hello') ||
      (MemoryFrameKind.control, 'hello_ack') =>
        {'type', 'version', 'installation', 'generation'},
      (MemoryFrameKind.control, 'cancel') => {'type', 'requestId'},
      (MemoryFrameKind.business, 'request') => {
          'type',
          'requestId',
          'capability',
          'context',
          'body'
        },
      _ => <String>{},
    };
    if (required.isEmpty ||
        decoded.length != required.length ||
        !required.every(decoded.containsKey)) {
      _fail(MemoryFrameFailure.message);
    }
    bool token(Object? value) =>
        value is String && value.isNotEmpty && value.length <= 128;
    if (type == 'hello' || type == 'hello_ack') {
      if (decoded['version'] is! int ||
          (decoded['version'] as int) < 1 ||
          decoded['generation'] is! int ||
          (decoded['generation'] as int) < 1 ||
          !token(decoded['installation'])) {
        _fail(MemoryFrameFailure.message);
      }
    } else {
      if (!token(decoded['requestId'])) _fail(MemoryFrameFailure.message);
      if (type == 'request' &&
          (!token(decoded['capability']) ||
              !token(decoded['context']) ||
              decoded['body'] is! Map<String, dynamic>)) {
        _fail(MemoryFrameFailure.message);
      }
    }
    return MemoryMessage._(kind, _freeze(decoded) as Map<String, Object?>);
  }

  Object? _freeze(Object? value) => switch (value) {
        Map<String, dynamic> map => Map<String, Object?>.unmodifiable(
            map.map((key, value) => MapEntry(key, _freeze(value)))),
        List list => List<Object?>.unmodifiable(list.map(_freeze)),
        _ => value,
      };

  Uint8List encode(MemoryFrameKind kind, Map<String, Object?> fields) {
    final payload = utf8.encode(jsonEncode(fields));
    final limit =
        kind == MemoryFrameKind.control ? controlLimit : businessLimit;
    if (payload.isEmpty || payload.length > limit) {
      throw const MemoryFrameException(MemoryFrameFailure.resourceLimit);
    }
    // Validate with identical limits on an isolated instance. Its fail-closed
    // state must never discard this instance's partially received frame.
    MemoryFrameDecoder(
      controlLimit: controlLimit,
      businessLimit: businessLimit,
      maxDepth: maxDepth,
      maxFramesPerFeed: maxFramesPerFeed,
    )._decode(kind, Uint8List.fromList(payload));
    final frame = Uint8List(5 + payload.length);
    frame[0] = kind.index;
    ByteData.sublistView(frame).setUint32(1, payload.length);
    frame.setRange(5, frame.length, payload);
    return frame;
  }
}
