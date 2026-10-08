import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/application/generated_question/generated_local_authority.dart';
import 'package:shiroha_quiz/data/repositories/generated_local_authority_repository.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_controllers.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_review_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'generated_ui_test_support.dart';

class _DelayedOwner implements GeneratedLocalIdentityPort {
  _DelayedOwner(this.base);
  final GeneratedLocalIdentityPort base;
  final started = Completer<void>(), release = Completer<void>();
  @override
  Future<String> loadOrCreateOwner() async {
    final result = await base.loadOrCreateOwner();
    started.complete();
    await release.future;
    return result;
  }
}

void main() {
  initializeGeneratedTests();
  late GeneratedUiHarness h;
  setUp(() async {
    h = GeneratedUiHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  test(
      'closing Controller during identity load cannot publish or retain a session',
      () async {
    final p = await h.stage();
    final repository =
        GeneratedLocalAuthorityRepository(databaseHelper: h.storage.helper);
    final identity = _DelayedOwner(repository);
    final authority = GeneratedLocalAuthorityFactory(
        identity: identity,
        proposals: repository,
        compositionIsCurrent: () => true);
    final c = GeneratedProposalReviewController(
        proposalId: p.proposalId,
        factory: authority,
        service: h.storage.service);
    final loading = c.load();
    await identity.started.future;
    c.dispose();
    identity.release.complete();
    await loading;
    expect(c.session, isNull);
    expect(c.proposal, isNull);
    expect(c.editable, isFalse);
    expect(await h.storage.count('questions'), 0);
    authority.invalidate();
  });
  GeneratedProposalReviewController controller(GeneratedQuestionProposal p,
          {GeneratedQuestionService? service}) =>
      GeneratedProposalReviewController(
          proposalId: p.proposalId,
          factory: h.authority,
          service: service ?? h.storage.service);
  test(
      'atomic multi-operation flush, edit resets decision and restart retains originals',
      () async {
    final p = await h.stage(items: [
      candidate(key: 'one'),
      candidate(key: 'two', stem: 'Other item')
    ]);
    final c = controller(p);
    await c.load();
    c.edit({
      'field': 'stem',
      'itemId': p.items.first.itemId,
      'value': [
        {'type': 'block_math', 'latex': 'x=1'}
      ]
    });
    c.decide(p.items.first.itemId, GeneratedDecision.accepted);
    c.decide(p.items.last.itemId, GeneratedDecision.rejected);
    expect(c.localPendingOperations, hasLength(3));
    expect(await c.save(c.target!), isTrue);
    expect(c.loadedReviewRevision, 1);
    expect(c.hasPending, isFalse);
    c.edit({
      'field': 'explanation',
      'itemId': p.items.first.itemId,
      'value': null
    });
    expect(c.workingItems.first.decision, GeneratedDecision.unreviewed);
    expect(await c.save(c.target!), isTrue);
    expect(c.loadedReviewRevision, 2);
    c.dispose();
    await h.storage.reopen();
    final reloaded = controller(p);
    await reloaded.load();
    expect(reloaded.workingItems.first.working.stem.nodes.single,
        isA<BlockMathNode>());
    expect(reloaded.workingItems.first.working.explanation, isNull);
    expect(reloaded.proposal!.items.first.original, p.items.first.original);
    expect(reloaded.workingItems.first.decision, GeneratedDecision.unreviewed);
    reloaded.dispose();
  });
  test(
      'double-window CAS retains unsaved edits and never resubmits stale revision',
      () async {
    final p = await h.stage();
    final port = ControlledGeneratedPersistence(h.storage.service.persistence);
    final service =
        GeneratedQuestionService(port, admission: h.storage.service.admission);
    final first = controller(p, service: service),
        second = controller(p, service: service);
    await first.load();
    await second.load();
    first.decide(p.items.single.itemId, GeneratedDecision.accepted);
    expect(await first.save(first.target!), isTrue);
    second.edit({
      'field': 'stem',
      'itemId': p.items.single.itemId,
      'value': [
        {'type': 'text', 'text': 'Unsaved local'}
      ]
    });
    expect(await second.save(second.target!), isFalse);
    expect(second.hasConflict, isTrue);
    expect(second.hasPending, isTrue);
    expect(second.loadedReviewRevision, 0);
    final calls = port.flushCalls;
    expect(await second.save(second.target!), isFalse);
    expect(port.flushCalls, calls);
    await second.load();
    expect(second.hasPending, isTrue);
    await second.discardAndReload();
    expect(second.hasPending, isFalse);
    expect(second.loadedReviewRevision, 1);
    expect(second.workingItems.single.decision, GeneratedDecision.accepted);
    first.dispose();
    second.dispose();
  });
  test('revision uses returned server value and unsupported edits never queue',
      () async {
    final p = await h.stage();
    final port = ControlledGeneratedPersistence(h.storage.service.persistence);
    port.flushOverride = (command, context) async {
      final updated = await port.base.flush(command, context);
      return GeneratedQuestionProposal.fromJson(
          updated.toJson()..['reviewRevision'] = 17);
    };
    final c = controller(p,
        service: GeneratedQuestionService(port,
            admission: h.storage.service.admission));
    await c.load();
    c.edit({
      'field': 'kind',
      'itemId': p.items.single.itemId,
      'value': 'singleChoice'
    });
    expect(c.hasPending, isFalse);
    expect(c.lastError, isNotNull);
    c.decide(p.items.single.itemId, GeneratedDecision.deferred);
    expect(await c.save(c.target!), isTrue);
    expect(c.loadedReviewRevision, 17);
    c.dispose();
  });
  test('current target catalog and explicit rebind reset all decisions',
      () async {
    final p = await h.stage();
    final c = controller(p);
    await c.load();
    c.decide(p.items.single.itemId, GeneratedDecision.accepted);
    await c.save(c.target!);
    await h.storage.db.update('bank_folders', {'folder_name': 'changed'},
        where: 'bank_name=?', whereArgs: ['bank']);
    final choices = await c.session!.targets();
    expect(choices.single.target.folderName, 'changed');
    c.rebind(choices.single.target);
    expect(c.workingItems.single.decision, GeneratedDecision.unreviewed);
    expect(await c.save(choices.single.target), isTrue);
    expect(c.proposal!.originalTarget.toJson(), p.originalTarget.toJson());
    expect(c.target!.folderName, 'changed');
    c.dispose();
  });
  test('R5A resolver shows reparse/delete and saves exact acknowledgement',
      () async {
    const source = '11111111-1111-4111-8111-111111111111';
    String digest(String s) => List.filled(64, s).join();
    await h.storage.db.insert('library_files', {
      'file_id': 'source-file',
      'display_name': 'Synthetic.txt',
      'mime_type': 'text/plain',
      'storage_key': 'source-file/source',
      'size_bytes': 0,
      'sha256': digest('a'),
      'created_at': 1000
    });
    await h.storage.db.insert('parsed_artifact_heads',
        {'file_id': 'source-file', 'last_revision': 1});
    await h.storage.db.insert('parsed_artifacts', {
      'file_id': 'source-file',
      'artifact_id': source,
      'revision': 1,
      'source_sha256': digest('a'),
      'cache_key_version': 1,
      'cache_fingerprint': 'synthetic',
      'parser_route': 'synthetic',
      'parser_version': '1',
      'options_schema_version': 1,
      'payload_schema_version': 1,
      'storage_key': 'artifact/source-file',
      'payload_sha256': digest('b'),
      'size_bytes': 0,
      'published_at': 1000
    });
    final p = await h.stage(items: [
      candidate(evidence: ['evidence'])
    ], evidence: [
      GeneratedEvidence(
          evidenceKey: 'evidence',
          sourceRef: SourceRef.document(sourceId: source),
          fileId: 'source-file',
          artifactRevision: 1,
          artifactDigest: digest('b'))
    ]);
    final c = controller(p);
    await c.load();
    expect((c.evidence[p.items.single.itemId]!.single as Map)['status'],
        'authorized');
    await h.storage.db.update(
        'parsed_artifacts', {'revision': 2, 'payload_sha256': digest('c')},
        where: 'file_id=?', whereArgs: ['source-file']);
    await c.refreshEvidence();
    expect(
        (c.evidence[p.items.single.itemId]!.single as Map)['status'], 'stale');
    c.acknowledge(p.items.single.itemId);
    expect(await c.save(c.target!), isTrue);
    expect(c.workingItems.single.evidenceAcknowledgement, isNotNull);
    await h.storage.db.delete('library_files',
        where: 'file_id=?', whereArgs: ['source-file']);
    await c.refreshEvidence();
    expect((c.evidence[p.items.single.itemId]!.single as Map)['status'],
        'unavailable');
    expect(c.workingItems.single.evidence.map((e) => e.toJson()).toList(),
        p.items.single.evidence.map((e) => e.toJson()).toList());
    c.dispose();
  });
  for (final size in [const Size(360, 720), const Size(1024, 768)]) {
    testWidgets(
        'typed node editing and single-choice Option ID mapping at $size',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final data = candidate(kind: 'singleChoice')
        ..['stem'] = [
          {'type': 'text', 'text': 'Original'},
          {'type': 'inline_math', 'latex': 'x+1'},
          {'type': 'block_math', 'latex': 'y=2'}
        ]
        ..['explanation'] = null;
      final p = (await tester.runAsync(() => h.stage(items: [data])))!;
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
            theme: AppTheme.lightTheme,
            home: GeneratedProposalReviewScreen(
                proposalId: p.proposalId, dependencies: h.dependencies())));
      });
      await settleGenerated(tester);
      await tapGenerated(tester,
          find.byKey(ValueKey('generated-edit-${p.items.single.itemId}')));
      await tester.enterText(
          find.byKey(const ValueKey('generated-node-stem-0')),
          'Edited literal');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tapGenerated(
          tester,
          find.descendant(
              of: find.byKey(const ValueKey('generated-choice-answer')),
              matching: find.byType(DropdownButton<String>)));
      await tapGenerated(tester, find.text('B').last);
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('generated-apply-edit')), 300,
          scrollable: find.byType(Scrollable).first);
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-apply-edit')));
      await tapGenerated(tester,
          find.byKey(ValueKey('generated-accepted-${p.items.single.itemId}')));
      await tapGenerated(tester, find.byKey(const ValueKey('generated-save')));
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-confirm')));
      final saved =
          await tester.runAsync(() => h.fixtureSession.read(p.proposalId));
      expect(saved!.reviewRevision, 1);
      expect(saved.items.single.decision, GeneratedDecision.accepted);
      expect((saved.items.single.working.answer as ChoiceAnswer).optionIds,
          [p.items.single.original.options.last.optionId]);
      expect(saved.items.single.working.stem.nodes[0],
          const TextNode('Edited literal'));
      expect(saved.items.single.working.stem.nodes[1],
          p.items.single.original.stem.nodes[1]);
      expect(saved.items.single.working.stem.nodes[2],
          p.items.single.original.stem.nodes[2]);
      expect(saved.items.single.working.explanation, isNull);
      expect(saved.items.single.original, p.items.single.original);
      await tapGenerated(tester,
          find.byKey(ValueKey('generated-edit-${p.items.single.itemId}')));
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('generated-explanation-empty')), 300,
          scrollable: find.byType(Scrollable).first);
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-explanation-empty')));
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-apply-edit')));
      await tapGenerated(tester, find.byKey(const ValueKey('generated-save')));
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-confirm')));
      final empty =
          await tester.runAsync(() => h.fixtureSession.read(p.proposalId));
      expect(empty!.items.single.working.explanation!.nodes, isEmpty);
      expect(empty.items.single.decision, GeneratedDecision.unreviewed);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'CAS conflict UI retains operations until explicit discard reload',
      (tester) async {
    final p = (await tester.runAsync(() => h.stage()))!;
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme,
          home: GeneratedProposalReviewScreen(
              proposalId: p.proposalId, dependencies: h.dependencies())));
    });
    await settleGenerated(tester);
    await tapGenerated(tester,
        find.byKey(ValueKey('generated-accepted-${p.items.single.itemId}')));
    final other = controller(p);
    await tester.runAsync(other.load);
    other.decide(p.items.single.itemId, GeneratedDecision.rejected);
    await tester.runAsync(() => other.save(other.target!));
    other.dispose();
    await tapGenerated(tester, find.byKey(const ValueKey('generated-save')));
    await tapGenerated(tester, find.byKey(const ValueKey('generated-confirm')));
    expect(find.textContaining('审核内容已被其他窗口修改'), findsOneWidget);
    expect(find.text('未保存操作：1'), findsOneWidget);
    await tapGenerated(tester, find.byKey(const ValueKey('generated-reload')));
    await tapGenerated(tester, find.text('取消'));
    expect(find.text('未保存操作：1'), findsOneWidget);
    await tapGenerated(tester, find.byKey(const ValueKey('generated-reload')));
    await tapGenerated(tester, find.byKey(const ValueKey('generated-confirm')));
    expect(find.text('未保存操作：0'), findsOneWidget);
    expect(find.textContaining('审核版本 1'), findsOneWidget);
    final persisted =
        await tester.runAsync(() => h.fixtureSession.read(p.proposalId));
    expect(persisted!.items.single.decision, GeneratedDecision.rejected);
    await tester.pumpWidget(const SizedBox());
  });
}
