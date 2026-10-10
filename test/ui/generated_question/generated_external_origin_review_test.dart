import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_controllers.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_inbox_screen.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_review_screen.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import '../../application/generated_question/external_origin_test_support.dart'
    show insertExternalHistory;
import 'generated_ui_test_support.dart';

void main() {
  initializeGeneratedTests();
  late GeneratedUiHarness h;
  setUp(() async {
    h = GeneratedUiHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  testWidgets(
      'Inbox and typed preview read external history without a current Profile',
      (tester) async {
    final proposal = await tester.runAsync(() =>
        insertExternalHistory(h.storage, owner: h.fixtureSession.localOwner));
    await tester.runAsync(() async {
      await tester.pumpWidget(h.dependencies(
          child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: GeneratedProposalInboxScreen(
                  dependencies: h.dependencies()))));
    });
    await settleGenerated(tester);
    expect(find.byKey(ValueKey('generated-proposal-${proposal!.proposalId}')),
        findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(
          find.byKey(ValueKey('generated-proposal-${proposal.proposalId}')));
      await tester.pump();
    });
    await settleGenerated(tester);
    expect(find.byType(GeneratedProposalReviewScreen), findsOneWidget);
    final renderer = tester
        .widgetList<RichContentRenderer>(find.byType(RichContentRenderer))
        .first;
    expect((renderer.content.nodes.first as TextNode).text,
        'External synthetic history');
    expect(tester.takeException(), isNull);
    expect(await tester.runAsync(() => h.storage.count('questions')), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test(
      'existing typed edit/Flush CAS retains original external facts and local-only approval',
      () async {
    final p = await insertExternalHistory(h.storage,
        owner: h.fixtureSession.localOwner);
    final c = GeneratedProposalReviewController(
        proposalId: p.proposalId,
        factory: h.authority,
        service: h.storage.service);
    await c.load();
    expect(c.editable, isTrue);
    c.edit({
      'field': 'stem',
      'itemId': p.items.single.itemId,
      'value': [
        {'type': 'text', 'text': 'Edited history preview'}
      ]
    });
    c.decide(p.items.single.itemId, GeneratedDecision.accepted);
    expect(await c.save(c.target!), isTrue);
    expect(c.loadedReviewRevision, 1);
    expect(c.proposal!.externalOrigin!.toPersistedPayload(),
        p.externalOrigin!.toPersistedPayload());
    expect(c.proposal!.items.single.original, p.items.single.original);
    expect((c.workingItems.single.working.stem.nodes.single as TextNode).text,
        'Edited history preview');
    expect(await h.storage.count('questions'), 0);
    final preview = await c.prepareTerminal();
    expect(preview, isNotNull);
    expect(await h.storage.count('questions'), 0);
    await c.confirmTerminal(preview!);
    expect(await h.storage.count('questions'), 1);
    expect(c.receipt!.itemMappings, hasLength(1));
    final current = await h.fixtureSession.read(p.proposalId);
    expect(current.commitReceipt!.toJson(), c.receipt!.toJson());
    expect(current.externalOrigin!.toPersistedPayload(),
        p.externalOrigin!.toPersistedPayload());
    c.dispose();
  });
}
