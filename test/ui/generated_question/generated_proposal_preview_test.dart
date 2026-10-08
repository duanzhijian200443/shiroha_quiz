import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_controllers.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_inbox_screen.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_review_screen.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
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
      'empty Inbox has a real empty state and disabled module hides entry',
      (tester) async {
    await tester.pumpWidget(h.dependencies(
        enabled: false,
        child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: Scaffold(
                appBar: AppBar(
                    actions: const [GeneratedProposalWorkspaceAction()])))));
    expect(
        find.byKey(const ValueKey('generated_proposal_review')), findsNothing);
    final controller = GeneratedProposalInboxController(h.authority);
    await tester.runAsync(controller.load);
    expect(controller.proposals, isEmpty);
    expect(controller.lastError, isNull);
    controller.dispose();
    final deps = h.dependencies();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme,
          home: GeneratedProposalInboxScreen(dependencies: deps)));
      final state =
          tester.state(find.byType(GeneratedProposalInboxScreen)) as dynamic;
      final loading = state.controller as GeneratedProposalInboxController;
      if (loading.isLoading) {
        final complete = Completer<void>();
        void done() {
          if (!loading.isLoading) {
            loading.removeListener(done);
            complete.complete();
          }
        }

        loading.addListener(done);
        await complete.future;
      }
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('generated-empty')), findsOneWidget);
    expect(await h.storage.count('generated_question_proposals'), 0);
  });
  for (final size in [const Size(360, 720), const Size(1024, 768)]) {
    testWidgets(
        'enabled action opens persisted batches and typed preview at $size',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final data = candidate(stem: r'Literal $x$');
      data['stem'] = [
        {'type': 'text', 'text': r'Literal $x$'},
        {'type': 'inline_math', 'latex': 'x+1'},
        {'type': 'block_math', 'latex': 'y=2'}
      ];
      final proposal =
          await tester.runAsync(() => h.stage(items: [data], requested: 2));
      final second = await tester.runAsync(() =>
          h.stage(key: 'second', items: [candidate(stem: 'Second batch')]));
      await tester.runAsync(h.storage.reopen);
      await tester.pumpWidget(h.dependencies(
          child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: Scaffold(
                  appBar: AppBar(
                      actions: const [GeneratedProposalWorkspaceAction()])))));
      await tester.runAsync(() async {
        await tester
            .tap(find.byKey(const ValueKey('generated_proposal_review')));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('generated-proposal-${proposal!.proposalId}')),
          findsOneWidget);
      expect(find.byKey(ValueKey('generated-proposal-${second!.proposalId}')),
          findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(
            find.byKey(ValueKey('generated-proposal-${proposal.proposalId}')));
      });
      await tester.pumpAndSettle();
      expect(find.byType(GeneratedProposalReviewScreen), findsOneWidget);
      expect(find.text('实际题目数量与请求数量不同'), findsOneWidget);
      final stem = tester
          .widgetList<RichContentRenderer>(find.byType(RichContentRenderer))
          .first
          .content;
      expect(stem.nodes[0], isA<TextNode>());
      expect(stem.nodes[1], isA<InlineMathNode>());
      expect(stem.nodes[2], isA<BlockMathNode>());
      expect(find.text('来源：uncited（未引用来源）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
