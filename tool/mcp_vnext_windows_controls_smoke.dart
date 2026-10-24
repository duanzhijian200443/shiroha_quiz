import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import '../test/application/generated_question/generated_test_support.dart';
import '../test/mcp/fixtures/first_party_interaction_cases.dart';
import 'mcp_vnext_windows_app_smoke.dart';

final class ControlsSmokeEvidence {
  ControlsSmokeEvidence(this.file);
  final File file;
  final _clock = Stopwatch()..start();
  final _failed = <int>{};
  final _completed = <int>{};
  final _cleaned = <int>{};
  final _posted = <int>{};
  int currentCase = 0, _sequence = 0;

  void record(String stage) {
    if (stage == 'case_start') currentCase++;
    if (stage == 'case_failed' ||
        stage == 'cleanup_failed' ||
        stage == 'post_test_failed') {
      _failed.add(currentCase);
    }
    if (stage == 'case_complete') _completed.add(currentCase);
    if (stage == 'cleanup_complete') _cleaned.add(currentCase);
    if (stage == 'post_test_complete') _posted.add(currentCase);
    file.writeAsStringSync(
        '${jsonEncode({
              'sequence': ++_sequence,
              'elapsedMs': _clock.elapsedMilliseconds,
              'case': currentCase,
              'stage': stage,
            })}\n',
        mode: FileMode.append,
        flush: true);
  }

  bool get settled =>
      currentCase == 7 &&
      _completed.length == 7 &&
      _cleaned.length == 7 &&
      _posted.length == 7;
  bool get passed => settled && _failed.isEmpty;
}

final class _SmokeBinding extends LiveTestWidgetsFlutterBinding {
  _SmokeBinding(this.evidence) {
    final originalReporter = reportTestException;
    reportTestException = (details, description) {
      evidence.record('case_failed');
      originalReporter(details, description);
    };
  }
  final ControlsSmokeEvidence evidence;

  @override
  Future<void> runTest(
      Future<void> Function() testBody, VoidCallback invariantTester,
      {String description = ''}) async {
    evidence.record('case_start');
    try {
      await super.runTest(testBody, invariantTester, description: description);
    } catch (_) {
      evidence.record('case_failed');
      rethrow;
    } finally {
      evidence.record('case_complete');
    }
  }

  @override
  void postTest() {
    try {
      super.postTest();
      evidence.record('post_test_complete');
    } catch (_) {
      evidence.record('post_test_failed');
      rethrow;
    }
  }
}

void main() {
  if (!Platform.isWindows) throw StateError('Windows smoke only');
  const root = String.fromEnvironment(smokeRootDefine);
  smokeDataPaths(root);
  final file = File(p.join(root, 'events.jsonl'));
  if (file.existsSync()) throw StateError('Smoke evidence must be fresh');
  final evidence = ControlsSmokeEvidence(file)..record('startup');
  HttpOverrides.global = SmokeHttpOverrides();
  final binding = _SmokeBinding(evidence);
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  initializeGeneratedTests();
  registerFirstPartyInteractionTests(
    trace: evidence.record,
    observe: (tester, name) async {
      await tester.pump();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('external-interaction-surface')));
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(p.join(root, '$name.png'))
            .writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
      evidence.record('screenshot_complete');
    },
  );
  tearDownAll(() async {
    evidence.record(evidence.passed ? 'suite_passed' : 'suite_failed');
    if (!evidence.settled) {
      evidence.record('exit_blocked_by_unsettled_cleanup');
      return;
    }
    // The test binding intentionally refuses native exit; the owner closes after reporting.
    evidence.record('exit_ready');
  });
}
