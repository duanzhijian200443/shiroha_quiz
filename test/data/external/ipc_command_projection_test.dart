import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_generated_stage.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/data/external/ipc_command_projection.dart';
import 'package:shiroha_quiz/data/external/ipc_envelope_codec.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';

import '../../application/external/external_file_read_test_support.dart'
    show FileReadHarness;
import '../../application/external/external_question_read_test_support.dart';
import '../../application/external/local_host_test_support.dart';

final class SyntheticAuthentication implements OfflineIpcAuthenticationPort {
  SyntheticAuthentication(this.session);
  ExternalSession? session;
  Future<void> Function()? before;
  int calls = 0;
  @override
  Future<ExternalSession?> authenticate() async {
    calls++;
    await before?.call();
    return session;
  }
}

final class OfflineEncoder implements IpcCommandFrameEncoder {
  bool fail = false;
  int calls = 0;
  @override
  Uint8List encodeResponse(String requestId, String payload) {
    calls++;
    if (fail) throw StateError('synthetic-secret/private-path');
    return IpcEnvelopeCodec.encodeResponse(requestId, payload);
  }
}

UntrustedIpcEnvelope decode(Uint8List frame) {
  final decoder = IpcEnvelopeDecoder();
  // Exercise fragmented P9 framing for every offline command/response.
  expect(decoder.consume(Uint8List.sublistView(frame, 0, 13)).envelope, isNull);
  final step = decoder.consume(Uint8List.sublistView(frame, 13));
  expect(step.consumed, frame.length - 13);
  decoder.finish();
  return step.envelope!;
}

UntrustedIpcEnvelope raw(String text, {String id = 'correlation-only'}) =>
    decode(IpcEnvelopeCodec.encodeRequest(id, text));
UntrustedIpcEnvelope command(String name, Object? input,
        {String id = 'correlation-only'}) =>
    raw(
        jsonEncode({
          'schemaVersion': 1,
          'type': 'command',
          'capability': name,
          'input': input,
        }),
        id: id);
Map<String, Object?> response(OfflineIpcCommandResult result) {
  final envelope = decode(result.frame!);
  expect(envelope.requestId, 'correlation-only');
  return IpcCommandResponseCodec.decode(envelope);
}

Map<String, Object?> data(OfflineIpcCommandResult result) {
  final root = response(result);
  expect(root['error'], isNull);
  return (root['data']! as Map).cast<String, Object?>();
}

const listInput = {'pageSize': 20, 'cursor': null};
const searchInput = {'query': 'needle', 'pageSize': 20, 'cursor': null};
const listName = 'external_list_targets';
const searchName = 'external_search_questions';
const stageName = 'external_stage_generated_questions';
const reconcileName = 'external_reconcile_generated_stage';

void main() {
  initializeGeneratedTests();
  group('P10 trusted offline projection over real SQLite', () {
    late OfflineHostHarness f;
    late SyntheticAuthentication auth;
    late OfflineEncoder encoder;
    late OfflineIpcCommandProjection adapter;
    setUp(() async {
      f = OfflineHostHarness();
      await f.open();
      auth = SyntheticAuthentication(f.h.s.session);
      encoder = OfflineEncoder();
      adapter = OfflineIpcCommandProjection(
          host: f.host, authentication: auth, encoder: encoder);
    });
    tearDown(() async {
      await adapter.shutdown();
      await f.close();
    });

    test('target/context/search/detail are typed routes with unchanged scope',
        () async {
      final discovery = await f.host.openRead(f.entry);
      final targets = data(await adapter.invoke(command(listName, listInput),
          context: discovery));
      final item = (targets['items'] as List).single as Map;
      expect(item.keys.toSet(),
          {'targetRef', 'bankName', 'projectId', 'folderName'});
      expect(item['bankName'], 'bank');
      final created = data(await adapter.invoke(
          command(
              'external_create_read_context', {'targetRef': item['targetRef']}),
          context: discovery));
      final context = await f.host
          .openRead(f.entry, context: created['contextRef']! as String);
      final search = data(await adapter.invoke(command(searchName, searchInput),
          context: context));
      final hit = (search['items'] as List).single as Map;
      expect(hit['stemPreview'], contains('Synthetic needle'));
      final detail = data(await adapter.invoke(
          command('external_get_question_detail',
              {'questionRef': hit['questionRef']}),
          context: context));
      expect(detail['answer'], isNotNull);
      expect(detail['explanation'], isNull);
      expect(jsonEncode(detail), isNot(contains('private needle')));
      expect(jsonEncode(detail), isNot(contains('storageId')));
      expect(auth.calls, 4);
    });

    test('authentication and current P8 binding precede even malformed JSON',
        () async {
      final context = await f.host.openRead(f.entry);
      auth.session = null;
      final denied = await adapter.invoke(raw('{malformed-private-body'),
          context: context);
      expect(response(denied)['error'], 'unauthenticated');
      expect(denied.execution, isNull);
      auth.session = f.h.s.session;
      f.h.s.trust.disable(f.h.s.principal);
      final stale = await adapter.invoke(raw('{malformed-private-body'),
          context: context);
      expect(response(stale)['error'], 'unauthenticated');
      expect(stale.execution, isNull);
      expect(f.h.contentReads, 0);
    });

    test('trusted authentication exceptions are classified without retention',
        () async {
      final context = await f.host.openRead(f.entry);
      auth.before =
          () async => throw StateError('synthetic-secret/private-path');
      final result =
          await adapter.invoke(raw('private-body'), context: context);
      expect(response(result)['error'], 'unauthenticated');
      expect(jsonEncode(response(result)), isNot(contains('private')));
    });

    for (final mutation in [
      'disable',
      'expire',
      'revoke',
      'regrant',
      'restart',
      'restore',
      'shutdown'
    ]) {
      test('$mutation rejects old authentication/Context without data release',
          () async {
        final context = await f.readContext();
        switch (mutation) {
          case 'disable':
            f.h.s.trust.disable(f.h.s.principal);
          case 'expire':
            f.h.s.clock.current =
                f.h.s.clock.current.add(const Duration(minutes: 31));
          case 'revoke':
            await f.h.s.management.revokeGrant(f.h.s.profile, 2);
          case 'regrant':
            await f.h.s.management.replaceGrant(
                f.h.s.profile,
                2,
                f.h.s.policy(permissions: [
                  CapabilityPermission.read,
                  CapabilityPermission.stage
                ]));
          case 'restart':
            f.h.s.trust.restart();
          case 'restore':
            f.h.s.trust.restore();
          case 'shutdown':
            await adapter.shutdown();
        }
        final result = await adapter.invoke(command(searchName, searchInput),
            context: context);
        expect(response(result)['data'], isNull);
        expect(result.failure, isNotNull);
        expect(f.h.contentReads, 0);
      });
    }

    test(
        'cross Profile/composition and same-Principal exact Session cannot copy Context',
        () async {
      final context = await f.readContext();
      auth.session = f.h.s.trust.openSession(
          f.h.s.trust.authenticate(f.h.s.credentials.authentication));
      final denied = await adapter.invoke(command(searchName, searchInput),
          context: context);
      expect(denied.execution!.receipt.status,
          CapabilityExecutionStatus.notStarted);
      expect(response(denied)['data'], isNull);
      expect(f.h.contentReads, 0);
      final foreign = OfflineHostHarness();
      await foreign.open();
      try {
        auth.session = foreign.h.s.session;
        expect(
            response(await adapter.invoke(command(searchName, searchInput),
                context: context))['error'],
            'unauthenticated');
      } finally {
        await foreign.close();
      }
    });

    test('every capability outside the fixed ten rejects before handler entry',
        () async {
      final context = await f.host.openRead(f.entry);
      final names = {
        'list_question_banks',
        'get_study_overview',
        'get_due_review_summary',
        'search_questions',
        'get_question_detail',
        'get_weak_questions',
        'retrieve_file_content',
        'propose_missing_answer',
        'propose_study_plan',
        'get_generated_question_proposal',
        'commit',
        'COMMIT',
        'destructive',
        'DESTRUCTIVE',
        'sql',
        'external_commit_generated_questions',
        'external_read_file_path',
        'unknown',
        'secret/private-path',
        '',
        'EXTERNAL_LIST_TARGETS',
      };
      for (final name in names) {
        final result =
            await adapter.invoke(command(name, {}), context: context);
        expect(response(result)['error'], 'unsupportedCapability',
            reason: name);
        expect(result.execution, isNull);
        expect(
            jsonEncode(response(result)),
            isNot(contains(
                name == '' ? 'never-empty-sentinel' : 'secret/private-path')));
      }
      expect(f.h.contentReads, 0);
    });

    test(
        'strict malformed/duplicate/unknown/missing/null/nesting/version inputs',
        () async {
      final context = await f.host.openRead(f.entry);
      final valid = jsonEncode({
        'schemaVersion': 1,
        'type': 'command',
        'capability': listName,
        'input': listInput
      });
      final cases = <String>[
        '{',
        '[]',
        'null',
        '\uFEFF$valid',
        '$valid trailing',
        valid.replaceFirst(
            '"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1'),
        valid.replaceFirst(
            '"schemaVersion":1', '"schemaVersion":1,"schema\\u0056ersion":1'),
        valid.replaceFirst('"pageSize":20', '"pageSize":20,"pageSize":20'),
        valid.replaceFirst(
            '"cursor":null', '"cursor":null,"principal":"forged"'),
        valid.replaceFirst('"cursor":null', '"cursor":{"nested":true}'),
        valid.replaceFirst('"cursor":null', '"cursor":"path/not-a-ref"'),
        valid.replaceFirst(',"cursor":null', ''),
        valid.replaceFirst('"pageSize":20', '"pageSize":null'),
        valid.replaceFirst('"input":{', '"input":null,"ignored":{'),
        valid.replaceFirst('"type":"command"', '"type":"result"'),
        valid.replaceFirst('"input":', '"permissions":["COMMIT"],"input":'),
        valid.replaceFirst(
            '"input":', '"input":${'[' * 17}0${']' * 17},"unused":'),
      ];
      for (final text in cases) {
        final result = await adapter.invoke(raw(text), context: context);
        expect(response(result)['error'], 'invalidRequest');
        expect(result.execution, isNull);
      }
      for (final version in [
        '0',
        '2',
        '1.0',
        '1e0',
        '"1"',
        'null',
        'true',
        '9007199254740993'
      ]) {
        final result = await adapter.invoke(
            raw(valid.replaceFirst(
                '"schemaVersion":1', '"schemaVersion":$version')),
            context: context);
        expect(response(result)['error'], 'unsupportedVersion');
      }
    });

    test(
        'strict integer bounds accept 1/50, reject float/exponent/coercion/overflow',
        () async {
      final context = await f.host.openRead(f.entry);
      for (final page in [1, 50]) {
        expect(
            data(await adapter.invoke(
                command(listName, {'pageSize': page, 'cursor': null}),
                context: context))['items'],
            isNotEmpty);
      }
      for (final number in [
        '0',
        '-1',
        '51',
        '20.0',
        '2e1',
        '"20"',
        'true',
        '1e309',
        '9223372036854775808'
      ]) {
        final text =
            '{"schemaVersion":1,"type":"command","capability":"$listName","input":{"pageSize":$number,"cursor":null}}';
        final result = await adapter.invoke(raw(text), context: context);
        expect(response(result)['error'], 'invalidRequest');
        expect(result.execution, isNull);
      }
    });

    test(
        'per-route exact input fields reject authority/path/SQL and invalid scalars',
        () async {
      final context = await f.host.openRead(f.entry);
      final ref = 'a' * 43;
      final invalid = <(String, Object?)>[
        ('external_create_read_context', {'targetRef': ref, 'scope': 'all'}),
        (
          'external_get_question_detail',
          {'questionRef': ref, 'questionId': 'raw'}
        ),
        (searchName, {'query': 'x' * 201, 'pageSize': 20, 'cursor': null}),
        (searchName, {'query': '   ', 'pageSize': 20, 'cursor': null}),
        (searchName, {'query': '\uD800', 'pageSize': 20, 'cursor': null}),
        ('external_list_file_selections', {'path': 'C:/private'}),
        ('external_create_file_context', {'fileRefs': []}),
        (
          'external_create_file_context',
          {
            'fileRefs': [ref, ref]
          }
        ),
        ('external_create_file_context', {'fileRefs': List.filled(65, ref)}),
        (
          'external_create_file_context',
          {
            'fileRefs': ['C:/private']
          }
        ),
        ('external_retrieve_file_content', {'query': '😀' * 201, 'limit': 1}),
        ('external_retrieve_file_content', {'query': 'x', 'limit': 0}),
        ('external_retrieve_file_content', {'query': 'x', 'limit': 21}),
        ('external_get_file_passage', {'passageRef': ref}),
        (stageName, {'submissionJson': null, 'externalRequestId': null}),
        (stageName, {'submissionJson': '', 'externalRequestId': null}),
        (
          stageName,
          {'submissionJson': 'é' * (512 * 1024 + 1), 'externalRequestId': null}
        ),
        (stageName, {'submissionJson': '{}', 'externalRequestId': 'x' * 129}),
        (stageName, {'submissionJson': {}, 'externalRequestId': null}),
        (reconcileName, {'submissionKey': 'request-id'}),
      ];
      for (final (name, input) in invalid) {
        final result =
            await adapter.invoke(command(name, input), context: context);
        expect(response(result)['error'], 'invalidRequest', reason: name);
        expect(result.execution, isNull);
      }
    });

    test(
        'embedded Submission remains P3-owned and cannot add authority or duplicate keys',
        () async {
      final context = await f.stageContext();
      for (final body in [
        '{',
        submission().replaceFirst('{', '{"principal":"forged",'),
        submission().replaceFirst('{', '{"schemaVersion":1,')
      ]) {
        final result = await adapter.invoke(
            command(
                stageName, {'submissionJson': body, 'externalRequestId': null}),
            context: context);
        expect(result.execution, isNotNull);
        expect(
            response(result)['error'], 'capability.generatedInvalidSubmission');
      }
      expect(await f.h.s.h.count('generated_question_proposals'), 0);
    });

    test(
        'STAGE/lost response/key reconciliation retain persisted publication, never COMMIT',
        () async {
      final staged = await adapter.invoke(
          command(stageName, {
            'submissionJson': submission(key: 'business-key'),
            'externalRequestId': null
          }),
          context: await f.stageContext(),
          responseAvailable: () => false);
      expect(staged.execution!.receipt.knownEffect,
          CapabilityEffect.proposalStaged);
      expect(staged.execution!.receipt.durableReconciliation!.submissionKey,
          'business-key');
      expect(response(staged)['data'], isNull);
      expect(response(staged)['error'], 'capability.externalResponseLost');
      final recovered = data(await adapter.invoke(command(reconcileName, {}),
          context: await f.host.openReconciliation(f.entry, 'business-key')));
      expect(recovered['submissionKey'], 'business-key');
      expect(recovered['publication'], 'STAGED');
      expect(recovered['formalCommit'], 'NOT_REPORTED');
      final absent = await adapter.invoke(command(reconcileName, {}),
          context:
              await f.host.openReconciliation(f.entry, 'correlation-only'));
      expect(absent.execution!.receipt.status,
          CapabilityExecutionStatus.outcomeUnknown);
      expect(absent.execution!.receipt.knownEffect, isNull);
      expect(await f.h.s.h.count('generated_question_proposals'), 1);
      expect(await f.h.s.h.count('generated_question_commit_receipts'), 0);
    });

    test(
        'successful STAGE repeats original semantics by business key, independently of Request ID',
        () async {
      final context = await f.stageContext();
      final input = {
        'submissionJson': submission(key: 'original-key'),
        'externalRequestId': null
      };
      final first = data(
          await adapter.invoke(command(stageName, input), context: context));
      final repeat = data(
          await adapter.invoke(command(stageName, input), context: context));
      expect(repeat, first);
      expect(first['publication'], 'STAGED');
      final changed = await adapter.invoke(
          command(stageName, {
            'submissionJson': submission(
                key: 'original-key',
                items: [candidate(stem: 'Different semantics')]),
            'externalRequestId': null
          }),
          context: context);
      expect(response(changed)['error'],
          'capability.generatedIdempotencyConflict');
      expect(await f.h.s.h.count('generated_question_proposals'), 1);
      expect(await f.h.s.h.count('generated_question_commit_receipts'), 0);
    });

    test(
        'one MiB Submission including worst-case wrapper escaping fits unchanged P9 budget',
        () async {
      final context = await f.stageContext();
      // A valid wrapper at the exact byte ceiling; P3 owns body rejection.
      final body = '\u0000' * (1024 * 1024);
      final envelope = command(
          stageName, {'submissionJson': body, 'externalRequestId': null});
      expect(utf8.encode(envelope.payload).length,
          lessThan(IpcEnvelopeLimits.requestBytes));
      final result = await adapter.invoke(envelope, context: context);
      expect(result.execution, isNotNull);
      expect(
          response(result)['error'], 'capability.generatedInvalidSubmission');
      final valid = submission(key: 'max-bytes');
      final padded = valid + (' ' * (1024 * 1024 - utf8.encode(valid).length));
      final staged = data(await adapter.invoke(
          command(stageName,
              {'submissionJson': padded, 'externalRequestId': 'x' * 128}),
          context: context));
      expect(staged['submissionKey'], 'max-bytes');
    });

    test(
        'encoder failure keeps original completed STAGE evidence and real restart reconciliation',
        () async {
      encoder.fail = true;
      final result = await adapter.invoke(
          command(stageName, {
            'submissionJson': submission(key: 'restart-key'),
            'externalRequestId': null
          }),
          context: await f.stageContext());
      expect(result.frame, isNull);
      expect(result.failure, 'responseEncodingFailed');
      final original = result.execution!;
      expect(original.receipt.status, CapabilityExecutionStatus.completed);
      expect(original.receipt.knownEffect, CapabilityEffect.proposalStaged);
      final proposalId = (original.output as ExternalStageSummary).proposalId;
      expect(await f.h.s.h.count('generated_question_proposals'), 1);
      await adapter.shutdown();
      f.h.read.close();
      await f.h.read.whenIdle;
      await f.h.s.reopen();
      f.h.compose();
      f.compose();
      await f.startHost();
      auth.session = f.h.s.session;
      encoder.fail = false;
      adapter = OfflineIpcCommandProjection(
          host: f.host, authentication: auth, encoder: encoder);
      final found = data(await adapter.invoke(command(reconcileName, {}),
          context: await f.host.openReconciliation(f.entry, 'restart-key')));
      expect(found['proposalId'], proposalId);
      expect(await f.h.s.h.count('generated_question_proposals'), 1);
    });

    for (final category in ['egress', 'scope']) {
      test('$category revoke after real content read denies output', () async {
        final context = await f.readContext();
        f.h.barrier.afterSearch = () async {
          await f.h.s.management.replaceGrant(
              f.h.s.profile,
              2,
              f.h.s.policy(
                  permissions: [CapabilityPermission.read],
                  scopes: category == 'scope' ? [] : null,
                  categories: category == 'egress'
                      ? [ExternalContentCategory.proposalMetadata]
                      : [ExternalContentCategory.questionContent]));
        };
        final result = await adapter.invoke(command(searchName, searchInput),
            context: context);
        expect(f.h.contentReads, greaterThan(0));
        expect(response(result)['data'], isNull);
        expect(result.execution!.receipt.knownEffect, CapabilityEffect.none);
      });
    }

    for (final deadline in [false, true]) {
      test(
          'READ ${deadline ? 'deadline' : 'cancel'} retains underlying slot through adapter shutdown',
          () async {
        final context = await f.readContext();
        final reached = Completer<void>(), resume = Completer<void>();
        f.h.barrier.beforeSearch = () async {
          reached.complete();
          await resume.future;
        };
        final control = ExternalCallControl(
            clock: f.h.s.clock,
            deadline: deadline
                ? f.h.s.clock.now().add(const Duration(seconds: 1))
                : null);
        final pending = adapter.invoke(command(searchName, searchInput),
            context: context, control: control);
        await reached.future;
        if (deadline) {
          f.h.s.clock.current =
              f.h.s.clock.current.add(const Duration(seconds: 2));
          control.checkDeadline();
        } else {
          control.cancel();
        }
        final result = await pending;
        expect(response(result)['data'], isNull);
        expect(result.failure,
            deadline ? 'capability.deadlineExceeded' : 'capability.cancelled');
        expect(f.gateway.pendingCount, 1);
        expect(f.h.read.pendingCount, 1);
        var stopped = false;
        final shutdown = adapter.shutdown().then((_) => stopped = true);
        await flushHostMicrotasks();
        expect(stopped, isFalse);
        resume.complete();
        await shutdown;
        expect(f.h.read.pendingCount, 0);
        expect(f.h.contentReads, 0);
      });
    }

    for (final deadline in [false, true]) {
      for (final committed in [false, true]) {
        test(
            'STAGE ${deadline ? 'deadline' : 'cancel'} ${committed ? 'after' : 'before'} commit retains owning settlement',
            () async {
          final context = await f.stageContext();
          final reached = Completer<void>(), resume = Completer<void>();
          f.h.s.checkpoint = (point) async {
            if (point ==
                (committed
                    ? ExternalStageCheckpoint.afterCommit
                    : ExternalStageCheckpoint.authorized)) {
              reached.complete();
              await resume.future;
            }
          };
          final control = ExternalCallControl(
              clock: f.h.s.clock,
              deadline: deadline
                  ? f.h.s.clock.now().add(const Duration(seconds: 1))
                  : null);
          final pending = adapter.invoke(
              command(stageName, {
                'submissionJson': submission(key: 'interrupted'),
                'externalRequestId': null
              }),
              context: context,
              control: control);
          await reached.future;
          if (deadline) {
            f.h.s.clock.current =
                f.h.s.clock.current.add(const Duration(seconds: 2));
            control.checkDeadline();
          } else {
            control.cancel();
          }
          final result = await pending;
          expect(response(result)['data'], isNull);
          expect(result.execution!.receipt.status,
              CapabilityExecutionStatus.outcomeUnknown);
          expect(result.execution!.receipt.knownEffect,
              committed ? CapabilityEffect.proposalStaged : null);
          expect(f.gateway.pendingCount, 1);
          expect(f.h.s.service.pendingCount, 1);
          var stopped = false;
          final shutdown = adapter.shutdown().then((_) => stopped = true);
          await flushHostMicrotasks();
          expect(stopped, isFalse);
          resume.complete();
          await shutdown;
          expect(await f.h.s.h.count('generated_question_proposals'),
              committed ? 1 : 0);
          expect(await f.h.s.h.count('generated_question_commit_receipts'), 0);
        });
      }
    }

    test(
        'shutdown waits for blocked trusted authentication and refuses late admission',
        () async {
      final context = await f.host.openRead(f.entry);
      final reached = Completer<void>(), resume = Completer<void>();
      auth.before = () async {
        reached.complete();
        await resume.future;
      };
      final pending =
          adapter.invoke(command(listName, listInput), context: context);
      await reached.future;
      var stopped = false;
      final shutdown = adapter.shutdown().then((_) => stopped = true);
      await flushHostMicrotasks();
      expect(stopped, isFalse);
      resume.complete();
      expect(response(await pending)['data'], isNull);
      await shutdown;
      expect(f.host.state, LocalHostState.stopped);
    });

    test('response and protocol-error envelopes cannot dispatch', () async {
      final context = await f.host.openRead(f.entry);
      for (final frame in [
        IpcEnvelopeCodec.encodeResponse('r', '{}'),
        IpcEnvelopeCodec.encodeError(IpcProtocolFailure.invalidPayload)
      ]) {
        final result = await adapter.invoke(decode(frame), context: context);
        expect(result.frame, isNull);
        expect(result.failure, 'invalidRequest');
        expect(result.execution, isNull);
      }
    });
  });

  test(
      'four file routes retain explicit snapshot, coverage and derived-cache evidence on encode loss',
      () async {
    final h = FileReadHarness();
    await h.open();
    final gateway =
        ExternalCapabilityGateway(stages: h.s.service, reads: h.read);
    final host = LocalHostDispatchCore(
        gateway: gateway, readiness: OfflineReadiness(() async {}));
    final auth = SyntheticAuthentication(h.s.session);
    final encoder = OfflineEncoder();
    final adapter = OfflineIpcCommandProjection(
        host: host, authentication: auth, encoder: encoder);
    try {
      await host.startOffline();
      final entry = await host.bindSession(h.s.session);
      final parent = await host.openRead(entry, context: await h.context());
      final choices = data(await adapter.invoke(
          command('external_list_file_selections', {}),
          context: parent));
      final selected = ((choices['items'] as List).first as Map)['fileRef'];
      final created = data(await adapter.invoke(
          command('external_create_file_context', {
            'fileRefs': [selected]
          }),
          context: parent));
      final approved =
          await host.openRead(entry, context: created['contextRef']! as String);
      encoder.fail = true;
      final lost = await adapter.invoke(
          command('external_retrieve_file_content',
              {'query': 'needle', 'limit': 8}),
          context: approved);
      expect(lost.frame, isNull);
      expect(lost.failure, 'responseEncodingFailed');
      expect(
          lost.execution!.receipt.knownEffect, CapabilityEffect.derivedCache);
      expect(h.index.searched, hasLength(1));
      encoder.fail = false;
      final search = data(await adapter.invoke(
          command('external_retrieve_file_content',
              {'query': 'needle', 'limit': 20}),
          context: approved));
      expect(search['startsAtDocumentBeginning'], isFalse);
      final ref = ((search['items'] as List).first as Map)['passageRef'];
      final passage = data(await adapter.invoke(
          command(
              'external_get_file_passage', {'passageRef': ref, 'cursor': null}),
          context: approved));
      expect(passage.keys.toSet(), {
        'items',
        'nextCursor',
        'hasMore',
        'unsupportedExcluded',
        'startsAtDocumentBeginning'
      });
      expect(passage['items'], isNotEmpty);
      expect(jsonEncode(passage), isNot(contains('never-release-raw')));
      expect(jsonEncode(passage), isNot(contains('fileId')));
      expect(h.index.searched.toSet(), hasLength(1));
      final noFiles = await adapter.invoke(
          command('external_retrieve_file_content',
              {'query': 'needle', 'limit': 8}),
          context: parent);
      expect(response(noFiles)['data'], isNull);
      expect(h.index.searched.toSet(), hasLength(1));
      h.index.afterSearch = () async =>
          h.grant(categories: [ExternalContentCategory.proposalMetadata]);
      final revoked = await adapter.invoke(
          command('external_retrieve_file_content',
              {'query': 'needle', 'limit': 8}),
          context: approved);
      expect(response(revoked)['data'], isNull);
      expect(revoked.execution, isNotNull);
    } finally {
      await adapter.shutdown();
      await h.close();
    }
  });

  test(
      'P10 is confined to offline infrastructure, without production registration or transport',
      () {
    final file = File('lib/data/external/ipc_command_projection.dart');
    final source = file.readAsStringSync();
    for (final forbidden in [
      'dart:io',
      'dart:ffi',
      'DatabaseHelper',
      'Socket',
      'HttpServer',
      'NamedPipe',
      'ServerSocket',
      'McpServer'
    ]) {
      expect(source, isNot(contains(forbidden)));
    }
    for (final path in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) =>
            f.path.endsWith('.dart') && !f.path.contains('ipc_command_'))) {
      expect(path.readAsStringSync(),
          isNot(contains('ipc_command_projection.dart')),
          reason: path.path);
    }
  });
}
