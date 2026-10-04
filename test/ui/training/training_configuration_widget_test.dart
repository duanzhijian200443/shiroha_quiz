import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/training/training_bank_selector.dart';
import 'package:shiroha_quiz/ui/training/training_configuration_page.dart';
import 'package:shiroha_quiz/ui/training/training_content_draft.dart';
import 'package:shiroha_quiz/ui/training/training_content_editor.dart';
import 'package:shiroha_quiz/ui/training/training_visuals.dart';
import 'training_configuration_fakes.dart';

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 220,
      scrollable: find
          .descendant(
              of: find.byType(ListView).last, matching: find.byType(Scrollable))
          .first,
      maxScrolls: 35);
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [320.0, 1100.0]) {
    for (final dark in [false, true]) {
      testWidgets('list and editor fixture width $width dark $dark',
          (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fake = ConfigurationFake()
          ..value =
              fixtureSnapshot(invalid: true, visual: CategoryVisualKey.math);
        final controller = fake.controller();
        addTearDown(controller.dispose);
        await tester.pumpWidget(MaterialApp(
            theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
            home: TrainingConfigurationPage(controller: controller)));
        await tester.pumpAndSettle();
        expect(find.textContaining('当前配置 · 配置需修复'), findsOneWidget);
        expect(find.text('高数 + 线代'), findsOneWidget);
        final badges = tester
            .widgetList<CategoryVisualBadge>(find.byType(CategoryVisualBadge));
        expect(
            badges.take(3).every((b) => b.visualKey == CategoryVisualKey.math),
            isTrue);
        await reveal(tester, find.text('空分类'));
        expect(find.text('空分类'), findsOneWidget);
        expect(find.text('添加训练内容'), findsWidgets);
        await tester.drag(find.byType(ListView), const Offset(0, 1700));
        await tester.pumpAndSettle();
        await tester.tap(find.text('高数 + 线代'));
        await tester.pumpAndSettle();
        expect(find.text('编辑训练内容'), findsOneWidget);
        expect(find.text('修改分类视觉，将应用于该分类全部训练内容。'), findsOneWidget);
        await reveal(tester, find.byType(TrainingRatioOverview));
        expect(find.text('预计理想题数：12 题'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await reveal(tester, find.textContaining('绑定失效'));
        expect(find.text('重新绑定'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(fake.calls, isEmpty);
      });
    }
  }

  testWidgets(
      'four presets and null fallback have semantic labels and preserve identity',
      (tester) async {
    final semantics = tester.ensureSemantics();
    for (final key in [null, ...CategoryVisualKey.values]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CategoryVisualBadge(visualKey: key, label: '原始分类'))));
      expect(find.byIcon(trainingVisualIcon(key)), findsOneWidget);
      expect(
          find.bySemanticsLabel(
              '原始分类分类视觉：${trainingVisualLabel(key ?? CategoryVisualKey.genericLearning)}'),
          findsOneWidget);
      expect(trainingCategoryLabel(mathCategory), '数学');
    }
    semantics.dispose();
  });

  testWidgets(
      'selector filters authority, restores selection, retains invalid context',
      (tester) async {
    final snapshot = fixtureSnapshot();
    final missing = TrainingContentMember(
        bankName: '已删除库',
        weightPercent: 0,
        position: 2,
        bindingStatus: TrainingBindingStatus.invalidated,
        invalidationReason: TrainingBindingInvalidationReason.bankMissing);
    await tester.pumpWidget(MaterialApp(
        home: TrainingBankSelector(
            catalog: snapshot.catalog,
            categoryKey: mathCategory,
            members: [...fixtureContent(invalid: true).members, missing])));
    await tester.pumpAndSettle();
    expect(find.text('四级'), findsNothing);
    expect(find.text('保留库'), findsNothing);
    expect(find.text('已选择 3 个题库'), findsOneWidget);
    expect(find.text('原绑定已失效；重新勾选不会恢复绑定'), findsOneWidget);
    await tester.tap(find.text('概率'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 4 个题库'), findsOneWidget);
    await tester.tap(find.text('线代'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 3 个题库'), findsOneWidget);
    await reveal(tester, find.text('已删除库'));
    expect(find.textContaining('原题库已不存在'), findsOneWidget);
  });

  testWidgets('cancel edited name, limit, weights, visual produces no command',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高数 + 线代'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '未保存名称');
    await tester.tap(find.widgetWithText(ChoiceChip, '英语'));
    await reveal(tester, find.byKey(const ValueKey('question-limit')));
    final limit =
        tester.widget<Slider>(find.byKey(const ValueKey('question-limit')));
    expect(limit.min, 1);
    expect(limit.max, 100);
    expect(limit.divisions, 99);
    limit.onChanged!(99);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('增加题量'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '增加题量'))
            .onPressed,
        isNull);
    tester
        .widget<Slider>(find.byKey(const ValueKey('question-limit')))
        .onChanged!(1);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '减少题量'))
            .onPressed,
        isNull);
    await reveal(tester, find.byKey(const ValueKey('weight-高数')));
    tester
        .widget<Slider>(find.byKey(const ValueKey('weight-高数')))
        .onChanged!(0);
    await tester.pumpAndSettle();
    expect(find.text('高数 · 0%'), findsOneWidget);
    await reveal(tester, find.text('取消编辑'));
    await tester.tap(find.text('取消编辑'));
    await tester.pumpAndSettle();
    expect(find.text('训练内容配置'), findsOneWidget);
    expect(fake.calls, isEmpty);
  });

  testWidgets(
      'create single bank through shared selector/editor; explicit Save only',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('添加训练内容').first);
    await tester.tap(find.text('添加训练内容').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('概率'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('新建训练内容'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '概率训练');
    await tester.pumpAndSettle();
    expect(fake.calls, isEmpty);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    final request = fake.calls.single as CreateTrainingContentRequest;
    expect(request.edit.members.single.bankName, '概率');
    expect(request.edit.members.single.weightPercent, 100);
    expect(request.categoryKey, mathCategory);
    expect(find.text('训练内容已保存'), findsOneWidget);
  });

  testWidgets('delete confirmation cancel is inert; confirm sends exact target',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高数 + 线代'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('删除训练内容'));
    await tester.tap(find.text('删除训练内容'));
    await tester.pumpAndSettle();
    expect(find.textContaining('仅删除训练配置，不删除题库与学习记录'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(fake.calls, isEmpty);
    await tester.tap(find.text('删除训练内容'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect((fake.calls.single as TrainingContentTarget).contentId, 'content');
    expect((fake.calls.single as TrainingContentTarget).expectedRevision, 4);
  });

  testWidgets(
      'partial save is visible after editor closes; stale does not retry',
      (tester) async {
    for (final partial in [true, false]) {
      final fake = ConfigurationFake();
      if (partial) {
        fake.visualFailure = HomeTrainingFailure.stale;
      } else {
        fake.contentFailure = HomeTrainingFailure.stale;
      }
      final controller = fake.controller();
      await tester.pumpWidget(MaterialApp(
          key: UniqueKey(),
          home: TrainingConfigurationPage(controller: controller)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高数 + 线代'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '数学'));
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.textContaining(partial ? '训练内容已保存，分类视觉未保存' : '配置已变化'),
          findsOneWidget);
      expect(fake.calls.length, partial ? 2 : 1);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }
  });

  testWidgets(
      'rebind requires explicit confirmation and future Save uses new revision',
      (tester) async {
    final fake = ConfigurationFake()..value = fixtureSnapshot(invalid: true);
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高数 + 线代'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('重新绑定'));
    await tester.tap(find.text('重新绑定'));
    await tester.pumpAndSettle();
    expect(find.textContaining('取消不会撤销本次重新绑定'), findsOneWidget);
    expect(fake.calls, isEmpty);
    await tester.tap(find.text('确认重新绑定'));
    await tester.pumpAndSettle();
    expect(
        (fake.calls.single as RebindTrainingContentMemberRequest)
            .target
            .expectedRevision,
        4);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(
        (fake.calls.last as UpdateTrainingContentRequest)
            .target
            .expectedRevision,
        5);
  });

  testWidgets('read failure never becomes real empty state', (tester) async {
    final fake = ConfigurationFake()..readFails = true;
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法读取训练配置'), findsOneWidget);
    expect(find.textContaining('暂无分类'), findsNothing);
  });

  testWidgets('large text narrow editor remains usable', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.5),
                disableAnimations: true),
            child: child!),
        home: TrainingContentEditor(
            controller: controller,
            catalog: fake.value.catalog,
            draft: TrainingContentDraft(
                categoryKey: mathCategory,
                preference: fake.value.categories.first.preference,
                content: fixtureContent()))));
    await tester.pumpAndSettle();
    await reveal(tester, find.byType(TrainingRatioOverview));
    expect(tester.takeException(), isNull);
    await reveal(tester, find.text('取消编辑'));
    expect(tester.takeException(), isNull);
  });
}
