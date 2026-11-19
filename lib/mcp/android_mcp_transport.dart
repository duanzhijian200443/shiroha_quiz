import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart';

import '../application/external/external_invocation_core.dart';
import '../core/observability/log_writer.dart';
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

enum _IoFailure { read, heartbeatWrite, output, closeControl, nativeClose }

/// Connection lifetime only. The App's P0/P15/Host owners remain outside it.
final class AndroidMcpTransport extends Transport {
  AndroidMcpTransport(
      {required this.port,
      required this.read,
      required this.newNonce,
      required this.validNonce,
      required this.write,
      required this.closeChannel,
      this.nativeCloseTrace,
      this.peerClosed,
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
  final Map<String, Object>? Function()? nativeCloseTrace;
  final Future<void> Function()? peerClosed;
  final void Function() invalidate;
  final String connectionId;
  final bool Function() current;
  final _elapsed = Stopwatch()..start();
  Duration _lastPeer = Duration.zero;
  String? _ping;
  Timer? _timer;
  bool _closed = false, _sendingPing = false;
  _IoFailure? _ioFailure;
  int? _dartClosedAtUs;
  ({int atUs, bool closed, String stage, String category})? _dartReadFailure;
  bool _lateHeartbeatReply = false;
  bool _withdrawing = false, _peerClosing = false;
  final _handshake = Completer<bool>();
  final _writes = <Future<void>>{};
  final _requests = <Object>{};
  Future<void>? _pump, _closing, _withdrawal;
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
        unawaited(withdraw().catchError((Object _) {}));
        return;
      }
      if (_elapsed.elapsed - _lastPeer >= const Duration(seconds: 45)) {
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
    Map<String, dynamic>? closingRequest;
    Timer? pongDeadline;
    var stage = 'awaitRead';
    try {
      while (!_closed) {
        stage = 'awaitRead';
        final (kind, message) = await read();
        if (_closed) return;
        stage = 'handleFrame';
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
            if (_peerClosing) androidLinkFail();
            _peerClosing = true;
            _timer?.cancel();
            closingRequest = message;
            if (!current() && !_withdrawing) {
              unawaited(withdraw().catchError((Object _) {}));
            }
            if (_ping != null) {
              pongDeadline = Timer(const Duration(seconds: 5), () {
                _ioFailure ??= _IoFailure.closeControl;
                _requestClose();
              });
            }
          } else {
            if (!current() && !_withdrawing) {
              if (port.binding.profileVersion != 3) androidLinkFail();
              unawaited(withdraw().catchError((Object _) {}));
            }
            if (message['type'] == 'ping') {
              await _write(1, {...message, 'type': 'pong'},
                  closing: _withdrawing || _peerClosing);
            } else if (message['type'] == 'pong' &&
                _ping != null &&
                message['nonce'] == _ping) {
              _ping = null;
            } else {
              androidLinkFail();
            }
          }
        } else if (kind == 2) {
          if (_peerClosing || _withdrawing || !current()) androidLinkFail();
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
        if (closingRequest != null && _ping == null) {
          pongDeadline?.cancel();
          await port.beginGracefulClose();
          await Future.wait(_writes.toList());
          if (_ioFailure != null) androidLinkFail();
          await _write(1, {...closingRequest, 'type': 'closed'}, closing: true);
          await peerClosed?.call();
          if (_closed) androidLinkFail();
          _handshake.complete(true);
          return;
        }
      }
    } catch (error) {
      if (port.binding.profileVersion == 2) {
        _dartReadFailure = (
          atUs: _elapsed.elapsedMicroseconds,
          closed: _closed,
          stage: stage,
          category: switch (error) {
            FormatException() => 'format',
            StateError() => 'state',
            TypeError() => 'type',
            _ => 'other',
          },
        );
      }
      if (!_closed) _ioFailure ??= _IoFailure.read;
      rethrow;
    } finally {
      pongDeadline?.cancel();
      _requestClose();
    }
  }

  void _requestClose() => unawaited(close().catchError((Object _) {}));

  Future<void> _write(int kind, Map<String, dynamic> value,
      {bool closing = false}) async {
    bool allowed() =>
        !_closed &&
        (closing && port.binding.profileVersion == 3 ||
            !_withdrawing && current());
    if (!allowed()) androidLinkFail();
    final heartbeat = value['type'] == 'ping' || value['type'] == 'pong';
    final legacyHeartbeat =
        port.binding.profileVersion == 2 && kind == 1 && heartbeat;
    final done = Completer<void>();
    _writes.add(done.future);
    try {
      await write(kind, value);
      if (!allowed()) {
        if (!legacyHeartbeat) androidLinkFail();
        _lateHeartbeatReply = true;
        _requestClose();
      }
    } catch (_) {
      _ioFailure ??= kind == 2
          ? _IoFailure.output
          : heartbeat
              ? _IoFailure.heartbeatWrite
              : _IoFailure.closeControl;
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
      if (_closed || _withdrawing || !current()) androidLinkFail();
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
      _ioFailure ??= _IoFailure.output;
      port.outputFailed();
      _requestClose();
      rethrow;
    }
  }

  /// Withdraw business immediately, retaining only this channel's CLOSE.
  Future<void> withdraw() {
    if (port.binding.profileVersion != 3) return close();
    if (_withdrawal != null) return _withdrawal!;
    _withdrawing = true;
    _timer?.cancel();
    invalidate();
    port.suspend();
    return _withdrawal = () async {
      try {
        await port.beginGracefulClose();
        if (!_peerClosing) {
          await _write(
              1,
              {
                'type': 'closing',
                'connectionId': connectionId,
                'nonce': newNonce()
              },
              closing: true);
        }
        if (!await _handshake.future.timeout(const Duration(seconds: 5))) {
          androidLinkFail();
        }
      } catch (_) {
        _ioFailure ??= _IoFailure.closeControl;
        rethrow;
      } finally {
        await close();
      }
    }();
  }

  @override
  Future<void> close() => _closing ??= () async {
        _closed = true;
        _dartClosedAtUs = _elapsed.elapsedMicroseconds;
        if (!_handshake.isCompleted) _handshake.complete(false);
        _timer?.cancel();
        invalidate();
        port.withdraw();
        final pendingWrites = _writes.length;
        var nativeClosed = false;
        try {
          await closeChannel();
          nativeClosed = true;
        } catch (_) {
          _ioFailure ??= _IoFailure.nativeClose;
        } finally {
          try {
            await _pump;
          } catch (_) {/* Original channel close decides settlement. */}
          await Future.wait(_writes.toList());
          port.channelSettled(clean: _ioFailure == null);
          if (port.binding.profileVersion == 2) {
            _recordLegacyClose(nativeClosed, pendingWrites);
          }
          onclose?.call();
        }
        if (_ioFailure != null) androidLinkFail();
      }();

  void _recordLegacyClose(bool nativeClosed, int pendingWrites) {
    try {
      final failure = _dartReadFailure;
      LogWriter.info('Android Profile 2 transport close', module: 'MCP', data: {
        'nativeClose': nativeClosed ? 'joined' : 'failed',
        'reader': _pump == null ? 'notStarted' : 'joined',
        'writersAtClose': pendingWrites,
        'writersJoined': true,
        'lateHeartbeatReply': _lateHeartbeatReply,
        'firstIoFailure': _ioFailure?.name ?? 'none',
        'dartClosedAtUs': _dartClosedAtUs,
        if (failure != null) ...{
          'dartReadFailedAtUs': failure.atUs,
          'dartReadSawClosed': failure.closed,
          'dartReadStage': failure.stage,
          'dartReadError': failure.category,
        },
        if (nativeCloseTrace?.call() case final trace?) 'nativeTrace': trace,
      });
    } catch (_) {/* Diagnostics do not own connection settlement. */}
  }
}

Never androidLinkFail() => throw StateError('android_link_unavailable');

/// One authenticated Android connection over the original P10/P8 business path.
/// Caller completion does not release the slot: original approval, dispatch and
/// persistence AND final response I/O must settle. Closing this port never shuts
/// down the App host.
// Shared response-settlement owner. The Android name remains a compatibility
// spelling; this pure SDK/P10 port requires no native Android host or device
// selector and can be injected by either target's trusted composition.
typedef VnextMcpBusinessPort = AndroidMcpPort;

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
  Object? _connectionSession;
  Future<void> Function()? _invalidateReferences;
  bool _closed = false, _settlementFailed = false;
  bool _draining = false;
  bool _cancelledBeforeClose = false;
  int _requestId = 0;

  Future<void> get whenSettled => _idle?.future ?? Future<void>.value();

  /// Peer EOF withdraws new admission; it is NOT a user cancellation. Join the
  /// original operation AND output before acknowledging CLOSE.
  Future<void> beginGracefulClose() async {
    _draining = true;
    if (_settlementFailed) androidLinkFail();
    await whenSettled;
    if (_settlementFailed) androidLinkFail();
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

  void suspend() {
    _draining = true;
    if (_output?.isCompleted == false && !_cancelledBeforeClose) {
      _settlementFailed = true;
    }
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

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available,
      Object? responseId}) async {
    Map<String, Object?> failure(String code) => vnextFailure(code,
        profileVersion: binding.profileVersion, source: binding.source);
    if (responseId == null ||
        _closeTransport == null ||
        _closed ||
        _draining ||
        _settlementFailed ||
        !current() ||
        !available()) {
      return failure('unavailable');
    }
    if (!VnextMcpServer.schemasFor(binding.profileVersion).containsKey(tool)) {
      return failure('unavailable');
    }
    if (_idle != null) return failure('resourceLimit');
    final done = _idle = Completer<void>();
    final output = _output = Completer<bool>();
    _responseId = responseId;
    _cancelledBeforeClose = false;
    final control = _control = ExternalCallControl(clock: binding.clock);
    final cancellation = cancelled.listen((_) {
      if (!_closed && !_draining) _cancelledBeforeClose = true;
      control.cancel();
      // The SDK suppresses a cancelled request's response. Close the original
      // channel instead of waiting forever for an output that will not exist.
      unawaited(_closeTransport!().catchError((Object _) {}));
    });
    final projection = OfflineIpcCommandProjection(
        host: binding.host,
        authentication: binding.supportsUnifiedProfile
            ? VnextMcpSessionAuthentication(() async {
                final session = await binding.authentication.authenticate();
                if (session == null ||
                    _connectionSession != null &&
                        !identical(session, _connectionSession)) {
                  return null;
                }
                _connectionSession = session;
                _invalidateReferences = () => binding.settleConnection(session);
                return session;
              })
            : binding.authentication);
    try {
      final command = binding.supportsUnifiedProfile
          ? VnextMcpCommand.parseUnified(tool, arguments)
          : VnextMcpCommand.parse(tool, arguments);
      final id = 'android_${++_requestId}';
      final result = await (binding.supportsUnifiedProfile
              ? projection.invokeV4
              : projection.invokeV3)(command.request(id),
          binding: binding,
          stageApprovalWait: true,
          control: control,
          responseAvailable: () => !_closed && current() && available());
      if (result.frame == null) return failure('outcome_unknown');
      try {
        return {
          ...command.response(VnextMcpCommand.decodeFrame(result.frame!), id),
          if (binding.supportsUnifiedProfile) 'source': binding.source.toJson(),
        };
      } catch (_) {
        return failure('invalidResult');
      }
    } on FormatException {
      return failure('invalidRequest');
    } catch (_) {
      return failure('unavailable');
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
      await _invalidateReferences?.call();
      if (_settlementFailed) androidLinkFail();
    }();
  }
}
