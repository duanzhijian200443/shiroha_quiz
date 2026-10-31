import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart';
import '../data/external/windows_local_relay.dart';
import '../data/external/link/link_values.dart';
import 'vnext_mcp_server.dart';

/// Static MCP discovery never constructs a pipe, target adapter or credential.
final class LinkFrontendPort implements VnextMcpResponsePort {
  LinkFrontendPort({LocalRelayConnection Function()? openChannel})
      : _openChannel = openChannel ??
            (() => WindowsLocalRelay.openLinkBusiness(server: false));
  final LocalRelayConnection Function() _openChannel;
  LocalRelayConnection? _pipe;
  String? _run, _connection;
  int _id = 0;
  Object? _mcpRequestId;
  Object? _resultRequestId;
  int? _resultId;
  bool _closed = false, _busy = false, _retired = false;
  bool _cancelSent = false, _cancelRequested = false, _callSent = false;
  Future<void>? _closing;
  Future<void> _writing = Future<void>.value();
  Map<String, Object?> _failure(String code) =>
      vnextFailure(code, profileVersion: 3);
  Map<String, Object?> _frame(String kind,
          [Map<String, Object?> data = const {}]) =>
      {
        'version': 1,
        'runId': _run,
        'connectionId': _connection,
        'kind': kind,
        ...data
      };
  Future<void> _send(Map<String, Object?> message) {
    final sent = _writing.then((_) async {
      if (_closed || _pipe == null) throw const LocalRelayException();
      await _pipe!.send(message, const Duration(seconds: 5));
    });
    _writing = sent;
    unawaited(sent.then((_) {}, onError: (Object _, StackTrace __) {}));
    return sent;
  }

  Future<void> _attach() async {
    final pipe = _pipe = _openChannel();
    await pipe.accept();
    final hello = await pipe.receive(const Duration(seconds: 5));
    linkFields(
        hello, {'version', 'runId', 'connectionId', 'kind', 'capabilitySet'});
    if (hello['version'] != 1 ||
        hello['kind'] != 'hello' ||
        hello['capabilitySet'] != LinkLease.capabilitySet) {
      linkFail('invalidRequest');
    }
    _run = linkToken(hello['runId']);
    _connection = linkToken(hello['connectionId']);
    await _send(_frame('attach', {'capabilitySet': LinkLease.capabilitySet}));
    final response = await pipe.receive(const Duration(seconds: 12));
    linkFields(
        response, {'version', 'runId', 'connectionId', 'kind', 'leaseId'});
    if (response['version'] != 1 ||
        response['runId'] != _run ||
        response['connectionId'] != _connection ||
        response['kind'] != 'attached') {
      linkFail('unavailable');
    }
    linkToken(response['leaseId']);
  }

  /// Called ONLY for a cancellation notification actually read from MCP input.
  /// SDK AbortSignals also fire on EOF, so they cannot establish user intent.
  void cancelRequest(Object? requestId) {
    if (!_closed && _busy && requestId != null && requestId == _mcpRequestId) {
      _cancelRequested = true;
      _forwardCancellation();
    }
  }

  void _forwardCancellation() {
    if (_cancelRequested && _callSent && !_cancelSent && !_closed) {
      _cancelSent = true;
      unawaited(_send(_frame('cancel', {'id': _id}))
          .then((_) {}, onError: (Object _, StackTrace __) {}));
    }
  }

  Future<void> responseDelivered(Object? requestId) async {
    if (!_closed &&
        requestId != null &&
        requestId == _resultRequestId &&
        _resultId != null) {
      await _send(_frame('delivered', {'id': _resultId}));
      _resultRequestId = null;
      _resultId = null;
    }
  }

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available,
      Object? responseId}) async {
    if (_closed || _retired || !available() || responseId == null) {
      return _failure('unavailable');
    }
    if (_busy || _resultId != null) return _failure('busy');
    _busy = true;
    _cancelSent = false;
    _cancelRequested = false;
    _callSent = false;
    _mcpRequestId = responseId;
    var sent = false;
    try {
      if (_pipe == null) await _attach();
      if (_closed || !available()) return _failure('unavailable');
      if (_id >= 0x7fffffff) linkFail('unavailable');
      final id = ++_id;
      sent = true;
      await _send(
          _frame('call', {'id': id, 'tool': tool, 'arguments': arguments}));
      _callSent = true;
      _forwardCancellation();
      final response = await _pipe!.receive(
          tool == 'propose_generated_questions'
              ? const Duration(seconds: 150)
              : const Duration(seconds: 15));
      linkFields(response,
          {'version', 'runId', 'connectionId', 'kind', 'id', 'result'});
      if (_closed ||
          response['version'] != 1 ||
          response['runId'] != _run ||
          response['connectionId'] != _connection ||
          response['kind'] != 'result' ||
          response['id'] != id ||
          response['result'] is! Map<String, dynamic>) {
        linkFail('unavailable');
      }
      final result = response['result'] as Map<String, dynamic>;
      if (result.length != 4 ||
          result['profileVersion'] != 3 ||
          !validVnextSource(result['source']) ||
          !result.containsKey('data') ||
          !result.containsKey('error')) {
        linkFail('invalidResult');
      }
      _resultRequestId = responseId;
      _resultId = id;
      return result;
    } catch (error) {
      if (error is LocalRelayException && error.busy && !sent) {
        await _pipe?.close();
        _pipe = null;
        return _failure('busy');
      }
      _retired = _pipe != null;
      await _pipe?.close();
      _pipe = null;
      return _failure(sent && tool == 'propose_generated_questions'
          ? 'outcome_unknown'
          : 'unavailable');
    } finally {
      _busy = false;
      _callSent = false;
      _mcpRequestId = null;
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      await _pipe?.close();
      _pipe = null;
    }();
  }
}

/// The real SDK still owns MCP parsing/negotiation. This wrapper distinguishes
/// wire cancellation from the SDK's cancellation of handlers on transport EOF.
final class LinkFrontendTransport extends Transport {
  LinkFrontendTransport(this.inner, this.port);
  final Transport inner;
  final LinkFrontendPort port;
  @override
  String? get sessionId => inner.sessionId;
  @override
  Future<void> start() async {
    inner.onmessage = (message) {
      final value = message.toJson();
      if (value['method'] == 'notifications/cancelled' &&
          value['params'] is Map) {
        port.cancelRequest((value['params'] as Map)['requestId']);
      }
      onmessage?.call(message);
    };
    inner.onerror = (error) => onerror?.call(error);
    inner.onclose = () {
      unawaited(
          port.close().then((_) {}, onError: (Object _, StackTrace __) {}));
      onclose?.call();
    };
    await inner.start();
  }

  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    try {
      await inner.send(message, relatedRequestId: relatedRequestId);
      await port.responseDelivered(switch (message) {
        JsonRpcResponse() => message.id,
        JsonRpcError() => message.id,
        _ => null,
      });
    } catch (_) {
      await port.close();
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    await port.close();
    await inner.close();
  }
}
