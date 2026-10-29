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
      {required this.read,
      required this.newNonce,
      required this.validNonce,
      required this.write,
      required this.closeChannel,
      required this.invalidate,
      required this.connectionId,
      required this.current});
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
      unawaited(write(
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
            await write(1, {...message, 'type': 'pong'});
          } else if (message['type'] == 'pong' &&
              _ping != null &&
              message['nonce'] == _ping) {
            _ping = null;
          } else {
            androidLinkFail();
          }
        } else if (kind == 2) {
          final parsed = JsonRpcMessage.fromJson(message);
          onmessage
              ?.call(parsed); // SDK work does not occupy the control reader.
        } else {
          androidLinkFail();
        }
        _lastPeer = _elapsed.elapsed;
      }
    } finally {
      _closed = true;
      _timer?.cancel();
      invalidate();
      onclose?.call();
    }
  }

  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    if (_closed || !current()) androidLinkFail();
    await write(2, message.toJson());
  }

  @override
  Future<void> close() => _closing ??= () async {
        _closed = true;
        _timer?.cancel();
        invalidate();
        try {
          await closeChannel();
        } finally {
          try {
            await _pump;
          } catch (_) {/* Original channel close decides settlement. */}
          onclose?.call();
        }
      }();
}

Never androidLinkFail() => throw StateError('android_link_unavailable');

/// One authenticated Android connection over the original P10/P8 business path.
/// Caller completion does not release the slot: original approval, dispatch and
/// persistence must settle. Closing this port never shuts down the App host.
final class AndroidMcpPort implements VnextMcpPort {
  AndroidMcpPort(this.binding, this.current);
  final VnextMcpAppComposition binding;
  final bool Function() current;
  Completer<void>? _idle;
  ExternalCallControl? _control;
  Future<void>? _closing;
  bool _closed = false, _settlementFailed = false;
  int _requestId = 0;

  Future<void> get whenSettled => _idle?.future ?? Future<void>.value();

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (_closed || _settlementFailed || !current() || !available()) {
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
    final control = _control = ExternalCallControl(clock: binding.clock);
    final cancellation = cancelled.listen((_) => control.cancel());
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
          await cancellation.cancel();
          projection.finishStageApproval(clean: clean);
          _control = null;
          _idle = null;
          done.complete();
        }
      }());
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    _control?.cancel();
    return _closing ??= () async {
      await whenSettled;
      if (_settlementFailed) androidLinkFail();
    }();
  }
}
