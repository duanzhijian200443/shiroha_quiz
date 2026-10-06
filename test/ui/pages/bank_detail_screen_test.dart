import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answer_completion/answer_completion_query.dart';
import 'package:shiroha_quiz/application/practice/practice_session_mutation_command.dart';
import 'package:shiroha_quiz/application/practice/record_answer_attempt_command.dart';
import 'package:shiroha_quiz/application/questions/question_list_query_port.dart';
import 'package:shiroha_quiz/application/questions/question_mutation_command.dart';
import 'package:shiroha_quiz/application/questions/question_presentation_read.dart';
import 'package:shiroha_quiz/application/questions/question_write_mutation_command.dart';
import 'package:shiroha_quiz/application/safe_write/typed_answer_command.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';
import 'package:shiroha_quiz/ui/dependencies/answer_completion_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/dependencies/practice_command_dependencies.dart';
import 'package:shiroha_quiz/ui/pages/answer_completion_screen.dart';
import 'package:shiroha_quiz/ui/pages/bank_detail_screen.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';
import 'package:shiroha_quiz/ui/pages/question_list_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

class _Ports extends Fake
    implements
        QuestionListQueryPort,
        QuestionMutationPersistencePort,
        TypedAnswerPersistencePort,
        QuestionWriteMutationPersistencePort,
        PracticeSessionMutationPersistencePort,
        AnswerAttemptPersistencePort {
  final reads = <String>[];
  @override
  Future<List<QuestionPresentationRead>> listQuestionsForBank(
      String bankName) async {
    reads.add(bankName);
    return [];
  }
}

class _Answers extends Fake implements AnswerCompletionQuery {
  final reads = <String>[];
  @override
  Future<AnswerCompletionRead> readBank(String bankName) async {
    reads.add(bankName);
    return AnswerCompletionSnapshot(sets: [], ungrouped: []);
  }
}

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);
}

PracticeCommandDependencies _commands(_Ports ports) =>
    PracticeCommandDependencies(
        questionMutation: QuestionMutationCommand(ports),
        practiceSessionMutation: PracticeSessionMutationCommand(ports),
        questionWriteMutation: QuestionWriteMutationCommand(ports),
        recordAttempt: RecordAnswerAttemptCommand(ports));

void main() {
  final capture = Platform.environment['BANK_DETAIL_VISUAL_EVIDENCE'] == '1';
  final boundary = GlobalKey();
  setUpAll(() async {
    if (capture && Platform.isWindows) {
      await (FontLoader('BankDetailEvidence')
            ..addFont(Future.value(ByteData.sublistView(
                await File('C:/Windows/Fonts/msyh.ttc').readAsBytes()))))
          .load();
      final icons = Platform.environment['BANK_DETAIL_MATERIAL_FONT'];
      if (icons != null) {
        await (FontLoader('MaterialIcons')
              ..addFont(Future.value(
                  ByteData.sublistView(await File(icons).readAsBytes()))))
            .load();
      }
    }
  });

  Future<void> pump(WidgetTester tester,
      {String bankName = '离线示例题库',
      Size size = const Size(390, 844),
      bool dark = false,
      double scale = 1,
      bool withAnswers = false,
      _Ports? ports,
      _Answers? answers,
      _Routes? routes,
      PracticeCommandDependencies? commands}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = dark ? AppTheme.darkTheme : AppTheme.lightTheme;
    Widget app = MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorObservers: [if (routes != null) routes],
        theme: capture
            ? theme.copyWith(
                textTheme:
                    theme.textTheme.apply(fontFamily: 'BankDetailEvidence'))
            : theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: BankDetailScreen(
            bankName: bankName,
            questionListQuery: ports,
            questionMutationPersistence: ports,
            typedAnswerPersistence: ports,
            practiceCommands: commands));
    if (withAnswers) {
      app = AnswerCompletionDependenciesScope(
          query: answers ?? _Answers(), child: app);
    }
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: app));
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (!capture) return;
    debugDisableShadows = false;
    try {
      void repaint(RenderObject render) {
        render.markNeedsPaint();
        render.visitChildren(repaint);
      }

      repaint(boundary.currentContext!.findRenderObject()!);
      await tester.pump();
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await Directory('.dart_tool/bank-detail-v2-visual')
            .create(recursive: true);
        await File('.dart_tool/bank-detail-v2-visual/$name.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    } finally {
      debugDisableShadows = true;
    }
  }

  testWidgets(
      'dynamic name, three groups and conditional management entries retire the local timer',
      (tester) async {
    await pump(tester, bankName: '可变题库甲');
    expect(find.text('可变题库甲'), findsOneWidget);
    for (final title in [
      '开始练习',
      '专项练习',
      '题库管理',
      '全类型自适应复习',
      '选择题专项',
      '填空题专项',
      '简答题专项',
      '浏览题库内容'
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('补充答案'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.textContaining('番茄'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    await pump(tester, bankName: '可变题库乙', withAnswers: true);
    expect(find.text('可变题库乙'), findsOneWidget);
    expect(find.text('补充答案'), findsOneWidget);
  });

  for (final entry
      in {'all': null, 'choice': 0, 'fill': 2, 'short': 3}.entries) {
    testWidgets(
        '${entry.key} retains bank/filter/commands/ordinary context and defaults timer off',
        (tester) async {
      final ports = _Ports();
      final commands = _commands(ports);
      final routes = _Routes();
      await pump(tester, ports: ports, commands: commands, routes: routes);
      final target = find.byKey(ValueKey('bank-practice-${entry.key}'));
      await tester.ensureVisible(target);
      await tester.tap(target);
      // Inspect the actual pushed route factory before mounting Practice. This
      // verifies the bank-scoped handoff without starting its repository read.
      final route = routes.pushed.last as MaterialPageRoute<dynamic>;
      final practice =
          route.builder(tester.element(find.byType(BankDetailScreen)))
              as PracticePage;
      expect(practice.bankName, '离线示例题库');
      expect(practice.filterType, entry.value);
      expect(practice.practiceCommands, same(commands));
      expect(
          practice.studyActivity!.scene, StudyActivityScene.ordinaryPractice);
      expect(practice.studyActivity!.context.bankName, '离线示例题库');
      expect(practice.studyActivity!.context.categoryKey, isNull);
      expect(practice.studyActivity!.context.contentId, isNull);
      expect(practice.isPomodoroActive, isFalse);
      expect(practice.usePreparedStudySession, isFalse);
      expect(practice.initialQuestions, isNull);
      expect(ports.reads, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'browse retains all original injected ports and reads the real bank argument',
      (tester) async {
    final ports = _Ports();
    await pump(tester, ports: ports);
    final target = find.byKey(const ValueKey('bank-browse'));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
    final list =
        tester.widget<QuestionListScreen>(find.byType(QuestionListScreen));
    expect(list.bankName, '离线示例题库');
    expect(list.questionListQuery, same(ports));
    expect(list.questionMutationPersistence, same(ports));
    expect(list.typedAnswerPersistence, same(ports));
    expect(ports.reads, ['离线示例题库']);
  });

  testWidgets('answer completion still inherits the existing query scope',
      (tester) async {
    final answers = _Answers();
    await pump(tester, withAnswers: true, answers: answers);
    final target = find.byKey(const ValueKey('bank-answer-completion'));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<AnswerCompletionScreen>(find.byType(AnswerCompletionScreen))
            .bankName,
        '离线示例题库');
    expect(answers.reads, ['离线示例题库']);
    expect(find.text('从文件补充答案'), findsNothing);
  });

  testWidgets('practice card supports button semantics and keyboard activation',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final routes = _Routes();
      await pump(tester, routes: routes);
      final card = find.byKey(const ValueKey('bank-practice-all'));
      expect(tester.getSemantics(card).flagsCollection.isButton, isTrue);
      // Return, More, then the first practice card in traversal order.
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      final route = routes.pushed.last as MaterialPageRoute<dynamic>;
      expect(route.builder(tester.element(find.byType(BankDetailScreen))),
          isA<PracticePage>());
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });

  for (final size in [
    const Size(360, 720),
    const Size(390, 844),
    const Size(520, 720),
    const Size(1024, 768)
  ]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets(
            'bank detail $size dark=$dark scale=$scale scrolls with full tap areas',
            (tester) async {
          await pump(tester,
              size: size,
              dark: dark,
              scale: scale,
              withAnswers: true,
              bankName: '离线题库示例');
          expect(tester.takeException(), isNull);
          final name =
              '${size.width.toInt()}-${dark ? 'dark' : 'light'}-$scale';
          await shot(tester, '$name-top');
          for (final key in [
            'bank-practice-all',
            'bank-practice-choice',
            'bank-practice-fill',
            'bank-practice-short',
            'bank-browse',
            'bank-answer-completion'
          ]) {
            final target = find.byKey(ValueKey(key));
            await tester.ensureVisible(target);
            expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
            expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
          }
          expect(tester.takeException(), isNull);
          await shot(tester, '$name-management');
        });
      }
    }
  }

  testWidgets('long Chinese bank name wraps safely without covering the menu',
      (tester) async {
    await pump(tester,
        size: const Size(360, 720),
        scale: 2,
        bankName: '数据结构与算法设计课程期末复习资料长题库名称');
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('bank-detail-menu')));
    await tester.pumpAndSettle();
    expect(find.text('删除题库'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
