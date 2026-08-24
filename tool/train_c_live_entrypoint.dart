import 'dart:convert';
import 'dart:io';

import 'train_c_http_observer.dart';

/// The live entrypoint is intentionally offline-only until H0/H1 and HR pass.
/// It provides a harmless proof command for the harness review and refuses all
/// other invocations so a live provider run cannot start accidentally.
final class TrainCLiveEntrypoint {
  const TrainCLiveEntrypoint._();

  static Map<String, Object?> offlineProof() {
    final ledger = TrainCRequestLedger();
    return <String, Object?>{
      'stage': 'TRAIN-C-H0',
      'status': 'PASS',
      'liveRun': 'BLOCKED',
      ...ledger.safeSummary(),
    };
  }
}

void main(List<String> args) {
  if (args.length == 1 && args.single == '--offline') {
    stdout.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(TrainCLiveEntrypoint.offlineProof()),
    );
    return;
  }

  stderr.writeln('TRAIN_C_HARNESS_NOT_READY');
  exitCode = 2;
}
