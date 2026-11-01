import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/link/link_call_capture.dart';
import 'package:shiroha_quiz/data/external/link/link_call_diagnostics.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';
import 'package:shiroha_quiz/data/external/link/link_verification_log.dart';

final class _LateFailureFile implements RandomAccessFile {
  _LateFailureFile(this.inner, {required this.failFlush});
  final RandomAccessFile inner;
  final bool failFlush;
  bool _footerWritten = false;
  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer,
      [int start = 0, int? end]) async {
    final row = jsonDecode(utf8.decode(buffer.sublist(start, end))) as Map;
    await inner.writeFrom(buffer, start, end);
    if (row['e'] == 'capture-finished') _footerWritten = true;
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    await inner.flush();
    if (_footerWritten && failFlush) throw StateError('SENTINEL_FLUSH');
    return this;
  }

  @override
  Future<void> close() async {
    await inner.close();
    if (!failFlush) throw StateError('SENTINEL_CLOSE');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void linkCallCaptureCases() {
  group('bounded call capture', () {
    late Directory root, evidence;
    const attempt = '12345678-1234-1234-1234-123456789abc';
    setUp(() async {
      root = await Directory.systemTemp.createTemp('link-call-capture-');
      evidence = await Directory(p.join(root.path, 'evidence')).create();
    });
    tearDown(() async {
      await root.delete(recursive: true);
    });
    LinkCallCapture capture(bool frontend, {int version = 1}) =>
        LinkCallCapture(
            LinkCaptureConfig(attempt, evidence.path, formatVersion: version),
            frontend: frontend,
            processStarted: () => '18446744073709551615');
    Map<String, dynamic> footer(String name) =>
        jsonDecode(File(p.join(evidence.path, name)).readAsLinesSync().last)
            as Map<String, dynamic>;

    for (final version in [1, 2]) {
      for (final frontend in [false, true]) {
        for (final failFlush in [false, true]) {
          test(
              'v$version frontend=$frontend late flush=$failFlush rejects false exit success',
              () async {
            final log = LinkCallCapture(
                LinkCaptureConfig(attempt, evidence.path,
                    formatVersion: version),
                frontend: frontend,
                processStarted: () => '123',
                openFile: (file) async => _LateFailureFile(
                    await file.open(mode: FileMode.writeOnlyAppend),
                    failFlush: failFlush));
            await log.start();
            if (frontend && version == 2) {
              log.lifecycle(LinkLifecycleCheckpoint.transportOnclose,
                  LinkLifecycleOutcome.observed);
              log.lifecycle(LinkLifecycleCheckpoint.portCloseEnter,
                  LinkLifecycleOutcome.observed);
              log.lifecycle(LinkLifecycleCheckpoint.portCloseSettled,
                  LinkLifecycleOutcome.completed);
            }
            final complete = await log.finish(originalClosed: true);
            expect(complete, isFalse);
            expect(log.incomplete, isTrue);
            expect(footer(log.filename)['complete'], isTrue);
            expect(log.exitCodeAfterFinish(0, complete: complete),
                version == 2 ? 80 : 0);
            for (final original in [64, 78, 79, 80]) {
              expect(log.exitCodeAfterFinish(original, complete: complete),
                  original);
            }
            expect(log.exitCodeAfterFinish(0, complete: true), 0);
            expect(
                await File(p.join(evidence.path, log.filename)).readAsString(),
                isNot(contains('SENTINEL')));
          });
        }
      }
    }

    test('separate config is exact, bounded, existing-directory only',
        () async {
      expect(await LinkCaptureConfig.load(runtimeDirectory: root.path), isNull);
      final file = File(p.join(root.path, 'link-verification-capture.json'));
      final valid = {
        'formatVersion': 1,
        'attemptId': attempt,
        'evidenceDirectory': evidence.path
      };
      for (final value in [
        {...valid, 'pairingInput': 'synthetic-secret'},
        {...valid, 'attemptId': 'untrusted-secret'},
        {...valid, 'evidenceDirectory': 'relative'},
        {...valid, 'evidenceDirectory': p.join(root.path, 'absent')},
        {...valid, 'formatVersion': 3},
      ]) {
        await file.writeAsString(jsonEncode(value));
        expect(
            await LinkCaptureConfig.load(runtimeDirectory: root.path), isNull);
      }
      await file.writeAsString(jsonEncode(valid));
      final loaded = await LinkCaptureConfig.load(runtimeDirectory: root.path);
      expect(loaded!.attemptId, attempt);
      expect(loaded.directory, evidence.path);
      expect(loaded.formatVersion, 1);
      await file.writeAsString(jsonEncode({...valid, 'formatVersion': 2}));
      expect(
          (await LinkCaptureConfig.load(runtimeDirectory: root.path))!
              .formatVersion,
          2);
      expect(await Directory(p.join(root.path, 'absent')).exists(), isFalse);
    });

    for (final version in [1, 2]) {
      test(
          'v$version longest legal identities and all stages fit fixed aggregate including LF and collision',
          () async {
        final token = 'x' * 128;
        final owner = LinkOwnerReference(
            runId: token,
            resourceId: token,
            processId: linkMaxRevision,
            processStarted: token,
            slotRef: token);
        final target = LinkVerifiedTarget('a' * 64, token, token);
        final lease = LinkLease(
            connectorRunId: token,
            selectionRevision: linkMaxRevision,
            routeGeneration: linkMaxRevision,
            targetRef: token,
            target: target,
            frontendPeerIdentity: token,
            frontendConnectionId: token,
            leaseId: token);
        final observations = [
          LinkVerificationObservation.adapterJoined(owner,
              proof: false, processExitCode: 0),
          LinkVerificationObservation.runtimeSettled(owner,
              lease: lease,
              operationId: token,
              connectorInstanceId: token,
              revision: linkMaxRevision,
              routeGeneration: linkMaxRevision),
          LinkVerificationObservation.outputJoined(owner,
              frontendEnded: false,
              frontendConnectionId: token,
              delivery: LinkDelivery.undelivered,
              workFailed: false,
              pendingWork: linkMaxRevision),
        ];
        for (final observation in observations) {
          expect(utf8.encode('${observation.encode(31)}\n').length,
              lessThanOrEqualTo(LinkCallCapture.resourceBytes));
        }
        final frontend = capture(true, version: version),
            link = capture(false, version: version);
        await frontend.start();
        final count = version == 2 ? 5 : 8;
        for (var i = 0; i < count; i++) {
          for (final producer in [frontend, link]) {
            final trace = producer.diagnostics.begin('open_context', {
              for (final key in LinkCallDiagnostics.schemas['open_context']!)
                key: '私密🙂' * 10000,
              for (var n = 0; n < 300; n++) 'unknown$n': 'secret',
            })!;
            trace.bind(
                run: token,
                connection: token,
                call: 0x7fffffff,
                lease: token,
                originalLease: producer.frontend ? null : lease,
                originalOwner: producer.frontend ? null : owner);
            for (final stage in LinkCallStage.values) {
              trace.stage(stage, LinkCallOutcome.unknown,
                  LinkCallCause.resultErrorFlag);
            }
            expect(
                utf8.encode('${trace.encode(31)}\n').length,
                lessThanOrEqualTo(producer.frontend
                    ? LinkCallCapture.frontendCallBytes
                    : LinkCallCapture.linkCallBytes));
            producer.diagnostics.finish(trace);
          }
        }
        for (var i = 0; i < 7; i++) {
          link.resource(observations[i % observations.length]);
        }
        if (version == 2) {
          frontend.lifecycle(LinkLifecycleCheckpoint.transportOnclose,
              LinkLifecycleOutcome.observed);
          frontend.lifecycle(LinkLifecycleCheckpoint.portCloseEnter,
              LinkLifecycleOutcome.observed);
          frontend.lifecycle(LinkLifecycleCheckpoint.portCloseSettled,
              LinkLifecycleOutcome.completed);
          // Repeated original close observations do not consume another record.
          frontend.lifecycle(LinkLifecycleCheckpoint.portCloseSettled,
              LinkLifecycleOutcome.completed);
        }
        expect(
            await File(p.join(evidence.path, 'link-verification.jsonl'))
                .exists(),
            isFalse);
        expect(await frontend.finish(originalClosed: true), isTrue);
        expect(await link.finish(originalClosed: true), isTrue);
        final prior = await File(p.join(evidence.path, 'frontend-calls.jsonl'))
            .readAsBytes();
        final duplicate = capture(true, version: version);
        await duplicate.start();
        expect(await duplicate.finish(originalClosed: true), isFalse);
        expect(
            await File(p.join(evidence.path, 'frontend-calls.jsonl'))
                .readAsBytes(),
            prior);
        var bytes = 0, lines = 0;
        await for (final file in evidence.list()) {
          final value = await File(file.path).readAsBytes();
          expect(utf8.decode(value), isNot(contains('私密')));
          bytes += value.length;
          lines += '\n'.allMatches(utf8.decode(value)).length;
        }
        if (version == 1) {
          expect(LinkCallCapture.aggregateBytes, 32640);
          expect(bytes, lessThanOrEqualTo(LinkCallCapture.aggregateBytes));
          expect(lines, 27);
        } else {
          final witness = utf8.encode('${jsonEncode({
                'pid': 4294967295,
                'processStarted': '18446744073709551615',
                'binarySha256': 'f' * 64,
                'originalHandleRetained': true,
                'observedExit': true,
                'exitCode': 0,
                'forcedTermination': false
              })}\n');
          final client = utf8.encode('${jsonEncode({
                'model': 'gpt-6-astra',
                'sourceManifestSha256': 'f' * 64,
                'calls': List.generate(
                    5,
                    (i) => {
                          'ordinal': i + 1,
                          'tool': 'get_due_review_summary',
                          'expectedServer': true,
                          'completed': true,
                          'clientErrorPresent': false,
                          'validAndroidResponse': true
                        }),
                'exitCode': 0,
                'detailObserved': true,
                'readPassed': true
              })}\n');
          expect(witness.length,
              lessThanOrEqualTo(LinkCallCapture.externalProcessWitnessBytes));
          expect(client.length,
              lessThanOrEqualTo(LinkCallCapture.externalClientSummaryBytes));
          expect(LinkCallCapture.closureAggregateBytes, 31936);
          // Reserve both FULL external allocations, not just this example's size.
          expect(
              bytes +
                  LinkCallCapture.externalProcessWitnessBytes +
                  LinkCallCapture.externalClientSummaryBytes,
              lessThanOrEqualTo(LinkCallCapture.closureAggregateBytes));
          expect(lines + 2, LinkCallCapture.closureAggregateRecords);
          final rows =
              (await File(p.join(evidence.path, 'frontend-calls.jsonl'))
                      .readAsLines())
                  .map(jsonDecode)
                  .toList();
          final largestHeader = Map<String, dynamic>.from(rows.first as Map)
            ..['pid'] = 4294967295;
          expect(utf8.encode('${jsonEncode(largestHeader)}\n').length,
              lessThanOrEqualTo(LinkCallCapture.headerBytes));
          expect(rows.first['processStarted'], '18446744073709551615');
          expect(
              rows
                  .where((r) => r['e'] == 'lifecycle')
                  .map((r) => [r['k'], r['o']]),
              [
                [0, 0],
                [1, 0],
                [2, 1],
                [3, 0]
              ]);
          for (final row in rows.where((r) => r['e'] == 'lifecycle')) {
            expect(utf8.encode('${jsonEncode(row)}\n').length,
                lessThanOrEqualTo(LinkCallCapture.lifecycleBytes));
          }
        }
        for (final name in [
          'frontend-calls.jsonl',
          'link-verification.jsonl'
        ]) {
          final rows = (await File(p.join(evidence.path, name)).readAsLines())
              .map(jsonDecode)
              .toList();
          for (var i = 0; i < rows.length; i++) {
            expect(rows[i]['s'] ?? rows[i]['sequence'], i + 1);
          }
          expect(rows.last['calls'], count);
          expect(rows.last['complete'], isTrue);
          if (version == 2) {
            expect(
                rows.last['lifecycle'], name == 'frontend-calls.jsonl' ? 4 : 0);
            final largestFooter = Map<String, dynamic>.from(rows.last as Map)
              ..addAll({
                'records': 27,
                'priorBytes': 31936,
                'unassociated': 256,
                'complete': false,
                'originalClosed': false
              });
            expect(utf8.encode('${jsonEncode(largestFooter)}\n').length,
                lessThanOrEqualTo(LinkCallCapture.footerBytes));
          }
        }
      });
    }

    test(
        'v1 does not initialize process-start provider or reinterpret its footer',
        () async {
      var starts = 0;
      final log = LinkCallCapture(LinkCaptureConfig(attempt, evidence.path),
          frontend: true, processStarted: () {
        starts++;
        throw StateError('must not execute');
      });
      await log.start();
      log.lifecycle(LinkLifecycleCheckpoint.portCloseEnter,
          LinkLifecycleOutcome.observed);
      expect(await log.finish(originalClosed: true), isTrue);
      expect(starts, 0);
      expect(footer('frontend-calls.jsonl').containsKey('lifecycle'), isFalse);
    });

    for (final kind in [
      'missing',
      'failed',
      'sixth',
      'start-null',
      'start-throws'
    ]) {
      test('v2 $kind evidence stays incomplete without changing call admission',
          () async {
        final log = LinkCallCapture(
            LinkCaptureConfig(attempt, evidence.path, formatVersion: 2),
            frontend: true, processStarted: () {
          if (kind == 'start-throws') {
            throw StateError('synthetic provider failure');
          }
          return kind == 'start-null' ? null : '123';
        });
        await log.start();
        log.lifecycle(LinkLifecycleCheckpoint.transportOnclose,
            LinkLifecycleOutcome.observed);
        if (kind != 'missing') {
          log.lifecycle(LinkLifecycleCheckpoint.portCloseEnter,
              LinkLifecycleOutcome.observed);
        }
        log.lifecycle(
            LinkLifecycleCheckpoint.portCloseSettled,
            kind == 'failed'
                ? LinkLifecycleOutcome.failed
                : LinkLifecycleOutcome.completed);
        var originalCalls = 0;
        for (var i = 0; i < (kind == 'sixth' ? 6 : 1); i++) {
          final trace = log.diagnostics.begin('open_context', {});
          originalCalls++; // Diagnostics never own original call admission.
          log.diagnostics.finish(trace);
        }
        expect(originalCalls, kind == 'sixth' ? 6 : 1);
        expect(await log.finish(originalClosed: true), isFalse);
        expect(footer('frontend-calls.jsonl')['complete'], isFalse);
        if (kind == 'sixth') expect(footer('frontend-calls.jsonl')['calls'], 5);
        if (kind.startsWith('start-')) {
          final header = jsonDecode(
              (await File(p.join(evidence.path, 'frontend-calls.jsonl'))
                      .readAsLines())
                  .first) as Map;
          expect(header['processStarted'], isNull);
        }
      });
    }

    for (final failure in [
      'ninth',
      'unfinished',
      'observer',
      'identity',
      'resource-limit',
      'original-close',
      'write'
    ]) {
      test('$failure cannot manufacture complete capture', () async {
        final log = failure == 'write'
            ? LinkCallCapture(
                LinkCaptureConfig(attempt, p.join(root.path, 'absent')),
                frontend: true)
            : capture(true);
        await log.start();
        final trace = log.diagnostics
            .begin('search_questions', {'query': 'synthetic-secret'})!;
        if (failure == 'identity') trace.bind(run: 'x' * 129);
        if (failure != 'unfinished') log.diagnostics.finish(trace);
        if (failure == 'ninth') {
          for (var i = 0; i < 8; i++) {
            log.diagnostics.finish(log.diagnostics.begin('open_context', {}));
          }
        }
        if (failure == 'observer') log.diagnostics.unbound();
        if (failure == 'resource-limit') {
          const owner = LinkOwnerReference(
              runId: 'r',
              resourceId: 's',
              processId: 1,
              processStarted: '1',
              slotRef: 's');
          log.resource(LinkVerificationObservation.adapterJoined(owner,
              proof: true, processExitCode: 0));
        }
        expect(await log.finish(originalClosed: failure != 'original-close'),
            isFalse);
        if (failure != 'write') {
          expect(footer('frontend-calls.jsonl')['complete'], isFalse);
        }
      });
    }

    test(
        'projection drops all values, unknown names, and observer failures stay local',
        () {
      const secret = 'SENTINEL_PRIVATE_VALUE';
      final rows = <String>[];
      final diagnostic = LinkCallDiagnostics(
          (trace) => rows.add(trace.encode(1)),
          frontend: true);
      final trace = diagnostic.begin('open_context', {
        'contextRef': secret,
        'targetRef': null,
        'fileRefs': [secret],
        'cursor': {'secret': secret},
        'pageSize': 42,
        'scope': secret,
        secret: secret,
      })!;
      diagnostic.finish(trace);
      expect(rows.single, isNot(contains(secret)));
      expect(rows.single, isNot(contains('contextRef')));
      final value = jsonDecode(rows.single) as Map;
      expect(value['u'], 1);
      expect((value['a'] as List).firstWhere((row) => row[0] == 1),
          [1, 1, 1, 0, 0]); // present null targetRef
      final throwing =
          LinkCallDiagnostics((_) => throw StateError(secret), frontend: true);
      expect(() => throwing.finish(throwing.begin('open_context', {})),
          returnsNormally);
      expect(throwing.incomplete, isTrue);
    });
  });
}
