import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart';

import '../application/external/external_invocation_core.dart';
import '../data/external/ipc_command_projection.dart';
import 'vnext_mcp_composition_root.dart';
import 'vnext_mcp_protocol_projection.dart';
import 'vnext_mcp_server.dart';

VnextMcpServer androidDeviceServer(VnextMcpPort port) => VnextMcpServer(port,
    protocolServer: McpServer(
      const Implementation(name: 'shiroha_mcp_vnext', version: '0.2.0'),
      options: const McpServerOptions(
          instructions:
              'Use the selected Android phone question library. The current '
              'phone policy may allow generated drafts or direct saving of new '
              'batches. STAGED/NOT_REPORTED acknowledges publication only: query '
              'get_question_proposal by the original submissionKey for lifecycle '
              'and counts. Never replay an uncertain write. File tools and file '
              'selection are unavailable. Local Review and direct consent belong '
              'to the phone user.',
          capabilities: ServerCapabilities(tools: ServerCapabilitiesTools())),
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
      required this.current}) {
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
      if (!current() ||
          _elapsed.elapsed - _lastPeer >= const Duration(seconds: 45)) {
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
    if (_closed || !current()) androidLinkFail();
    try {
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
      _ioFailed = true;
      _requestClose();
      rethrow;
    }
  }

  @override
  Future<void> close() => _closing ??= () async {
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
  ExternalCallControl? _control;
  Future<void>? _closing;
  Future<void> Function()? _closeTransport;
  final _channelSettled = Completer<bool>();
  Completer<bool>? _output;
  Object? _responseId;
  bool _closed = false, _settlementFailed = false;
  int _requestId = 0;

  Future<void> get whenSettled => _idle?.future ?? Future<void>.value();

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
    _closed = true;
    _control?.cancel();
  }

  /// Native close and all original Dart I/O have completed. Cancellation can
  /// suppress the SDK response; only this acknowledged close can settle it.
  void channelSettled({required bool clean}) {
    if (!clean) _settlementFailed = true;
    if (!_channelSettled.isCompleted) _channelSettled.complete(clean);
    if (_output?.isCompleted == false) _output!.complete(clean);
  }

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
      return vnextFailure('unavailable');
    }
    if (!const {
          'open_generation_context',
          'search_questions',
          'get_question_detail',
          'propose_generated_questions',
          'get_question_proposal',
        }.contains(tool) ||
        (tool == 'open_generation_context' &&
            (arguments.containsKey('contextRef') ||
                arguments.containsKey('fileRefs')))) {
      return vnextFailure('unavailable');
    }
    if (_idle != null) return vnextFailure('resourceLimit');
    final done = _idle = Completer<void>();
    final output = _output = Completer<bool>();
    _responseId = responseId;
    final control = _control = ExternalCallControl(clock: binding.clock);
    final cancellation = cancelled.listen((_) {
      control.cancel();
      // The SDK suppresses a cancelled request's response. Close the original
      // channel instead of waiting forever for an output that will not exist.
      unawaited(_closeTransport!().catchError((Object _) {}));
    });
    final projection = OfflineIpcCommandProjection(
        host: binding.host, authentication: binding.authentication);
    try {
      final command = VnextMcpCommand.parse(tool, arguments);
      final id = 'android_${++_requestId}';
      final result = await projection.invokeV3(command.request(id),
          binding: binding,
          stageApprovalWait: true,
          control: control,
          responseAvailable: () => !_closed && current() && available());
      if (result.frame == null) return vnextFailure('outcome_unknown');
      try {
        return command.response(VnextMcpCommand.decodeFrame(result.frame!), id);
      } catch (_) {
        return vnextFailure('invalidResult');
      }
    } on FormatException {
      return vnextFailure('invalidRequest');
    } catch (_) {
      return vnextFailure('unavailable');
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
