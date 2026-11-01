import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'link_values.dart';

typedef LinkVerificationObserver = void Function(LinkVerificationObservation);

/// Non-authoritative observations made only by the original resource owner.
final class LinkVerificationObservation {
  LinkVerificationObservation.adapterJoined(LinkOwnerReference owner,
      {required bool proof, required int processExitCode})
      : runId = owner.runId,
        _value = {
          'event': 'adapter-joined',
          'owner': owner.toJson(),
          'mode': proof ? 'enable-proof' : 'business',
          'processExitCode': processExitCode,
          'stdinFlushed': true,
          'stdinClosed': true,
          'stdoutDrained': true,
          'stderrDrained': true,
          'clientCloseRequired': !proof,
          'clientClosed': !proof,
          'boundSettledEventValidated': true,
        };

  LinkVerificationObservation.runtimeSettled(LinkOwnerReference owner,
      {required LinkLease lease,
      required String operationId,
      required String connectorInstanceId,
      required int revision,
      required int routeGeneration})
      : runId = owner.runId,
        _value = {
          'event': 'runtime-settled',
          'owner': owner.toJson(),
          'target': lease.target.toJson(),
          'leaseId': lease.leaseId,
          'frontendConnectionId': lease.frontendConnectionId,
          'operationId': operationId,
          'connectorInstanceId': connectorInstanceId,
          'routeGeneration': routeGeneration,
          'originalCallJoined': true,
          'receiptValidated': true,
          'stateAndSlotPublished': true,
          'stateRevision': revision,
        };

  LinkVerificationObservation.outputJoined(LinkOwnerReference owner,
      {required bool frontendEnded,
      required String? frontendConnectionId,
      required LinkDelivery delivery,
      required bool workFailed,
      required int pendingWork})
      : runId = owner.runId,
        _value = {
          'event': 'output-work-joined',
          'owner': owner.toJson(),
          'frontendEnded': frontendEnded,
          'frontendConnectionId': frontendConnectionId,
          'delivery': delivery.name,
          'pendingWorkFailed': workFailed,
          'pendingWork': pendingWork,
        };

  final String runId;
  final Map<String, Object?> _value;
  String encode(int sequence) => jsonEncode({
        'formatVersion': 1,
        'sequence': sequence,
        'runId': runId,
        ..._value,
      });
}

/// Observer failures never enter resource settlement or recovery decisions.
void observeLinkVerification(LinkVerificationObserver? observer,
    LinkVerificationObservation Function() observation) {
  if (observer == null) return;
  try {
    observer(observation());
  } catch (_) {
    // Missing owner observations make verification incomplete. Diagnostics must
    // not throw back into original settlement, including through stderr.
  }
}

/// Opt-in build diagnostics. No I/O occurs until the original Link has closed.
/// These files are never read by admission, custody, or recovery code.
final class LinkVerificationLog {
  LinkVerificationLog(this.stateDirectory, this.runId);
  final String stateDirectory, runId;
  final _lines = <String>[];
  var _bytes = 0, _failed = false, _finished = false;

  void record(LinkVerificationObservation observation) {
    if (_failed || _finished) {
      _failed = true;
      return;
    }
    try {
      if (observation.runId != runId || _lines.length >= 31) {
        throw const FormatException();
      }
      final line = '${observation.encode(_lines.length + 1)}\n';
      final bytes = utf8.encode(line).length;
      // Reserve the last record and bounded space for the terminal marker.
      if (_bytes + bytes > 31744) throw const FormatException();
      _lines.add(line);
      _bytes += bytes;
    } catch (_) {
      _failed = true;
    }
  }

  Future<bool> finish() async {
    if (_finished) return false;
    _finished = true;
    if (_failed ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(runId)) {
      return false;
    }
    try {
      final terminal = '${jsonEncode({
            'formatVersion': 1,
            'sequence': _lines.length + 1,
            'runId': runId,
            'event': 'verification-log-complete',
            'observationCount': _lines.length,
          })}\n';
      final bytes = utf8.encode('${_lines.join()}$terminal');
      if (bytes.length > 32768) return false;
      final file = File(p.join(stateDirectory, 'verification-$runId.jsonl'));
      await file.create(exclusive: true);
      await file.writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}
