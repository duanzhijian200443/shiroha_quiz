import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/ui/dependencies/generated_question_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_controllers.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_review_screen.dart';
import '../application/external/external_question_read_test_support.dart';
import '../ui/generated_question/generated_ui_test_support.dart'
    show settleGenerated, tapGenerated;
import 'fixtures/vnext_mcp_test_support.dart';
import 'fixtures/vnext_stdio_settlement_cases.dart';

void main() {
  initializeGeneratedTests();
  group('stdio lifecycle', stdioSettlementCases);
  late EndToEndHarness h;
  setUp(() async {
    h = EndToEndHarness();
    await h.open();
  });
  tearDown(() async => h.close());

  for (final protocol in [McpProtocol.require2026, McpProtocol.legacy]) {
    test(
        'real stdio ${protocol.name}: stage, duplicate/conflict, reads and key recovery',
        () async {
      final client = await h.connect(protocol);
      final tools = await client.listTools();
      expect(tools.tools.map((t) => t.name).toSet(), {
        'open_generation_context',
        'search_questions',
        'get_question_detail',
        'retrieve_file_content',
        'get_file_passage',
        'propose_generated_questions',
        'get_question_proposal',
      });
      expect(tools.tools.every((t) => t.outputSchema != null), isTrue);
      expect(
          tools.tools
              .where((t) => t.annotations?.readOnlyHint == false)
              .map((t) => t.name),
          ['propose_generated_questions']);
      final byName = {for (final tool in tools.tools) tool.name: tool};
      expect(byName['open_generation_context']!.annotations?.idempotentHint,
          isFalse);
      expect(byName['propose_generated_questions']!.annotations?.idempotentHint,
          isTrue);
      final ref = await context(client);
      final before = await h.app.h.s.h.count('questions');
      final staged = await call(
          client, 'propose_generated_questions', batch(ref, 'batch'));
      expect(staged['error'], isNull);
      expect(staged['data']['publication'], 'STAGED');
      expect(staged['data']['formalCommit'], 'NOT_REPORTED');
      expect(await h.app.h.s.h.count('questions'), before);
      expect(await h.app.h.s.h.count('generated_question_proposals'), 1);
      expect(
          await call(
              client, 'propose_generated_questions', batch(ref, 'batch')),
          staged);
      final conflict = await call(client, 'propose_generated_questions',
          batch(ref, 'batch', suffix: ' changed'));
      expect(conflict['error'], isNotNull);
      expect(await h.app.h.s.h.count('generated_question_proposals'), 1);
      final queried = await call(
          client, 'get_question_proposal', {'submissionKey': 'batch'});
      expect(queried['data'], {
        'submissionKey': 'batch',
        'lifecycleStatus': 'pending_review',
        'requestedCount': 3,
        'actualCount': 3,
        'committedCount': 0,
        'rejectedCount': 0,
      });
      final inbox = GeneratedProposalInboxController(h.app.h.s.localFactory);
      await inbox.load();
      expect(inbox.lastError, isNull);
      expect(inbox.proposals.single.lifecycleStatus,
          GeneratedStatus.pendingReview);
      expect(inbox.proposals.single.items.length, 3);
      inbox.dispose();
      final search = await call(
          client, 'search_questions', {'contextRef': ref, 'query': 'needle'});
      final hit = (search['data']['items'] as List).single as Map;
      expect(
          (await call(client, 'get_question_detail',
              {'contextRef': ref, 'questionRef': hit['questionRef']}))['error'],
          isNull);
      final files =
          await call(client, 'open_generation_context', {'contextRef': ref});
      // This composition installs no File reader or fileContent authority.
      expect(files['data'], isNull);
      expect(files['error'], isNotNull);
      expect(
          (await call(client, 'retrieve_file_content', {
            'contextRef': ref,
            'query': 'not authorized by a source snapshot'
          }))['error'],
          isNotNull);
    });
  }

  test('lost response: new stdio client queries original key without restaging',
      () async {
    final client = await h.connect();
    final ref = await context(client);
    h.loseResponse = true;
    expect(
        (await call(client, 'propose_generated_questions', batch(ref, 'lost')))[
            'error'],
        'outcome_unknown');
    await client.close();
    // Real close/reopen: no old handle, completed-call Map or pending slot can
    // supply this result. Fresh App authentication binds the original Profile.
    await h.restart();
    final next = await h.connect();
    final recovered =
        await call(next, 'get_question_proposal', {'submissionKey': 'lost'});
    expect(recovered['error'], isNull);
    expect(recovered['data']['lifecycleStatus'], 'pending_review');
    expect(h.stageCalls, 1);
    expect(await h.app.h.s.h.count('generated_question_proposals'), 1);
    expect(await h.app.h.s.h.count('questions'), 2);
  });

  test(
      'unauthorized, invalid content, expired Context, revoked and unavailable reject',
      () async {
    final client = await h.connect();
    final ref = await context(client);
    h.auth.session = null;
    expect(
        (await call(client, 'propose_generated_questions',
            batch(ref, 'denied')))['error'],
        'unauthenticated');
    h.auth.session = h.app.h.s.session;
    final invalid = batch(ref, 'invalid');
    ((invalid['submission'] as Map)['items'] as List).first['unexpected'] =
        true;
    expect(
        (await call(client, 'propose_generated_questions', invalid))['error'],
        isNotNull);
    h.app.h.s.clock.current =
        h.app.h.s.clock.current.add(const Duration(minutes: 16));
    expect(
        (await call(client, 'propose_generated_questions',
            batch(ref, 'expired')))['error'],
        isNotNull);
    await h.app.h.s.management.revokeGrant(h.app.h.s.profile, 2);
    expect(
        (await call(client, 'get_question_proposal',
            {'submissionKey': 'denied'}))['error'],
        isNotNull);
    await h.composition.close();
    expect((await call(client, 'open_generation_context'))['error'],
        'unavailable');
    expect(await h.app.h.s.h.count('generated_question_proposals'), 0);
  });

  test(
      'READ handle without App approval and a fresh Session cannot inherit STAGE',
      () async {
    final client = await h.connect();
    final ref = await context(client);
    final original = h.app.h.s.session;
    final other = h.app.h.s.trust.openSession(
        h.app.h.s.trust.authenticate(h.app.h.s.credentials.authentication));
    h.auth.session = other;
    expect(
        (await call(client, 'propose_generated_questions',
            batch(ref, 'other-session')))['error'],
        isNotNull);
    h.auth.session = original;
    // A separate trusted composition with no approved target grants no STAGE.
    final unapproved = VnextMcpAppComposition(
        host: h.app.host,
        reads: h.app.h.read,
        stages: h.app.h.s.service,
        authentication: h.auth,
        approvedTargets: []);
    expect(
        (await unapproved.call(
            'propose_generated_questions', batch(ref, 'no-approval'),
            cancelled: const Stream.empty(), available: () => true))['error'],
        isNotNull);
    expect(await h.app.h.s.h.count('generated_question_proposals'), 0);
  });

  test('STAGE bounds refuse before approval or payload serialization',
      () async {
    final client = await h.connect();
    final ref = await context(client);
    final unapproved = VnextMcpAppComposition(
        host: h.app.host,
        reads: h.app.h.read,
        stages: h.app.h.s.service,
        authentication: h.auth,
        approvedTargets: []);
    Future<Map<String, Object?>> direct(
            VnextMcpAppComposition composition, Map<String, dynamic> args) =>
        composition.call('propose_generated_questions', args,
            cancelled: const Stream.empty(), available: () => true);

    final oversizedProbe = SubmissionEncodingProbe();
    final oversized = <String, dynamic>{
      'contextRef': ref,
      'submission': {
        'schemaVersion': 1,
        'submissionKey': 'oversized',
        'requestedCount': 1,
        'items': [oversizedProbe],
        'padding': 'x' * (1024 * 1024 + 1),
      },
    };
    // Exact-Session approval precedes any serialization attempt.
    expect((await direct(unapproved, oversized))['error'],
        'capability.accessDenied');
    expect(oversizedProbe.encoded, isFalse);
    // With approval the frozen bounds reject before a STAGE frame exists.
    expect((await direct(h.composition, oversized))['error'], 'invalidRequest');
    expect(oversizedProbe.encoded, isFalse);

    final deepProbe = SubmissionEncodingProbe();
    Object nested = deepProbe;
    for (var i = 0; i < 20; i++) {
      nested = [nested];
    }
    expect(
        (await direct(h.composition, {
          'contextRef': ref,
          'submission': {
            'schemaVersion': 1,
            'submissionKey': 'deep',
            'requestedCount': 1,
            'items': [nested],
          },
        }))['error'],
        'invalidRequest');
    expect(deepProbe.encoded, isFalse);
    expect(await h.app.h.s.h.count('generated_question_proposals'), 0);
    // A bounded, approved submission still stages through the same owner.
    final staged = await call(
        client, 'propose_generated_questions', batch(ref, 'bounded'));
    expect(staged['error'], isNull);
    expect(staged['data']['publication'], 'STAGED');
  });

  test('READ metadata only is independent of STAGE and does not enumerate keys',
      () async {
    final client = await h.connect();
    final ref = await context(client);
    await call(client, 'propose_generated_questions', batch(ref, 'scoped'));
    final s = h.app.h.s;
    Future<void> grant(int revision,
            {List<CapabilityPermission> permissions = const [
              CapabilityPermission.read
            ],
            List<ExternalContentCategory> categories = const [
              ExternalContentCategory.proposalMetadata
            ],
            List<ExternalGrantScope>? scopes}) =>
        s.management.replaceGrant(
            s.profile,
            revision,
            s.policy(
                permissions: permissions,
                categories: categories,
                scopes: scopes));
    Future<Map<String, dynamic>> query(String key) =>
        call(client, 'get_question_proposal', {'submissionKey': key});
    await grant(2);
    expect(
        (await query('scoped'))['data']['lifecycleStatus'], 'pending_review');
    expect((await s.reconcile('scoped')).output, isNull);
    await grant(3, permissions: [CapabilityPermission.stage]);
    expect((await query('scoped'))['data'], isNull);
    expect((await s.reconcile('scoped')).output, isNotNull);
    await grant(4, categories: [ExternalContentCategory.questionContent]);
    expect((await query('scoped'))['data'], isNull);
    await grant(5, scopes: [
      ExternalGrantScope(
          kind: ExternalTargetKind.bank, targetId: 'private-bank')
    ]);
    expect(await query('scoped'), await query('absent'));
    // Another fully authenticated Profile with identical bank scope still cannot
    // resolve the original Profile's key, even in the same TrustCore.
    s.profile = await s.management.createProfile(
        displayName: 'Other synthetic', adapter: 'bridge', protocol: 'tcp-v1');
    await s.management.replaceGrant(
        s.profile, 0, s.policy(permissions: [CapabilityPermission.read]));
    await h.restart();
    expect(await query('scoped'), await query('absent'));
    await s.management.revokeGrant(s.profile, 1);
    expect((await query('scoped'))['data'], isNull);
  });

  test(
      'terminal mixed local review counts survive restart and reauthentication',
      () async {
    final client = await h.connect();
    final ref = await context(client);
    final staged =
        await call(client, 'propose_generated_questions', batch(ref, 'mixed'));
    final id = staged['data']['proposalId'] as String;
    final c = GeneratedProposalReviewController(
        proposalId: id,
        factory: h.app.h.s.localFactory,
        service: h.app.h.s.h.service);
    await c.load();
    for (var i = 0; i < c.workingItems.length; i++) {
      c.decide(c.workingItems[i].itemId,
          i == 0 ? GeneratedDecision.rejected : GeneratedDecision.accepted);
    }
    expect(await c.save(c.target!), isTrue);
    final pending =
        await call(client, 'get_question_proposal', {'submissionKey': 'mixed'});
    expect(pending['data']['rejectedCount'], 0);
    await c.confirmTerminal((await c.prepareTerminal())!);
    expect(c.lastError, isNull);
    c.dispose();
    final result =
        await call(client, 'get_question_proposal', {'submissionKey': 'mixed'});
    expect(result['data'], {
      'submissionKey': 'mixed',
      'lifecycleStatus': 'committed',
      'requestedCount': 3,
      'actualCount': 3,
      'committedCount': 2,
      'rejectedCount': 1
    });
    // Reconciliation reports the original committed effect without writing again.
    final questionsBefore = await h.app.h.s.h.count('questions');
    final receiptsBefore =
        await h.app.h.s.h.count('generated_question_commit_receipts');
    final reconciliation = await h.app.h.s.reconcile('mixed');
    expect(reconciliation.output!.proposalId, id);
    expect(reconciliation.effect, CapabilityEffect.formalMutation);
    expect(await h.app.h.s.h.count('questions'), questionsBefore);
    expect(await h.app.h.s.h.count('generated_question_commit_receipts'),
        receiptsBefore);
    await client.close();
    await h.restart();
    final recovered = await h.app.h.s.reconcile('mixed');
    expect(recovered.output!.proposalId, id);
    expect(recovered.effect, CapabilityEffect.formalMutation);
    expect(await h.app.h.s.h.count('questions'), questionsBefore);
    expect(await h.app.h.s.h.count('generated_question_commit_receipts'),
        receiptsBefore);
    expect(
        await call(await h.connect(), 'get_question_proposal',
            {'submissionKey': 'mixed'}),
        result);
  });

  test('a locally retargeted Proposal requires both original and current Scope',
      () async {
    final client = await h.connect();
    final staged = await call(client, 'propose_generated_questions',
        batch(await context(client), 'retargeted'));
    final c = GeneratedProposalReviewController(
        proposalId: staged['data']['proposalId'] as String,
        factory: h.app.h.s.localFactory,
        service: h.app.h.s.h.service);
    await c.load();
    final target = c.targets
        .firstWhere((choice) => choice.target.bankName == 'private-bank')
        .target;
    c.rebind(target);
    expect(await c.save(target), isTrue);
    c.dispose();
    Future<Map<String, dynamic>> query(String key) =>
        call(client, 'get_question_proposal', {'submissionKey': key});
    expect(await query('retargeted'), await query('absent'));
    final s = h.app.h.s;
    await s.management.replaceGrant(
        s.profile,
        2,
        s.policy(permissions: [
          CapabilityPermission.read
        ], categories: [
          ExternalContentCategory.proposalMetadata
        ], scopes: [
          s.bank,
          ExternalGrantScope(
              kind: ExternalTargetKind.bank, targetId: 'private-bank')
        ]));
    expect((await query('retargeted'))['data']['lifecycleStatus'],
        'pending_review');
    await s.management.replaceGrant(
        s.profile,
        3,
        s.policy(permissions: [
          CapabilityPermission.read
        ], scopes: [
          ExternalGrantScope(
              kind: ExternalTargetKind.bank, targetId: 'private-bank')
        ]));
    expect(await query('retargeted'), await query('absent'));
  });

  test('COMMIT and claimed authority are absent from the protocol', () async {
    final client = await h.connect(McpProtocol.legacy);
    final ref = await context(client);
    await expectLater(
        client.callTool(CallToolRequest(
            name: 'commit_generated_questions',
            arguments: {'contextRef': ref})),
        throwsA(isA<McpError>()));
    final rejected = await client.callTool(
        CallToolRequest(name: 'propose_generated_questions', arguments: {
      ...batch(ref, 'forged'),
      'clientProfileId': 'forged',
      'trusted': true,
      'bankName': 'private-bank'
    }));
    expect(rejected.isError, isTrue);
    expect(h.stageCalls, 0);
    expect(await h.app.h.s.h.count('generated_question_proposals'), 0);
  });

  test(
      'standalone production entrypoint always refuses without admitted App transport',
      () async {
    final client = await h.connect(
        McpProtocol.require2026, 'lib/mcp/vnext_mcp_entrypoint.dart');
    expect((await client.listTools()).tools.length, 7);
    expect((await call(client, 'open_generation_context'))['error'],
        'unavailable');
    expect(
        (await call(client, 'get_question_proposal',
            {'submissionKey': 'absent'}))['error'],
        'unavailable');
    expect(h.stageCalls, 0);
    expect(await h.app.h.s.h.count('generated_question_proposals'), 0);
  });

  for (final reject in [false, true]) {
    testWidgets(
        'stdio Proposal loads existing Review UI; explicit UI ${reject ? 'rejection' : 'approval'} is queried after restart',
        (tester) async {
      final data = (await tester.runAsync(() async {
        final client = await h.connect();
        final ref = await context(client);
        return call(client, 'propose_generated_questions', batch(ref, 'ui'));
      }))!;
      final id = data['data']['proposalId'] as String;
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
            home: GeneratedProposalReviewScreen(
                proposalId: id,
                dependencies: GeneratedQuestionDependenciesScope(
                    authority: h.app.h.s.localFactory,
                    service: h.app.h.s.h.service,
                    child: const SizedBox()))));
      });
      Future<void> tap(Finder finder) => tapGenerated(tester, finder);
      await settleGenerated(tester);
      expect(find.textContaining('Select one'), findsWidgets);
      final proposal =
          (await tester.runAsync(() => h.app.h.s.localSession.read(id)))!;
      for (final item in proposal.items) {
        final finder = find.byKey(ValueKey(
            'generated-${reject ? 'rejected' : 'accepted'}-${item.itemId}'));
        await tester.scrollUntilVisible(finder, 250,
            scrollable: find.byType(Scrollable).first);
        await tap(finder);
      }
      expect(await tester.runAsync(() => h.app.h.s.h.count('questions')), 2);
      await tap(find.byKey(const ValueKey('generated-save')));
      await tap(find.byKey(const ValueKey('generated-confirm')));
      await tap(find.byKey(ValueKey(
          reject ? 'generated-reject-proposal' : 'generated-approve')));
      expect(await tester.runAsync(() => h.app.h.s.h.count('questions')), 2);
      await tap(find.byKey(const ValueKey('generated-confirm')));
      if (!reject) {
        expect(find.byKey(const ValueKey('generated-receipt')), findsOneWidget);
      }
      expect(await tester.runAsync(() => h.app.h.s.h.count('questions')),
          reject ? 2 : 5);
      expect(
          await tester.runAsync(
              () => h.app.h.s.h.count('generated_question_commit_receipts')),
          reject ? 0 : 1);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        final result = await call(
            h.clients.last, 'get_question_proposal', {'submissionKey': 'ui'});
        expect(result['data'], {
          'submissionKey': 'ui',
          'lifecycleStatus': reject ? 'rejected' : 'committed',
          'requestedCount': 3,
          'actualCount': 3,
          'committedCount': reject ? 0 : 3,
          'rejectedCount': reject ? 3 : 0
        });
        await h.clients.last.close();
        await h.restart();
        expect(
            await call(await h.connect(), 'get_question_proposal',
                {'submissionKey': 'ui'}),
            result);
      });
    });
  }
}
