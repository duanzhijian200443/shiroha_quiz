// Synthetic credentials, original P8/P7/P3-P6 and isolated real SQLite only.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/data/external/ipc_command_projection.dart';
import 'package:shiroha_quiz/data/external/ipc_envelope_codec.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_protocol_projection.dart';
import '../../../application/external/local_host_test_support.dart';
import '../../../application/external/external_question_read_test_support.dart';

final class _Authentication implements OfflineIpcAuthenticationPort {
  _Authentication(this.session);
  ExternalSession? session;
  int calls = 0;
  void Function(int)? before;
  @override
  Future<ExternalSession?> authenticate() async {
    before?.call(++calls);
    return session;
  }
}

final class _Encoder implements IpcCommandFrameEncoder {
  bool fail = false;
  @override
  Uint8List encodeResponse(String id, String payload) {
    if (fail) throw StateError('synthetic withheld encoder failure');
    return IpcEnvelopeCodec.encodeResponse(id, payload);
  }
}

final class _BindingBarrier implements IpcTrustedContextBinding {
  _BindingBarrier(this.inner);
  final IpcTrustedContextBinding inner;
  final entered = Completer<void>(), resume = Completer<void>();
  ExternalCallControl? received;
  @override
  LocalHostDispatchCore get host => inner.host;
  @override
  ExternalClock get clock => inner.clock;
  @override
  Duration get readTimeout => inner.readTimeout;
  @override
  Future<ExternalExecutionContext> bind({
    required ExternalSession session,
    required LocalHostSessionEntry entry,
    required IpcContextSelection selection,
    required ExternalCallControl control,
  }) async {
    received = control;
    entered.complete();
    await resume.future;
    return inner.bind(
        session: session, entry: entry, selection: selection, control: control);
  }
}

UntrustedIpcEnvelope _raw(String payload) => VnextMcpCommand.decodeFrame(
    IpcEnvelopeCodec.encodeRequest('v3-correlation-only', payload));
UntrustedIpcEnvelope _request(String capability, Map<String, Object?> input,
        {int version = 3}) =>
    _raw(jsonEncode({
      'schemaVersion': version,
      'type': 'command',
      'capability': capability,
      'input': input,
    }));
Map<String, Object?> _response(OfflineIpcCommandResult result) {
  final envelope = VnextMcpCommand.decodeFrame(result.frame!);
  expect(envelope.requestId, 'v3-correlation-only');
  return IpcCommandResponseCodec.decode(envelope);
}

Map<String, Object?> _data(OfflineIpcCommandResult result) {
  final response = _response(result);
  expect(response['schemaVersion'], 3);
  expect(response['error'], isNull);
  return (response['data'] as Map).cast<String, Object?>();
}

void ipcCommandV3Cases() {
  group('P10 v3 authenticated App selection', () {
    late OfflineHostHarness f;
    late _Authentication auth;
    late _Encoder encoder;
    late VnextMcpAppComposition app;
    late OfflineIpcCommandProjection projection;
    setUp(() async {
      f = OfflineHostHarness();
      await f.open();
      auth = _Authentication(f.h.s.session);
      encoder = _Encoder();
      app = VnextMcpAppComposition(
          host: f.host,
          reads: f.h.read,
          stages: f.h.s.service,
          authentication: auth,
          approvedTargets: const []);
      projection = OfflineIpcCommandProjection(
          host: f.host, authentication: auth, encoder: encoder);
    });
    tearDown(() async {
      await projection.shutdown();
      await app.close();
      await f.close();
    });
    Future<OfflineIpcCommandResult> invoke(
            String name, Map<String, Object?> input, {int version = 3}) =>
        projection.invokeV3(_request(name, input, version: version),
            binding: app);
    Future<String> context() async {
      final targets = _data(await invoke(
          'external_list_targets', {'pageSize': 20, 'cursor': null}));
      final target = (targets['items'] as List).single as Map;
      return _data(await invoke('external_create_read_context',
          {'targetRef': target['targetRef']}))['contextRef'] as String;
    }

    ExternalSession anotherSession() => f.h.s.trust.openSession(
        f.h.s.trust.authenticate(f.h.s.credentials.authentication));
    Map<String, Object?> search(String ref) =>
        {'contextRef': ref, 'query': 'needle', 'pageSize': 20, 'cursor': null};
    Map<String, Object?> stage(String ref, String key) => {
          'contextRef': ref,
          'submissionJson': submission(key: key),
          'externalRequestId': null
        };

    test(
        'A/B READ references revalidate; every call receives its own execution Context',
        () async {
      final ref = await context();
      final found =
          _data(await invoke('external_search_questions', search(ref)));
      final hit = (found['items'] as List).single as Map;
      auth.session = anotherSession();
      expect(identical(auth.session, f.h.s.session), isFalse);
      final detail = _data(await invoke('external_get_question_detail',
          {'contextRef': ref, 'questionRef': hit['questionRef']}));
      expect(detail['sourceKind'], 'typed');
      expect(detail['answer'], isNotNull);
      expect(
          _data(
              await invoke('external_search_questions', search(ref)))['items'],
          hasLength(1));
    });

    test(
        'foreign Principal and wrong reference kind never select trusted Context',
        () async {
      final targets = _data(await invoke(
          'external_list_targets', {'pageSize': 20, 'cursor': null}));
      final targetRef = ((targets['items'] as List).single as Map)['targetRef'];
      final wrong = await invoke(
          'external_search_questions', search(targetRef as String));
      expect(_response(wrong)['error'], 'capability.accessDenied');
      expect(wrong.execution, isNull);
      final ref = await context();
      final foreign = OfflineHostHarness();
      await foreign.open();
      try {
        auth.session = foreign.h.s.session;
        expect(
            _response(await invoke('external_search_questions', search(ref)))[
                'error'],
            'unauthenticated');
        expect(f.h.contentReads, 0);
      } finally {
        await foreign.close();
      }
    });

    for (final mutation in [
      'revision',
      'revoke',
      'disable',
      'expiry',
      'restart'
    ]) {
      test('$mutation rejects old READ selection without content lookup',
          () async {
        final ref = await context();
        final s = f.h.s;
        final revision =
            (await s.management.read(s.profile)).profile.grantRevision;
        switch (mutation) {
          case 'revision':
            await s.management.replaceGrant(
                s.profile,
                revision,
                s.policy(permissions: [
                  CapabilityPermission.read,
                  CapabilityPermission.stage
                ]));
          case 'revoke':
            await s.management.revokeGrant(s.profile, revision);
          case 'disable':
            s.trust.disable(s.principal);
          case 'expiry':
            s.clock.current = s.clock.current.add(const Duration(minutes: 16));
          case 'restart':
            s.trust.restart();
        }
        final denied = await invoke('external_search_questions', search(ref));
        expect(_response(denied)['data'], isNull);
        expect(_response(denied)['error'], isNotNull);
        expect(f.h.contentReads, 0);
      });
    }

    test(
        'same-Session STAGE only; B cannot inherit A approval; original-key reconciliation',
        () async {
      final ref = await context();
      app.replaceApprovedTargets([await f.h.s.context()]);
      final staged = _data(await invoke(
          'external_stage_generated_questions', stage(ref, 'v3-original-key')));
      expect(staged['submissionKey'], 'v3-original-key');
      expect(staged['publication'], 'STAGED');
      expect(staged['formalCommit'], 'NOT_REPORTED');
      auth.session = anotherSession();
      expect(
          _response(await invoke('external_stage_generated_questions',
              stage(ref, 'must-not-publish')))['error'],
          'capability.accessDenied');
      final reconciled = _data(await invoke(
          'external_reconcile_generated_stage',
          {'submissionKey': 'v3-original-key'}));
      expect(reconciled['proposalId'], staged['proposalId']);
      expect(await f.h.s.h.count('generated_question_proposals'), 1);
      expect(await f.h.s.h.count('generated_question_commit_receipts'), 0);
    });

    test(
        'lifecycle is independent READ/metadata, without STAGE, content grant or old handle',
        () async {
      await f.h.s.stage(key: 'metadata-key');
      final revision =
          (await f.h.s.management.read(f.h.s.profile)).profile.grantRevision;
      await f.h.s.management.replaceGrant(
          f.h.s.profile,
          revision,
          f.h.s.policy(
              permissions: [CapabilityPermission.read],
              categories: [ExternalContentCategory.proposalMetadata]));
      auth.session = anotherSession();
      final value = _data(await invoke('external_get_proposal_lifecycle',
          {'submissionKey': 'metadata-key'}));
      expect(value, {
        'submissionKey': 'metadata-key',
        'lifecycleStatus': 'pending_review',
        'requestedCount': 1,
        'actualCount': 1,
        'committedCount': 0,
        'rejectedCount': 0
      });
      expect(
          _response(await invoke('external_get_proposal_lifecycle',
              {'submissionKey': 'v3-correlation-only'}))['error'],
          'capability.generatedProposalUnavailable');
      expect(
          _response(await invoke('external_reconcile_generated_stage',
              {'submissionKey': 'metadata-key'}))['data'],
          isNull);
      expect(
          _response(await invoke('external_list_targets',
              {'pageSize': 20, 'cursor': null}))['data'],
          isNull);
    });

    test(
        'strict version entry matrix has no legacy Context or selector fallback',
        () async {
      final legacy = await f.host.openRead(f.entry);
      final ref = 'R' * 43; // Valid syntax supplies no Context authority.
      final inputs = <String, Map<String, Object?>>{
        'external_list_targets': {'pageSize': 20, 'cursor': null},
        'external_create_read_context': {'targetRef': ref},
        'external_search_questions': search(ref),
        'external_get_question_detail': {'contextRef': ref, 'questionRef': ref},
        'external_list_file_selections': {'contextRef': ref},
        'external_create_file_context': {
          'contextRef': ref,
          'fileRefs': [ref]
        },
        'external_retrieve_file_content': {
          'contextRef': ref,
          'query': 'needle',
          'limit': 8
        },
        'external_get_file_passage': {
          'contextRef': ref,
          'passageRef': ref,
          'cursor': null
        },
        'external_stage_generated_questions': stage(ref, 'matrix-only'),
        'external_reconcile_generated_stage': {'submissionKey': 'matrix-only'},
        'external_get_proposal_lifecycle': {'submissionKey': 'matrix-only'}
      };
      for (final item in inputs.entries) {
        for (final version in [1, 2, 4]) {
          final result = await invoke(item.key, item.value, version: version);
          expect(_response(result)['error'], 'unsupportedVersion',
              reason: '${item.key}/v$version');
          expect(result.execution, isNull);
        }
        final crossed = await projection.invoke(_request(item.key, item.value),
            context: legacy);
        expect(_response(crossed)['error'], 'unsupportedVersion');
        final parsed = _response(await invoke(item.key, item.value));
        expect(parsed['schemaVersion'], 3);
        expect(parsed['capability'], item.key);
        expect(parsed['error'],
            isNot(isIn(['invalidRequest', 'unsupportedVersion'])));
        for (final field in item.value.keys) {
          final incomplete = Map<String, Object?>.of(item.value)..remove(field);
          final result = await invoke(item.key, incomplete);
          expect(_response(result)['error'], 'invalidRequest',
              reason: '${item.key} missing $field');
          expect(result.execution, isNull);
        }
        final extra =
            await invoke(item.key, {...item.value, 'session': 'claim'});
        expect(_response(extra)['error'], 'invalidRequest');
        expect(extra.execution, isNull);
      }
      expect(
          _data(await invoke('external_list_targets',
              {'pageSize': 20, 'cursor': null}))['items'],
          hasLength(1));
    });

    test(
        'v3 duplicate/unknown/missing/null/invalid selectors fail before handler',
        () async {
      final ref = await context();
      final valid = jsonEncode({
        'schemaVersion': 3,
        'type': 'command',
        'capability': 'external_search_questions',
        'input': search(ref)
      });
      final bad = <String>[
        valid.replaceFirst('"contextRef":"$ref"', '"contextRef":null'),
        valid.replaceFirst('"contextRef":"$ref",', ''),
        valid.replaceFirst(ref, 'short'),
        valid.replaceFirst('"contextRef":"$ref"',
            '"contextRef":"$ref","context\\u0052ef":"$ref"'),
        valid.replaceFirst(
            '"cursor":null', '"cursor":null,"session":"claimed"'),
        valid.replaceFirst('"schemaVersion":3', '"schemaVersion":3.0'),
        valid.replaceFirst(
            '"schemaVersion":3', '"schemaVersion":3,"schemaVersion":3'),
        valid.replaceFirst('"query":"needle"', '"query":"\\ud800"'),
        jsonEncode({
          'schemaVersion': 3,
          'type': 'command',
          'capability': 'external_get_proposal_lifecycle',
          'input': {}
        }),
        for (final key in [null, '', 'bad/key', 'k' * 65])
          jsonEncode({
            'schemaVersion': 3,
            'type': 'command',
            'capability': 'external_get_proposal_lifecycle',
            'input': {'submissionKey': key}
          }),
      ];
      for (final text in bad) {
        final result = await projection.invokeV3(_raw(text), binding: app);
        expect(_response(result)['data'], isNull);
        expect(_response(result)['error'], isNotNull);
        expect(result.execution, isNull);
      }
      auth.session = null;
      expect(
          _response(await projection.invokeV3(_raw('{malformed'),
              binding: app))['error'],
          'unauthenticated');
      expect(f.h.contentReads, 0);
    });

    test('v3 lifecycle never accepts legacy success or a substituted key/ID',
        () {
      final command = VnextMcpCommand.parse(
          'get_question_proposal', {'submissionKey': 'original-key'});
      final value = {
        'schemaVersion': 3,
        'type': 'result',
        'capability': 'external_get_proposal_lifecycle',
        'data': {
          'submissionKey': 'original-key',
          'lifecycleStatus': 'pending_review',
          'requestedCount': 1,
          'actualCount': 1,
          'committedCount': 0,
          'rejectedCount': 0
        },
        'error': null
      };
      UntrustedIpcEnvelope reply(Map<String, Object?> result) =>
          VnextMcpCommand.decodeFrame(IpcEnvelopeCodec.encodeResponse(
              'response-id', jsonEncode(result)));
      expect(command.response(reply(value), 'response-id')['error'], isNull);
      expect(
          () => command.response(
              reply({...value, 'schemaVersion': 2}), 'response-id'),
          throwsFormatException);
      expect(() => command.response(reply(value), 'different-id'),
          throwsFormatException);
      expect(
          () => command.response(
              reply({
                ...value,
                'data': {
                  ...(value['data'] as Map),
                  'submissionKey': 'substituted-key'
                }
              }),
              'response-id'),
          throwsFormatException);
      expect(
          command.response(
              reply({
                'schemaVersion': 1,
                'type': 'result',
                'capability': null,
                'data': null,
                'error': 'unsupportedVersion'
              }),
              'response-id')['error'],
          'unsupportedVersion');
    });

    test('authentication refresh cannot substitute S2 after binding S',
        () async {
      final ref = await context();
      auth.calls = 0;
      auth.before = (count) {
        if (count == 2) auth.session = anotherSession();
      };
      final result = await invoke('external_search_questions', search(ref));
      expect(_response(result)['error'], 'capability.accessDenied');
      expect(result.execution, isNull);
      expect(f.h.contentReads, 0);
    });

    for (final mode in ['cancel', 'deadline', 'shutdown']) {
      test(
          '$mode during binding retains settlement and the original READ deadline',
          () async {
        final barrier = _BindingBarrier(app);
        final control = f.h.s.control();
        final pending = projection.invokeV3(
            _request('external_list_targets', {'pageSize': 20, 'cursor': null}),
            binding: barrier,
            control: control);
        await barrier.entered.future;
        expect(barrier.received!.deadline,
            f.h.s.clock.now().add(const Duration(seconds: 2)));
        var settled = false;
        final drain = projection.whenSettled.then((_) => settled = true);
        Future<void>? closing;
        if (mode == 'cancel') control.cancel();
        if (mode == 'deadline') {
          f.h.s.clock.current =
              f.h.s.clock.current.add(const Duration(seconds: 2));
        }
        if (mode == 'shutdown') closing = projection.shutdown();
        await flushHostMicrotasks();
        expect(settled, isFalse);
        barrier.resume.complete();
        final result = _response(await pending);
        expect(result['data'], isNull);
        expect(
            result['error'],
            mode == 'cancel'
                ? 'capability.cancelled'
                : mode == 'deadline'
                    ? 'capability.deadlineExceeded'
                    : 'capability.accessDenied');
        await closing;
        await drain;
        expect(f.h.contentReads, 0);
      });
    }

    test(
        'committed STAGE encoding loss retains original-key lifecycle and no second writer',
        () async {
      final ref = await context();
      app.replaceApprovedTargets([await f.h.s.context()]);
      encoder.fail = true;
      final lost = await invoke(
          'external_stage_generated_questions', stage(ref, 'lost-v3'));
      expect(lost.frame, isNull);
      expect(
          lost.execution!.receipt.knownEffect, CapabilityEffect.proposalStaged);
      encoder.fail = false;
      auth.session = anotherSession();
      expect(
          _data(await invoke('external_get_proposal_lifecycle',
              {'submissionKey': 'lost-v3'}))['lifecycleStatus'],
          'pending_review');
      expect(await f.h.s.h.count('generated_question_proposals'), 1);
    });
  });
}
