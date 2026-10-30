import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart';

import '../application/external/external_invocation_core.dart';
import '../data/external/ipc_command_projection.dart';
import 'vnext_mcp_composition_root.dart';
import 'vnext_mcp_protocol_projection.dart';
import 'vnext_mcp_server.dart';

VnextMcpServer androidDeviceServer(VnextMcpPort port,
        {int profileVersion = 2}) =>
    VnextMcpServer(port,
        profileVersion: profileVersion,
        protocolServer: McpServer(
          const Implementation(name: 'shiroha_mcp_vnext', version: '0.2.0'),
          options: const McpServerOptions(
              instructions:
                  'Use the selected Android phone library. Call one tool at a time '
                  'and await its response. File access requires '
                  'local fileContent permission: list paginated choices under a '
                  'parent contextRef, then select returned fileRefs into a separate '
                  'File Context. Empty pages may have nextCursor; ordinals are '
                  'page-local. Retrieve hits, then read passageRef/cursor; report '
                  'coverage flags and never infer complete reading from hits. '
                  'Passage refs are not GeneratedEvidence. The current '
                  'phone policy may allow generated drafts or direct saving of new '
                  'batches. STAGED/NOT_REPORTED acknowledges publication only: query '
                  'get_question_proposal by the original submissionKey for lifecycle '
                  'and counts. Never replay an uncertain write. Local Review and direct consent belong '
                  'to the phone user. Submission v1 has schemaVersion:1, '
                  'submissionKey, requestedCount and items. Each item has exactly '
                  'itemKey, kind, stem, options, answer, explanation, evidenceKeys. '
                  'For singleChoice, stem/explanation and option content are node '
                  'arrays (for text: {type:"text",text:"..."}); explanation may be '
                  'null. Each option has optionKey,label,content; use 2..26 unique '
                  'options. answer is {type:"choice",optionKeys:[one optionKey]}. '
                  'Empty evidenceKeys:[] means uncited; do not add an uncited field. '
                  'itemKey/optionKey/submissionKey use '
                  '[A-Za-z0-9][A-Za-z0-9._-]{0,63}.',
              capabilities:
                  ServerCapabilities(tools: ServerCapabilitiesTools())),
        ));

/// Connection lifetime only. The App's P0/P15/Host owners remain outside it.
final class AndroidMcpTransport extends Transport {
  AndroidMcpTransport(
      {required this.port,
      required this.read,
      required this.newNonce,
      required this.validNonce,
      required this.write,
      required this.closeChannel,
      required this.invalidate,
      required this.connectionId,
      required this.current,
      this.onDiagnostic}) {
    port.attachTransport(close);
  }
  final AndroidMcpPort port;
  final Future<(int, Map<String, dynamic>)> Function() read;
  final String Function() newNonce;
  final bool Function(Object?) validNonce;
  final Future<void> Function(int, Map<String, dynamic>) write;
  final Future<void> Function() closeChannel;
  final void Function() invalidate;
  final String connectionId;
  final bool Function() current;
  final void Function(String cause)? onDiagnostic;
  bool _reportedClose = false;
  void _reportClose(String cause) {
    if (_reportedClose) return;
    _reportedClose = true;
    try {
      onDiagnostic?.call(cause);
    } catch (_) {/* Observation never changes the original close. */}
  }

  final _elapsed = Stopwatch()..start();
  Duration _lastPeer = Duration.zero;
  String? _ping;
  Timer? _timer;
  bool _closed = false, _sendingPing = false;
  bool _ioFailed = false;
  final _writes = <Future<void>>{};
  final _requests = <Object>{};
  Future<void>? _pump, _closing;
  @override
  String? get sessionId => null;

  @override
  Future<void> start() async {
    _lastPeer = _elapsed.elapsed;
    _pump = _read();
    unawaited(_pump!.catchError((Object _) {}));
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_closed) return;
      if (!current()) {
        _reportClose('authorization_changed');
        unawaited(close().catchError((Object _) {}));
        return;
      }
      if (_elapsed.elapsed - _lastPeer >= const Duration(seconds: 45)) {
        _reportClose('peer_timeout');
        unawaited(close().catchError((Object _) {}));
        return;
      }
      if (_ping != null || _sendingPing) return;
      _sendingPing = true;
      final nonce = _ping = newNonce();
      unawaited(_write(
              1, {'type': 'ping', 'connectionId': connectionId, 'nonce': nonce})
          .catchError((Object _) {
        unawaited(close().catchError((Object _) {}));
      }).whenComplete(() => _sendingPing = false));
    });
  }

  Future<void> _read() async {
    try {
      while (!_closed) {
        final (kind, message) = await read();
        if (!current()) androidLinkFail();
        if (kind == 1) {
          if (message.length != 3 ||
              !{'type', 'connectionId', 'nonce'}.every(message.containsKey)) {
            androidLinkFail();
          }
          if (message['connectionId'] != connectionId ||
              !validNonce(message['nonce'])) {
            androidLinkFail();
          }
          if (message['type'] == 'closing' &&
              port.binding.profileVersion == 3) {
            _reportClose('peer_closing');
            if (!await port.beginGracefulClose()) androidLinkFail();
            await _write(1, {...message, 'type': 'closed'});
            return; // finally closes the original channel after the acknowledgement.
          }
          if (message['type'] == 'ping') {
            await _write(1, {...message, 'type': 'pong'});
          } else if (message['type'] == 'pong' &&
              _ping != null &&
              message['nonce'] == _ping) {
            _ping = null;
          } else {
            androidLinkFail();
          }
        } else if (kind == 2) {
          final parsed = JsonRpcMessage.fromJson(message);
          if (parsed is JsonRpcRequest &&
              (_requests.length >= 2 || !_requests.add(parsed.id))) {
            // One original request and one bounded excess/protocol reply.
            // A duplicate ID must never settle another invocation's output.
            androidLinkFail();
          }
          onmessage
              ?.call(parsed); // SDK work does not occupy the control reader.
        } else {
          androidLinkFail();
        }
        _lastPeer = _elapsed.elapsed;
      }
    } catch (_) {
      _reportClose('read_failed');
      rethrow;
    } finally {
      _requestClose();
    }
  }

  void _requestClose() => unawaited(close().catchError((Object _) {}));

  Future<void> _write(int kind, Map<String, dynamic> value) async {
    if (_closed || !current()) androidLinkFail();
    final done = Completer<void>();
    _writes.add(done.future);
    try {
      await write(kind, value);
      if (_closed || !current()) androidLinkFail();
    } catch (_) {
      _reportClose('write_failed');
      _ioFailed = true;
      _requestClose();
      rethrow;
    } finally {
      done.complete();
      _writes.remove(done.future);
    }
  }

  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    try {
      if (_closed || !current()) androidLinkFail();
      await _write(2, message.toJson());
      final id = switch (message) {
        JsonRpcResponse() => message.id,
        JsonRpcError() => message.id,
        _ => null,
      };
      if (id != null) {
        _requests.remove(id);
        port.responseWritten(id);
      }
    } catch (_) {
      // Includes SDK response encoding, before any native write was started.
      _reportClose('output_failed');
      _ioFailed = true;
      port.outputFailed();
      _requestClose();
      rethrow;
    }
  }

  @override
  Future<void> close() => _closing ??= () async {
        _reportClose('local_close');
        _closed = true;
        _timer?.cancel();
        invalidate();
        port.withdraw();
        try {
          await closeChannel();
        } catch (_) {
          _ioFailed = true;
        } finally {
          try {
            await _pump;
          } catch (_) {/* Original channel close decides settlement. */}
          await Future.wait(_writes.toList());
          port.channelSettled(clean: !_ioFailed);
          onclose?.call();
        }
        if (_ioFailed) androidLinkFail();
      }();
}

Never androidLinkFail() => throw StateError('android_link_unavailable');

/// One authenticated Android connection over the original P10/P8 business path.
/// Caller completion does not release the slot: original approval, dispatch and
/// persistence AND final response I/O must settle. Closing this port never shuts
/// down the App host.
final class AndroidMcpPort implements VnextMcpResponsePort {
  AndroidMcpPort(this.binding, this.current);
  final VnextMcpAppComposition binding;
  final bool Function() current;
  Completer<void>? _idle;
  Completer<bool>? _businessSettled;
  ExternalCallControl? _control;
  Future<void>? _closing;
  Future<void> Function()? _closeTransport;
  final _channelSettled = Completer<bool>();
  Completer<bool>? _output;
  Object? _responseId;
  bool _closed = false, _settlementFailed = false;
  bool _cancelledBeforeClose = false;
  int _requestId = 0;

  Future<void> get whenSettled => _idle?.future ?? Future<void>.value();
  Future<bool> get whenBusinessSettled =>
      _businessSettled?.future ?? Future<bool>.value(true);

  Future<bool> beginGracefulClose() async {
    // Desktop stdin EOF is not cancellation of the outstanding MCP request.
    // Join original work, but never acknowledge a lost response as clean.
    withdraw();
    return await whenBusinessSettled && !_settlementFailed;
  }

  void attachTransport(Future<void> Function() close) {
    if (_closeTransport != null || _closed) androidLinkFail();
    _closeTransport = close;
  }

  void responseWritten(Object id) {
    if (!_closed && id == _responseId && _output?.isCompleted == false) {
      _output!.complete(true);
    }
  }

  void withdraw() {
    // Freeze the cause before closing the SDK: its onclose also aborts request
    // signals, which is not evidence of an explicit peer cancellation.
    if (_output?.isCompleted == false && !_cancelledBeforeClose) {
      _settlementFailed = true;
    }
    _closed = true;
    _control?.cancel();
  }

  void outputFailed() => _settlementFailed = true;

  /// Native close and all original Dart I/O have completed. Only an explicit
  /// cancellation observed for this request BEFORE withdrawal can substitute
  /// clean close for a response that the SDK suppresses.
  void channelSettled({required bool clean}) {
    clean = clean &&
        !_settlementFailed &&
        (_output?.isCompleted != false || _cancelledBeforeClose);
    if (!clean) _settlementFailed = true;
    if (!_channelSettled.isCompleted) _channelSettled.complete(clean);
    if (_output?.isCompleted == false) _output!.complete(clean);
  }

  Map<String, Object?> _failure(String code) => vnextFailure(code,
      profileVersion: binding.profileVersion, source: binding.source);

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available,
      Object? responseId}) async {
    if (responseId == null ||
        _closeTransport == null ||
        _closed ||
        _settlementFailed ||
        !current() ||
        !available()) {
      return _failure('unavailable');
    }
    if (!VnextMcpServer.schemasFor(binding.profileVersion).containsKey(tool)) {
      return _failure('unavailable');
    }
    if (_idle != null) return _failure('resourceLimit');
    final done = _idle = Completer<void>();
    final businessSettled = _businessSettled = Completer<bool>();
    final output = _output = Completer<bool>();
    _responseId = responseId;
    _cancelledBeforeClose = false;
    final control = _control = ExternalCallControl(clock: binding.clock);
    final cancellation = cancelled.listen((_) {
      if (!_closed) _cancelledBeforeClose = true;
      control.cancel();
      // The SDK suppresses a cancelled request's response. Close the original
      // channel instead of waiting forever for an output that will not exist.
      unawaited(_closeTransport!().catchError((Object _) {}));
    });
    final projection = OfflineIpcCommandProjection(
        host: binding.host, authentication: binding.authentication);
    try {
      final command = binding.profileVersion == 3
          ? VnextMcpCommand.parseUnified(tool, arguments)
          : VnextMcpCommand.parse(tool, arguments);
      final id = 'android_${++_requestId}';
      final result = await (binding.profileVersion == 3
              ? projection.invokeV4
              : projection.invokeV3)(command.request(id),
          binding: binding,
          stageApprovalWait: true,
          control: control,
          responseAvailable: () => !_closed && current() && available());
      if (result.frame == null) return _failure('outcome_unknown');
      try {
        return {
          ...command.response(VnextMcpCommand.decodeFrame(result.frame!), id),
          if (binding.profileVersion == 3) 'source': binding.source.toJson()
        };
      } catch (_) {
        return _failure('invalidResult');
      }
    } on FormatException {
      return _failure('invalidRequest');
    } catch (_) {
      return _failure('unavailable');
    } finally {
      // Cancellation may have returned above while the original work is still
      // running. This same connection retains custody and refuses replacement.
      unawaited(() async {
        var clean = false;
        try {
          await projection.whenSettled;
          clean = true;
        } catch (_) {
          _settlementFailed = true;
        } finally {
          businessSettled.complete(clean);
          clean = await output.future && clean;
          await cancellation.cancel();
          if (_closed) clean = await _channelSettled.future && clean;
          clean = clean && !_settlementFailed;
          if (!clean) _settlementFailed = true;
          projection.finishStageApproval(clean: clean);
          if (clean) {
            _control = null;
            _idle = null;
            _output = null;
            _responseId = null;
          }
          done.complete();
        }
      }());
    }
  }

  @override
  Future<void> close() {
    withdraw();
    return _closing ??= () async {
      try {
        await _closeTransport?.call();
      } catch (_) {
        _settlementFailed = true;
      }
      await whenSettled;
      if (_settlementFailed) androidLinkFail();
    }();
  }
}
