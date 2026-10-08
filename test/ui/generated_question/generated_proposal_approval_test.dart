import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_controllers.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_review_screen.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_inbox_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'generated_ui_test_support.dart';

void main() {
  initializeGeneratedTests();
  late GeneratedUiHarness h;
  setUp(() async {
    h = GeneratedUiHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  GeneratedProposalReviewController controller(GeneratedQuestionProposal p,
          {ControlledGeneratedPersistence? port}) =>
      GeneratedProposalReviewController(
          proposalId: p.proposalId,
          factory: h.authority,
          service: port == null
              ? h.storage.service
              : GeneratedQuestionService(port,
                  admission: h.storage.service.admission));
  Future<void> ready(GeneratedProposalReviewController c) async {
    await c.load();
    for (final item in c.workingItems) {
      c.decide(item.itemId, GeneratedDecision.accepted);
    }
    expect(await c.save(c.target!), isTrue);
  }

  test(
      'deferred/unreviewed/local pending block approval; all rejected uses reject only',
      () async {
    final p = await h.stage();
    final port = ControlledGeneratedPersistence(h.storage.service.persistence),
        c = controller(p, port: port);
    await c.load();
    expect(c.canApprove, isFalse);
    c.decide(p.items.single.itemId, GeneratedDecision.deferred);
    await c.save(c.target!);
    expect(c.canApprove, isFalse);
    c.decide(p.items.single.itemId, GeneratedDecision.accepted);
    expect(c.canApprove, isFalse);
    c.decide(p.items.single.itemId, GeneratedDecision.rejected);
    await c.save(c.target!);
    expect(c.canReject, isTrue);
    expect(await c.prepareTerminal(), isNull);
    final preview = await c.prepareTerminal(reject: true);
    expect(await h.storage.count('questions'), 0);
    await c.confirmTerminal(preview!);
    expect(port.rejectCalls, 1);
    expect(port.approveCalls, 0);
    expect(c.proposal!.lifecycleStatus, GeneratedStatus.rejected);
    expect(await h.storage.count('questions'), 0);
    c.dispose();
  });
  test(
      'lost successful response recovers matching receipt and double submit does not repeat',
      () async {
    final p = await h.stage();
    final port = ControlledGeneratedPersistence(h.storage.service.persistence);
    port.approveOverride = (command, context) async {
      await port.base.approve(command, context);
      throw const GeneratedQuestionException(
          GeneratedFailure.persistenceFailed);
    };
    final c = controller(p, port: port);
    await ready(c);
    final preview = (await c.prepareTerminal())!;
    await c.confirmTerminal(preview);
    expect(c.receipt, isNotNull);
    expect(c.needsVerification, isFalse);
    expect(c.lastError, isNull);
    await c.confirmTerminal(preview);
    expect(port.approveCalls, 1);
    expect(await h.storage.count('questions'), 1);
    final receipt = c.receipt!.toJson();
    c.dispose();
    await h.storage.reopen();
    final reopened = controller(p);
    await reopened.load();
    expect(reopened.receipt!.toJson(), receipt);
    expect(reopened.canApprove, isFalse);
    reopened.dispose();
  });
  test('unknown pending result stays locked and never creates a second write',
      () async {
    final p = await h.stage();
    final port = ControlledGeneratedPersistence(h.storage.service.persistence);
    port.approveOverride = (command, context) async =>
        throw StateError('Synthetic lost acknowledgement');
    final c = controller(p, port: port);
    await ready(c);
    final preview = (await c.prepareTerminal())!;
    await c.confirmTerminal(preview);
    expect(c.needsVerification, isTrue);
    expect(c.editable, isFalse);
    expect(c.lastError, contains('待核实'));
    await c.confirmTerminal(preview);
    await c.reconcile();
    expect(port.approveCalls, 1);
    expect(await h.storage.count('questions'), 0);
    c.dispose();
  });
  test(
      'commit gate suppresses concurrent confirmation and catalog drift requires rebind',
      () async {
    final p = await h.stage();
    final port = ControlledGeneratedPersistence(h.storage.service.persistence);
    final gate = Completer<void>();
    port.approveOverride = (command, context) async {
      await gate.future;
      return port.base.approve(command, context);
    };
    final c = controller(p, port: port);
    await ready(c);
    final preview = (await c.prepareTerminal())!;
    final submitting = c.confirmTerminal(preview);
    expect(c.isCommitting, isTrue);
    await c.confirmTerminal(preview);
    expect(port.approveCalls, 1);
    gate.complete();
    await submitting;
    expect(await h.storage.count('questions'), 1);
    c.dispose();
    final changed = await h.stage(
        key: 'changed', items: [candidate(stem: 'Changed target fixture')]);
    final next = controller(changed);
    await ready(next);
    await h.storage.db.update('bank_folders', {'folder_name': 'changed'},
        where: 'bank_name=?', whereArgs: ['bank']);
    await next.confirmTerminal((await next.prepareTerminal())!);
    expect(next.lastError, contains('目标题库'));
    expect(next.receipt, isNull);
    final target = (await next.session!.targets()).single.target;
    next.rebind(target);
    expect(await next.save(target), isTrue);
    expect(next.workingItems.single.decision, GeneratedDecision.unreviewed);
    next.dispose();
  });
  test(
      'terminal by another window yields terminalConflict and adopts its receipt',
      () async {
    final p = await h.stage();
    final first = controller(p);
    await ready(first);
    final second = controller(p);
    await second.load();
    await second.confirmTerminal((await second.prepareTerminal())!);
    second.dispose();
    expect(first.receipt, isNull);
    final preview = await first.prepareTerminal();
    expect(preview, isNull);
    expect(first.lastError, '该批次已完成其他终态操作，请核实持久化结果。');
    expect(first.receipt, isNotNull);
    expect(first.editable, isFalse);
    expect(await h.storage.count('questions'), 1);
    first.dispose();
  });
  test('pending revision drift blocks an unseen accepted-subset swap',
      () async {
    final p = await h.stage(items: [
      candidate(key: 'one'),
      candidate(key: 'two', stem: 'Second candidate')
    ]);
    final first = controller(p);
    await first.load();
    first.decide(p.items.first.itemId, GeneratedDecision.accepted);
    first.decide(p.items.last.itemId, GeneratedDecision.rejected);
    expect(await first.save(first.target!), isTrue);
    final reviewedRevision = first.loadedReviewRevision;

    final second = controller(p);
    await second.load();
    second.decide(p.items.first.itemId, GeneratedDecision.rejected);
    second.decide(p.items.last.itemId, GeneratedDecision.accepted);
    expect(await second.save(second.target!), isTrue);
    expect(second.acceptedCount, first.acceptedCount);
    expect(second.loadedReviewRevision, reviewedRevision! + 1);

    expect(await first.prepareTerminal(), isNull);
    expect(first.hasConflict, isTrue);
    expect(first.lastError, contains('其他窗口'));
    expect(first.loadedReviewRevision, reviewedRevision);
    expect(first.workingItems.first.decision, GeneratedDecision.accepted);
    expect(first.workingItems.last.decision, GeneratedDecision.rejected);
    expect(first.canApprove, isFalse);
    expect(first.receipt, isNull);
    expect(await h.storage.count('questions'), 0);
    expect(await h.storage.count('generated_question_commit_receipts'), 0);

    await first.discardAndReload();
    expect(first.hasConflict, isFalse);
    expect(first.loadedReviewRevision, second.loadedReviewRevision);
    expect(first.workingItems.first.decision, GeneratedDecision.rejected);
    expect(first.workingItems.last.decision, GeneratedDecision.accepted);
    first.dispose();
    second.dispose();
  });

  test('pending revision drift blocks an unseen changed accepted answer',
      () async {
    final p = await h.stage();
    final first = controller(p);
    await ready(first);
    final reviewedRevision = first.loadedReviewRevision;

    final second = controller(p);
    await second.load();
    second.edit({
      'field': 'answer',
      'itemId': p.items.single.itemId,
      'value': {
        'type': 'content',
        'content': [
          {'type': 'text', 'text': 'Changed after review'}
        ]
      }
    });
    expect(second.workingItems.single.decision, GeneratedDecision.unreviewed);
    second.decide(p.items.single.itemId, GeneratedDecision.accepted);
    expect(await second.save(second.target!), isTrue);
    expect(second.loadedReviewRevision, reviewedRevision! + 1);

    expect(await first.prepareTerminal(), isNull);
    expect(first.hasConflict, isTrue);
    expect(first.lastError, contains('其他窗口'));
    expect(first.loadedReviewRevision, reviewedRevision);
    expect(first.workingItems.single.decision, GeneratedDecision.accepted);
    expect(first.canApprove, isFalse);
    expect(first.receipt, isNull);
    expect(await h.storage.count('questions'), 0);
    expect(await h.storage.count('generated_question_commit_receipts'), 0);

    await first.discardAndReload();
    expect(first.hasConflict, isFalse);
    expect(first.loadedReviewRevision, second.loadedReviewRevision);
    final answer = first.workingItems.single.working.answer as ContentAnswer;
    expect(answer.content.nodes.single, const TextNode('Changed after review'));
    first.dispose();
    second.dispose();
  });

  test('duplicate content uses safe error and has no force-approval path',
      () async {
    final first = await h.stage();
    final one = controller(first);
    await ready(one);
    await one.confirmTerminal((await one.prepareTerminal())!);
    one.dispose();
    final second = await h.stage(key: 'duplicate');
    final two = controller(second);
    await ready(two);
    await two.confirmTerminal((await two.prepareTerminal())!);
    expect(two.lastError, contains('重复题目'));
    expect(two.receipt, isNull);
    expect(await h.storage.count('questions'), 1);
    two.dispose();
  });
  for (final size in [const Size(360, 720), const Size(1024, 768)]) {
    testWidgets(
        'real SQLite UI edit subset approval receipt and reopen without duplicates at $size',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final p = (await tester.runAsync(() => h.stage(items: [
            candidate(key: 'one'),
            candidate(key: 'two', stem: 'Rejected fixture')
          ])))!;
      final port =
          ControlledGeneratedPersistence(h.storage.service.persistence);
      if (size.width == 360) {
        port.approveOverride = (command, context) async {
          await port.base.approve(command, context);
          throw const GeneratedQuestionException(
              GeneratedFailure.persistenceFailed);
        };
      }
      final service = GeneratedQuestionService(port,
          admission: h.storage.service.admission);
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
            theme: AppTheme.lightTheme,
            home: GeneratedProposalReviewScreen(
                proposalId: p.proposalId,
                dependencies: h.dependencies(service: service))));
      });
      await settleGenerated(tester);
      await tapGenerated(tester,
          find.byKey(ValueKey('generated-edit-${p.items.first.itemId}')));
      await tester.enterText(
          find.byKey(const ValueKey('generated-node-stem-0')),
          'Edited durable stem');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('generated-apply-edit')), 300,
          scrollable: find.byType(Scrollable).first);
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-apply-edit')));
      await tapGenerated(tester,
          find.byKey(ValueKey('generated-accepted-${p.items.first.itemId}')));
      await tester.scrollUntilVisible(
          find.byKey(ValueKey('generated-rejected-${p.items.last.itemId}')),
          300,
          scrollable: find.byType(Scrollable).first);
      await tapGenerated(tester,
          find.byKey(ValueKey('generated-rejected-${p.items.last.itemId}')));
      expect(
          tester
              .widget<FilledButton>(
                  find.byKey(const ValueKey('generated-approve')))
              .onPressed,
          isNull);
      await tapGenerated(tester, find.byKey(const ValueKey('generated-save')));
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-confirm')));
      expect(await tester.runAsync(() => h.storage.count('questions')), 0);
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-approve')));
      expect(find.textContaining('正式入库：1 题'), findsOneWidget);
      expect(find.textContaining('已拒绝：1 题'), findsOneWidget);
      expect(find.textContaining('审核版本：1'), findsOneWidget);
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-confirm')));
      expect(find.byKey(const ValueKey('generated-receipt')), findsOneWidget);
      final committed =
          (await tester.runAsync(() => h.fixtureSession.read(p.proposalId)))!;
      expect(committed.lifecycleStatus, GeneratedStatus.committed);
      expect(port.approveCalls, 1);
      expect(
          committed.commitReceipt!.itemMappings.keys, [p.items.first.itemId]);
      final rows =
          (await tester.runAsync(() => h.storage.db.query('questions')))!;
      final sidecars = (await tester
          .runAsync(() => h.storage.db.query('question_v2_payloads')))!;
      final review =
          (await tester.runAsync(() => h.storage.db.query('review_states')))!;
      final id = committed.commitReceipt!.itemMappings.values.single;
      expect(rows.single['id'], id);
      expect(sidecars.single['question_id'], id);
      expect(review.single['question_id'], id);
      final typed = const QuestionDraftV2Codec()
          .decode(jsonDecode(sidecars.single['payload_json'] as String));
      expect(typed.stem.nodes.single, const TextNode('Edited durable stem'));
      expect(committed.items.first.original, p.items.first.original);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.storage.reopen);
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
            theme: AppTheme.lightTheme,
            home:
                GeneratedProposalInboxScreen(dependencies: h.dependencies())));
      });
      await settleGenerated(tester);
      expect(find.byKey(const ValueKey('generated-empty')), findsOneWidget);
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-completed')));
      await tapGenerated(
          tester, find.byKey(ValueKey('generated-proposal-${p.proposalId}')));
      expect(find.byKey(const ValueKey('generated-receipt')), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.byKey(const ValueKey('generated-approve')))
              .onPressed,
          isNull);
      expect(await tester.runAsync(() => h.storage.count('questions')), 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'confirmation double-click and back during transaction remain safe',
      (tester) async {
    final p = (await tester.runAsync(() => h.stage()))!;
    final port = ControlledGeneratedPersistence(h.storage.service.persistence);
    final c = controller(p);
    await tester.runAsync(() => ready(c));
    c.dispose();
    final gate = Completer<void>();
    port.approveOverride = (command, context) async {
      await gate.future;
      return port.base.approve(command, context);
    };
    final service =
        GeneratedQuestionService(port, admission: h.storage.service.admission);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme,
          home: GeneratedProposalReviewScreen(
              proposalId: p.proposalId,
              dependencies: h.dependencies(service: service))));
    });
    await settleGenerated(tester);
    await tapGenerated(tester, find.byKey(const ValueKey('generated-approve')));
    await tester.runAsync(() async {
      final position =
          tester.getCenter(find.byKey(const ValueKey('generated-confirm')));
      await tester.tapAt(position);
      await tester.tapAt(position);
      await tester.pump();
    });
    await tester.pumpAndSettle();
    expect(port.approveCalls, 1);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('generated-approve')))
            .onPressed,
        isNull);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(await navigator.maybePop(), isTrue);
    expect(find.byType(GeneratedProposalReviewScreen), findsOneWidget);
    gate.complete();
    await settleGenerated(tester);
    expect(find.byKey(const ValueKey('generated-receipt')), findsOneWidget);
    expect(await tester.runAsync(() => h.storage.count('questions')), 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('all rejected is explicit; passive dismissal writes nothing',
      (tester) async {
    final p = (await tester.runAsync(() => h.stage()))!;
    final port = ControlledGeneratedPersistence(h.storage.service.persistence);
    final service =
        GeneratedQuestionService(port, admission: h.storage.service.admission);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                            builder: (_) => GeneratedProposalReviewScreen(
                                proposalId: p.proposalId,
                                dependencies:
                                    h.dependencies(service: service)))),
                    child: const Text('打开审核'))))));
    await tapGenerated(tester, find.text('打开审核'));
    await tapGenerated(tester,
        find.byKey(ValueKey('generated-accepted-${p.items.single.itemId}')));
    await tapGenerated(tester, find.byType(BackButton));
    expect(find.text('存在未保存审核修改'), findsOneWidget);
    await tapGenerated(
        tester, find.byKey(const ValueKey('generated-discard-exit')));
    expect(await tester.runAsync(() => h.storage.count('questions')), 0);
    expect(port.rejectCalls, 0);
    expect(port.approveCalls, 0);
    await tapGenerated(tester, find.text('打开审核'));
    await tapGenerated(tester,
        find.byKey(ValueKey('generated-rejected-${p.items.single.itemId}')));
    await tapGenerated(tester, find.byKey(const ValueKey('generated-save')));
    await tapGenerated(tester, find.byKey(const ValueKey('generated-confirm')));
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('generated-approve')))
            .onPressed,
        isNull);
    await tapGenerated(
        tester, find.byKey(const ValueKey('generated-reject-proposal')));
    expect(port.rejectCalls, 0);
    await tapGenerated(tester, find.byKey(const ValueKey('generated-confirm')));
    expect(port.rejectCalls, 1);
    expect(port.approveCalls, 0);
    final result =
        await tester.runAsync(() => h.fixtureSession.read(p.proposalId));
    expect(result!.lifecycleStatus, GeneratedStatus.rejected);
    expect(await tester.runAsync(() => h.storage.count('questions')), 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'deleted evidence blocks approval until explicit saved acknowledgement',
      (tester) async {
    final evidence = (await tester.runAsync(h.addSource))!;
    final p = (await tester.runAsync(() => h.stage(items: [
          candidate(evidence: ['evidence'])
        ], evidence: evidence)))!;
    await tester.runAsync(() => h.storage.db.delete('library_files',
        where: 'file_id=?', whereArgs: ['source-file']));
    final c = controller(p);
    await tester.runAsync(() => ready(c));
    c.dispose();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme,
          home: GeneratedProposalReviewScreen(
              proposalId: p.proposalId, dependencies: h.dependencies())));
    });
    await settleGenerated(tester);
    await tapGenerated(tester, find.byKey(const ValueKey('generated-approve')));
    await tapGenerated(tester, find.byKey(const ValueKey('generated-confirm')));
    expect(find.textContaining('来源证据已变化'), findsOneWidget);
    expect(await tester.runAsync(() => h.storage.count('questions')), 0);
    await tapGenerated(
        tester, find.byKey(ValueKey('generated-ack-${p.items.single.itemId}')));
    expect(find.textContaining('unavailable'), findsWidgets);
    await tapGenerated(tester, find.byKey(const ValueKey('generated-confirm')));
    await tapGenerated(tester, find.byKey(const ValueKey('generated-save')));
    await tapGenerated(tester, find.byKey(const ValueKey('generated-confirm')));
    await tapGenerated(tester, find.byKey(const ValueKey('generated-approve')));
    await tapGenerated(tester, find.byKey(const ValueKey('generated-confirm')));
    expect(find.byKey(const ValueKey('generated-receipt')), findsOneWidget);
    final result =
        (await tester.runAsync(() => h.fixtureSession.read(p.proposalId)))!;
    expect(result.items.single.evidence.single.toJson(),
        p.items.single.evidence.single.toJson());
    expect(await tester.runAsync(() => h.storage.count('questions')), 1);
    await tester.pumpWidget(const SizedBox());
  });
}
