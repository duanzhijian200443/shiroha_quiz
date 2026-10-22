// Bounded test-only evidence: fixed phase names and monotonic milliseconds.
// No request bodies, request IDs, credentials or filesystem paths are recorded.
import 'dart:convert';
import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;

enum StageCancellationPhase {
  wireStage,
  wireCancel,
  wireCancelOther,
  wireProbe,
  transportClosed,
  sdkAbort,
  mailboxStarted,
  mailboxResponse,
  mailboxExpired,
  mailboxUnavailable,
  mailboxPeerClosed,
  cancelWritten,
  parentCancel,
  bridgeCallReturned,
  portCloseStarted,
  portCloseFinished,
  owningSettled,
}

final class StageCancellationEvidence {
  StageCancellationEvidence({this.directory});
  final Directory? directory;
  final _clock = Stopwatch()..start();
  final _events = <String, int>{};
  static const filename = 'stage-cancellation-evidence.json';
  Map<String, int> get events => Map.unmodifiable(_events);
  void mark(StageCancellationPhase phase) {
    if (_events.containsKey(phase.name)) return;
    _events[phase.name] = _clock.elapsedMilliseconds;
    if (directory != null) {
      File(p.join(directory!.path, filename))
          .writeAsStringSync(jsonEncode(_events));
    }
  }

  static Future<Map<String, int>> read(Directory directory) async {
    final decoded =
        jsonDecode(await File(p.join(directory.path, filename)).readAsString())
            as Map;
    if (decoded.length > StageCancellationPhase.values.length ||
        decoded.keys.any((key) =>
            !StageCancellationPhase.values.any((phase) => phase.name == key))) {
      throw StateError('Invalid bounded phase evidence.');
    }
    return decoded.cast<String, int>();
  }
}

/// Observes the original SDK stdio transport before its protocol callback.
/// All messages and close callbacks are forwarded unchanged, exactly once.
final class StageObservedStdio extends StdioServerTransport {
  StageObservedStdio(this.evidence);
  final StageCancellationEvidence evidence;
  Object? _stageId;
  @override
  Future<void> start() async {
    final receive = onmessage;
    final closed = onclose;
    onmessage = (message) {
      if (message is JsonRpcRequest && message.method == 'tools/call') {
        if (message.params?['name'] == 'propose_generated_questions') {
          _stageId = message.id;
          evidence.mark(StageCancellationPhase.wireStage);
        } else if (_stageId != null) {
          evidence.mark(StageCancellationPhase.wireProbe);
        }
      }
      if (message is JsonRpcNotification &&
          message.method == 'notifications/cancelled' &&
          _stageId != null) {
        evidence.mark(message.params?['requestId'] == _stageId
            ? StageCancellationPhase.wireCancel
            : StageCancellationPhase.wireCancelOther);
      }
      receive?.call(message);
    };
    onclose = () {
      evidence.mark(StageCancellationPhase.transportClosed);
      closed?.call();
    };
    return super.start();
  }
}
