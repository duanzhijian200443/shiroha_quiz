import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart';
import '../data/external/windows_local_relay.dart';
import '../data/external/link/link_values.dart';
import '../data/external/link/link_call_diagnostics.dart';
import 'vnext_mcp_server.dart';

/// External JSON-RPC identities live only in this bounded in-memory map.
final class LinkFrontendDiagnostics {
  LinkFrontendDiagnostics(this.calls, {this.lifecycleObserver});
  final LinkCallDiagnostics calls;
  final LinkLifecycleObserver? lifecycleObserver;
  void lifecycle(
      LinkLifecycleCheckpoint checkpoint, LinkLifecycleOutcome outcome) {
    try {
      lifecycleObserver?.call(checkpoint, outcome);
    } catch (_) {
      calls.incomplete = true;
    }
  }

  final _requests = <Object, LinkCallTrace>{};
  void received(Map<String, dynamic> message) {
    if (message['method'] != 'tools/call') return;
    final params = message['params'];
    final trace = calls.begin(params is Map ? params['name'] : null,
        params is Map ? params['arguments'] : null);
    if (trace == null) return;
    trace.stage(LinkCallStage.admission, LinkCallOutcome.entered);
    final id = message['id'];
    if ((id is! String && id is! int) || _requests.containsKey(id)) {
      calls.unbound();
      calls.finish(trace);
      return;
    }
    _requests[id] = trace;
  }

  LinkCallTrace? request(Object? id) => _requests[id];
  void finish(Object? id) {
    calls.finish(_requests.remove(id));
  }

  void closed() {
    for (final trace in _requests.values) {
      trace.stage(LinkCallStage.deliveryAck, LinkCallOutcome.unknown,
          LinkCallCause.eof);
    }
    calls.close();
    _requests.clear();
  }
}

/// Static MCP discovery never constructs a pipe, target adapter or credential.
final class LinkFrontendPort implements VnextMcpResponsePort {
  LinkFrontendPort(
      {LocalRelayConnection Function()? openChannel, this.diagnostics})
      : _openChannel = openChannel ??
            (() => WindowsLocalRelay.openLinkBusiness(server: false));
  final LocalRelayConnection Function() _openChannel;
  final LinkFrontendDiagnostics? diagnostics;
  String? _diagnosticLease;
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

  Future<void> _attach([LinkCallTrace? diagnostic]) async {
    final pipe = _pipe = _openChannel();
    await pipe.accept();
    final hello = await pipe.receive(const Duration(seconds: 5));
    _fields(
        hello,
        {'version', 'runId', 'connectionId', 'kind', 'capabilitySet'},
        diagnostic,
        LinkCallStage.attach);
    if (hello['version'] != 1 ||
        hello['kind'] != 'hello' ||
        hello['capabilitySet'] != LinkLease.capabilitySet) {
      diagnostic?.stage(LinkCallStage.attach, LinkCallOutcome.rejected,
          LinkCallCause.invalidFrame);
      linkFail('invalidRequest');
    }
    _run = _token(hello['runId'], diagnostic);
    _connection = _token(hello['connectionId'], diagnostic);
    diagnostic?.bind(run: _run, connection: _connection);
    await _send(_frame('attach', {'capabilitySet': LinkLease.capabilitySet}));
    final response = await pipe.receive(const Duration(seconds: 12));
    _fields(response, {'version', 'runId', 'connectionId', 'kind', 'leaseId'},
        diagnostic, LinkCallStage.attach);
    if (response['version'] != 1 ||
        response['runId'] != _run ||
        response['connectionId'] != _connection ||
        response['kind'] != 'attached') {
      diagnostic?.stage(LinkCallStage.attach, LinkCallOutcome.rejected,
          LinkCallCause.invalidFrame);
      linkFail('unavailable');
    }
    _token(response['leaseId'], diagnostic);
    if (diagnostics != null) _diagnosticLease = response['leaseId'] as String;
    diagnostic?.bind(lease: _diagnosticLease);
  }

  void _fields(Map value, Set<String> fields, LinkCallTrace? diagnostic,
      LinkCallStage stage) {
    try {
      linkFields(value, fields);
    } catch (_) {
      diagnostic?.stage(
          stage, LinkCallOutcome.rejected, LinkCallCause.invalidFrame);
      rethrow;
    }
  }

  String _token(Object? value, LinkCallTrace? diagnostic) {
    try {
      return linkToken(value);
    } catch (_) {
      diagnostic?.stage(LinkCallStage.attach, LinkCallOutcome.rejected,
          LinkCallCause.invalidFrame);
      rethrow;
    }
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
      final diagnostic = diagnostics?.request(requestId);
      diagnostic?.stage(LinkCallStage.deliveryAck, LinkCallOutcome.entered);
      try {
        await _send(_frame('delivered', {'id': _resultId}));
        diagnostic?.stage(LinkCallStage.deliveryAck, LinkCallOutcome.succeeded);
      } catch (_) {
        diagnostic?.stage(LinkCallStage.deliveryAck, LinkCallOutcome.failed,
            LinkCallCause.sendFailed);
        rethrow;
      }
      _resultRequestId = null;
      _resultId = null;
    }
  }

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available,
      Object? responseId}) async {
    final diagnostic = diagnostics?.request(responseId);
    if (_closed || _retired || !available() || responseId == null) {
      diagnostic?.stage(LinkCallStage.admission, LinkCallOutcome.rejected,
          LinkCallCause.unavailable);
      return _failure('unavailable');
    }
    if (_busy || _resultId != null) {
      diagnostic?.stage(LinkCallStage.admission, LinkCallOutcome.rejected,
          LinkCallCause.busy);
      return _failure('busy');
    }
    diagnostic?.stage(LinkCallStage.admission, LinkCallOutcome.succeeded);
    _busy = true;
    _cancelSent = false;
    _cancelRequested = false;
    _callSent = false;
    _mcpRequestId = responseId;
    var sent = false;
    var observedStage = LinkCallStage.attach;
    try {
      diagnostic?.stage(observedStage, LinkCallOutcome.entered);
      if (_pipe == null) await _attach(diagnostic);
      diagnostic?.bind(
          run: _run, connection: _connection, lease: _diagnosticLease);
      diagnostic?.stage(observedStage, LinkCallOutcome.succeeded);
      if (_closed || !available()) {
        diagnostic?.stage(LinkCallStage.admission, LinkCallOutcome.rejected,
            LinkCallCause.unavailable);
        return _failure('unavailable');
      }
      if (_id >= 0x7fffffff) linkFail('unavailable');
      final id = ++_id;
      diagnostic?.bind(call: id);
      observedStage = LinkCallStage.ipcSend;
      diagnostic?.stage(observedStage, LinkCallOutcome.entered);
      sent = true;
      await _send(
          _frame('call', {'id': id, 'tool': tool, 'arguments': arguments}));
      _callSent = true;
      diagnostic?.stage(observedStage, LinkCallOutcome.succeeded);
      _forwardCancellation();
      observedStage = LinkCallStage.ipcReceive;
      diagnostic?.stage(observedStage, LinkCallOutcome.entered);
      final response = await _pipe!.receive(
          tool == 'propose_generated_questions'
              ? const Duration(seconds: 150)
              : const Duration(seconds: 15));
      _fields(
          response,
          {'version', 'runId', 'connectionId', 'kind', 'id', 'result'},
          diagnostic,
          observedStage);
      if (_closed ||
          response['version'] != 1 ||
          response['runId'] != _run ||
          response['connectionId'] != _connection ||
          response['kind'] != 'result' ||
          response['id'] != id ||
          response['result'] is! Map<String, dynamic>) {
        diagnostic?.stage(observedStage, LinkCallOutcome.rejected,
            _closed ? LinkCallCause.unavailable : LinkCallCause.invalidFrame);
        linkFail('unavailable');
      }
      final result = response['result'] as Map<String, dynamic>;
      diagnostic?.stage(observedStage, LinkCallOutcome.succeeded);
      observedStage = LinkCallStage.resultValidate;
      diagnostic?.stage(observedStage, LinkCallOutcome.entered);
      if (result.length != 4 ||
          result['profileVersion'] != 3 ||
          !validVnextSource(result['source']) ||
          !result.containsKey('data') ||
          !result.containsKey('error')) {
        linkFail('invalidResult');
      }
      _resultRequestId = responseId;
      _resultId = id;
      diagnostic?.stage(observedStage, LinkCallOutcome.succeeded);
      return result;
    } catch (error) {
      final priorCause = diagnostic?.stages[observedStage.index][1];
      if (priorCause == null ||
          priorCause == LinkCallCause.none.index ||
          priorCause == LinkCallCause.unknown.index) {
        diagnostic?.stage(
            observedStage,
            LinkCallOutcome.failed,
            error is LocalRelayException && error.busy
                ? LinkCallCause.busy
                : error is TimeoutException
                    ? LinkCallCause.timeout
                    : error is LinkException && error.code == 'invalidResult'
                        ? LinkCallCause.invalidResult
                        : error is LinkException &&
                                error.code == 'invalidRequest'
                            ? LinkCallCause.invalidFrame
                            : error is LocalRelayException
                                ? LinkCallCause.unavailable
                                : LinkCallCause.unknown);
      }
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
      diagnostics?.lifecycle(LinkLifecycleCheckpoint.portCloseEnter,
          LinkLifecycleOutcome.observed);
      try {
        await _pipe?.close();
        _pipe = null;
        diagnostics?.lifecycle(LinkLifecycleCheckpoint.portCloseSettled,
            LinkLifecycleOutcome.completed);
      } catch (_) {
        diagnostics?.lifecycle(LinkLifecycleCheckpoint.portCloseSettled,
            LinkLifecycleOutcome.failed);
        rethrow;
      }
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
      port.diagnostics?.received(value);
      if (value['method'] == 'notifications/cancelled' &&
          value['params'] is Map) {
        port.cancelRequest((value['params'] as Map)['requestId']);
      }
      onmessage?.call(message);
    };
    inner.onerror = (error) {
      port.diagnostics?.calls.unbound();
      onerror?.call(error);
    };
    inner.onclose = () {
      port.diagnostics?.lifecycle(LinkLifecycleCheckpoint.transportOnclose,
          LinkLifecycleOutcome.observed);
      port.diagnostics?.closed();
      unawaited(
          port.close().then((_) {}, onError: (Object _, StackTrace __) {}));
      onclose?.call();
    };
    await inner.start();
  }

  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    final requestId = switch (message) {
      JsonRpcResponse() => message.id,
      JsonRpcError() => message.id,
      _ => null,
    };
    final diagnostic = port.diagnostics?.request(requestId);
    if (diagnostic != null &&
        diagnostic.stages[LinkCallStage.admission.index][0] ==
            LinkCallOutcome.entered.index) {
      final value = message.toJson();
      final error = value['error'];
      final code = error is Map ? error['code'] : null;
      diagnostic.stage(
          LinkCallStage.admission,
          LinkCallOutcome.rejected,
          switch (code) {
            -32602 => LinkCallCause.invalidParams,
            -32600 => LinkCallCause.invalidRequest,
            -32601 => LinkCallCause.methodNotFound,
            -32603 => LinkCallCause.internalError,
            _ => LinkCallCause.prePortRejected,
          });
    }
    diagnostic?.stage(LinkCallStage.outputSend, LinkCallOutcome.entered);
    try {
      await inner.send(message, relatedRequestId: relatedRequestId);
      diagnostic?.stage(LinkCallStage.outputSend, LinkCallOutcome.succeeded);
      await port.responseDelivered(switch (message) {
        JsonRpcResponse() => message.id,
        JsonRpcError() => message.id,
        _ => null,
      });
    } catch (_) {
      if (diagnostic?.stages[LinkCallStage.outputSend.index][0] !=
          LinkCallOutcome.succeeded.index) {
        diagnostic?.stage(LinkCallStage.outputSend, LinkCallOutcome.failed,
            LinkCallCause.sendFailed);
      }
      await port.close();
      rethrow;
    } finally {
      port.diagnostics?.finish(requestId);
    }
  }

  @override
  Future<void> close() async {
    await port.close();
    await inner.close();
    port.diagnostics?.closed();
  }
}
