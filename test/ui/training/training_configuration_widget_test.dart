import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:shiroha_quiz/application/training/training_configuration_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/training/training_bank_selector.dart';
import 'package:shiroha_quiz/ui/training/training_configuration_page.dart';
import 'package:shiroha_quiz/ui/training/training_hero.dart';
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
  _registerV2Tests();
  _registerCategoryPagingTests();
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
        await tester.tap(find.byTooltip('下一页'));
        await tester.pumpAndSettle();
        expect(find.text('空分类'), findsOneWidget);
        expect(find.text('高数 + 线代'), findsNothing);
        expect(find.text('新建训练内容'), findsWidgets);
        await tester.tap(find.byTooltip('上一页'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('高数 + 线代'));
        await tester.pumpAndSettle();
        expect(find.text('编辑训练内容'), findsOneWidget);
        await reveal(tester, find.text('修改分类视觉，将应用于该分类全部训练内容。'));
        expect(find.text('修改分类视觉，将应用于该分类全部训练内容。'), findsOneWidget);
        await tester.drag(find.byType(ListView).last, const Offset(0, 1800));
        await tester.pumpAndSettle();
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
    await reveal(tester, find.widgetWithText(ChoiceChip, '英语'));
    await tester.tap(find.widgetWithText(ChoiceChip, '英语'));
    await tester.drag(find.byType(ListView).last, const Offset(0, 2200));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('question-limit')));
    final limit =
        tester.widget<Slider>(find.byKey(const ValueKey('question-limit')));
    expect(limit.min, 1);
    expect(limit.max, 100);
    expect(limit.divisions, 99);
    limit.onChanged!(99);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('增加题量'));
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
    await reveal(tester, find.text('新建训练内容').first);
    await tester.tap(find.text('新建训练内容').first);
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
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('训练内容已保存'), findsNothing);
  });

  testWidgets(
      'save success expires after two seconds without clearing a later failure',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    TrainingContentDraft edit(String name) => TrainingContentDraft(
        categoryKey: mathCategory,
        preference: fake.value.categories.first.preference,
        content: fixtureContent())
      ..name = name;
    await controller.save(edit('成功保存'));
    await tester.pump();
    expect(find.text('训练内容已保存'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.text('训练内容已保存'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('训练内容已保存'), findsNothing);
    await controller.save(edit('第二次成功'));
    await tester.pump();
    fake.contentFailure = HomeTrainingFailure.stale;
    await controller.save(edit('后续失败'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('配置已变化'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing a pending success notice cancels its expiry callback',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    await controller.save(TrainingContentDraft(
        categoryKey: mathCategory,
        preference: fake.value.categories.first.preference,
        content: fixtureContent())
      ..name = '准备离开');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
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
      await tester.enterText(find.byType(TextField), '修改后的名称');
      await tester.pumpAndSettle();
      await reveal(tester, find.widgetWithText(ChoiceChip, '数学'));
      await tester.tap(find.widgetWithText(ChoiceChip, '数学'));
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.textContaining(partial ? '训练内容已保存，分类视觉未保存' : '配置已变化'),
          findsOneWidget);
      expect(fake.calls.length, partial ? 2 : 1);
      await tester.pump(const Duration(seconds: 3));
      expect(find.textContaining(partial ? '训练内容已保存，分类视觉未保存' : '配置已变化'),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }
  });

  testWidgets('visual-only edit saves the preference and closes the editor',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高数 + 线代'));
    await tester.pumpAndSettle();
    await reveal(tester, find.widgetWithText(ChoiceChip, '数学'));
    await tester.tap(find.widgetWithText(ChoiceChip, '数学'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('编辑训练内容'), findsNothing);
    expect(find.text('训练内容配置'), findsOneWidget);
    expect(find.text('分类视觉已保存'), findsOneWidget);
    final request = fake.calls.single as UpdateCategoryVisualRequest;
    expect(request.target.expectedRevision, 7);
    expect(request.visualKey, CategoryVisualKey.math);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('分类视觉已保存'), findsNothing);
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
    await tester.enterText(find.byType(TextField), '重新绑定后改名');
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
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('训练内容已保存'), findsNothing);
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

void _registerCategoryPagingTests() {
  testWidgets(
      'one category per page; buttons and swipe browse without commands',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Semantics>(find
                .ancestor(
                    of: find.byKey(const ValueKey('training-category-dot-0')),
                    matching: find.byType(Semantics))
                .first)
            .properties
            .selected,
        isTrue);
    expect(find.textContaining('分类 1 /'), findsNothing);
    expect(find.text('1 / 3'), findsNothing);
    expect(find.byKey(const ValueKey('training-category-pagination')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('training-category-dot-2')), findsOneWidget);
    final card = tester.getRect(find
        .descendant(
            of: find.byType(TrainingHero).first,
            matching: find.byType(ClipRRect))
        .first);
    for (final key in [
      'previous-training-category',
      'next-training-category'
    ]) {
      final arrow = find.byKey(ValueKey(key));
      expect(tester.getCenter(arrow).dy, closeTo(card.center.dy, .01));
      expect(card.contains(tester.getCenter(arrow)), isTrue);
      expect(tester.getSize(arrow).width, greaterThanOrEqualTo(44));
      expect(
          tester
              .widget<Icon>(
                  find.descendant(of: arrow, matching: find.byType(Icon)))
              .size,
          18);
    }

    expect(find.text('高数 + 线代'), findsOneWidget);
    expect(find.text('空分类'), findsNothing);
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('previous-training-category')))
            .onPressed,
        isNull);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Semantics>(find
                .ancestor(
                    of: find.byKey(const ValueKey('training-category-dot-1')),
                    matching: find.byType(Semantics))
                .first)
            .properties
            .selected,
        isTrue);
    expect(find.text('空分类'), findsOneWidget);
    expect(find.text('高数 + 线代'), findsNothing);
    expect(find.text('暂无训练内容，选择题库新建一组训练。'), findsOneWidget);
    await tester.drag(find.byKey(const ValueKey('training-category-pages')),
        const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Semantics>(find
                .ancestor(
                    of: find.byKey(const ValueKey('training-category-dot-2')),
                    matching: find.byType(Semantics))
                .first)
            .properties
            .selected,
        isTrue);
    expect(find.text('英语'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('next-training-category')))
            .onPressed,
        isNull);
    await tester.drag(find.byKey(const ValueKey('training-category-pages')),
        const Offset(600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上一页'));
    await tester.pumpAndSettle();
    expect(find.text('高数 + 线代'), findsOneWidget);
    expect(fake.calls, isEmpty);
    expect(fake.value.categories.first.preference.currentContentId, 'content');
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop mouse drag pages categories without commands',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('training-category-pages')),
        const Offset(-600, 0),
        kind: ui.PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Semantics>(find
                .ancestor(
                    of: find.byKey(const ValueKey('training-category-dot-1')),
                    matching: find.byType(Semantics))
                .first)
            .properties
            .selected,
        isTrue);
    expect(find.text('空分类'), findsOneWidget);
    expect(find.text('高数 + 线代'), findsNothing);
    expect(fake.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'refresh retains category identity across reordering; removal falls back safely',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    final snapshot = fake.value;
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    fake.value = TrainingConfigurationSnapshot(
        catalog: snapshot.catalog,
        categories: [
          snapshot.categories[1],
          snapshot.categories[0],
          snapshot.categories[2]
        ]);
    await tester.tap(find.byTooltip('刷新配置'));
    await tester.pumpAndSettle();
    expect(find.text('空分类'), findsOneWidget);
    expect(
        tester
            .widget<Semantics>(find
                .ancestor(
                    of: find.byKey(const ValueKey('training-category-dot-0')),
                    matching: find.byType(Semantics))
                .first)
            .properties
            .selected,
        isTrue);
    fake.value = TrainingConfigurationSnapshot(
        catalog: snapshot.catalog,
        categories: [snapshot.categories[0], snapshot.categories[2]]);
    await tester.tap(find.byTooltip('刷新配置'));
    await tester.pumpAndSettle();
    expect(find.text('数学'), findsOneWidget);
    expect(
        tester
            .widget<Semantics>(find
                .ancestor(
                    of: find.byKey(const ValueKey('training-category-dot-0')),
                    matching: find.byType(Semantics))
                .first)
            .properties
            .selected,
        isTrue);
    expect(fake.calls, isEmpty);
  });

  testWidgets(
      'category browsing keeps creation scoped and preserves page on editor return',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byTooltip('下一页'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('新建训练内容'));
    await tester.pumpAndSettle();
    expect(find.text('四级'), findsOneWidget);
    expect(find.text('高数'), findsNothing);
    await tester.tap(find.text('四级'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TrainingContentEditor>(find.byType(TrainingContentEditor))
            .draft
            .categoryKey,
        FolderCategoryKey('英语'));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Semantics>(find
                .ancestor(
                    of: find.byKey(const ValueKey('training-category-dot-2')),
                    matching: find.byType(Semantics))
                .first)
            .properties
            .selected,
        isTrue);
    expect(find.text('英语'), findsOneWidget);
    expect(fake.calls, isEmpty);
  });

  testWidgets(
      'single category disables both arrows; empty snapshot has no pager',
      (tester) async {
    final fake = ConfigurationFake();
    fake.value = TrainingConfigurationSnapshot(
        catalog: fake.value.catalog, categories: [fake.value.categories.first]);
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: TrainingConfigurationPage(controller: controller)));
    await tester.pumpAndSettle();
    for (final key in [
      'previous-training-category',
      'next-training-category'
    ]) {
      expect(tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed,
          isNull);
    }
    fake.value = TrainingConfigurationSnapshot(
        catalog: TrainingCatalogSnapshot(categories: const [], banks: const []),
        categories: const []);
    await tester.tap(find.byTooltip('刷新配置'));
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsNothing);
    expect(find.textContaining('暂无分类'), findsOneWidget);
    expect(fake.calls, isEmpty);
  });
}

void _registerV2Tests() {
  final capture = Platform.environment['TRAINING_VISUAL_EVIDENCE'] == '1';
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'TrainingVisualFont': Platform.environment['TRAINING_VISUAL_FONT'],
      'MaterialIcons': Platform.environment['TRAINING_MATERIAL_FONT'],
    }.entries) {
      if (entry.value == null) continue;
      await (FontLoader(entry.key)
            ..addFont(Future.value(
                ByteData.sublistView(await File(entry.value!).readAsBytes()))))
          .load();
    }
  });

  Future<void> pump(WidgetTester tester, Widget home,
      {double width = 390,
      double scale = 1,
      bool dark = false,
      GlobalKey? boundary}) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var theme = dark ? AppTheme.darkTheme : AppTheme.lightTheme;
    if (capture) {
      theme = theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'TrainingVisualFont'));
    }
    await tester.pumpWidget(MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: boundary == null
            ? home
            : RepaintBoundary(key: boundary, child: home)));
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(
      WidgetTester tester, GlobalKey key, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      await precacheImage(
          const AssetImage('assets/images/today/category-math-v3.png'),
          key.currentContext!);
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image = await (key.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/training_ui_v2/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final selected in [false, true]) {
    testWidgets(
        'detail is independent of selection and preserves search/scroll selected=$selected',
        (tester) async {
      final opened = <String>[];
      late BuildContext routeContext;
      var refreshes = 0;
      final snapshot = fixtureSnapshot();
      await pump(tester, Builder(builder: (context) {
        routeContext = context;
        return TrainingBankSelector(
            catalog: snapshot.catalog,
            categoryKey: mathCategory,
            members: selected ? fixtureContent().members : const [],
            refreshCatalog: () async {
              refreshes++;
              return snapshot.catalog;
            },
            onOpenBank: (name) async {
              opened.add(name);
              await Navigator.push<void>(
                  routeContext,
                  MaterialPageRoute(
                      builder: (_) =>
                          Scaffold(appBar: AppBar(title: Text('详情 $name')))));
            });
      }));
      await tester.enterText(find.byType(TextField), '高');
      await tester.pumpAndSettle();
      final checkbox = find.byKey(const ValueKey('bank-select-高数'));
      expect(tester.widget<Checkbox>(checkbox).value, selected);
      expect(tester.getCenter(find.byTooltip('查看题库详情：高数')).dx,
          lessThan(tester.getCenter(checkbox).dx));
      final position = tester
          .state<ScrollableState>(find
              .descendant(
                  of: find.byType(ListView).last,
                  matching: find.byType(Scrollable))
              .first)
          .position
          .pixels;
      await tester.tap(find.byTooltip('查看题库详情：高数'));
      await tester.pumpAndSettle();
      expect(opened, ['高数']);
      expect(find.text('详情 高数'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '高');
      expect(tester.widget<Checkbox>(checkbox).value, selected);
      expect(
          tester
              .state<ScrollableState>(find
                  .descendant(
                      of: find.byType(ListView).last,
                      matching: find.byType(Scrollable))
                  .first)
              .position
              .pixels,
          position);
      expect(refreshes, 2);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(checkbox).value, !selected);
      expect(opened, ['高数']);
    });
  }

  testWidgets(
      'long filtered list restores nonzero scroll and exact bank routes after return',
      (tester) async {
    final catalog = TrainingCatalogSnapshot(categories: [
      mathCategory
    ], banks: [
      for (var i = 0; i < 24; i++)
        TrainingCatalogBank(
            bankName: '数学题库 $i',
            categoryKey: mathCategory,
            ordinaryTrainingEligible: true),
    ]);
    final opened = <String>[];
    late BuildContext routeContext;
    await pump(tester, Builder(builder: (context) {
      routeContext = context;
      return TrainingBankSelector(
          catalog: catalog,
          categoryKey: mathCategory,
          members: const [],
          refreshCatalog: () async => catalog,
          onOpenBank: (name) async {
            opened.add(name);
            await Navigator.push<void>(
                routeContext,
                MaterialPageRoute(
                    builder: (_) =>
                        Scaffold(appBar: AppBar(title: Text(name)))));
          });
    }));
    await tester.enterText(find.byType(TextField), '数学');
    final scroll = find
        .descendant(
            of: find.byType(ListView).last, matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.byTooltip('查看题库详情：数学题库 15'), 300,
        scrollable: scroll);
    await tester.pumpAndSettle();
    final offset = tester.state<ScrollableState>(scroll).position.pixels;
    expect(offset, greaterThan(0));
    await tester.tap(find.byTooltip('查看题库详情：数学题库 15'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(scroll).position.pixels, offset);
    expect(opened, ['数学题库 15']);
    expect(find.text('已选择 0 个题库'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bank-select-数学题库 15')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byTooltip('查看题库详情：数学题库 19'), 300,
        scrollable: scroll);
    await tester.tap(find.byTooltip('查看题库详情：数学题库 19'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(opened, ['数学题库 15', '数学题库 19']);
    expect(find.text('已选择 1 个题库'), findsOneWidget);
  });

  testWidgets(
      'return refresh exposes deleted choice without silently deselecting or saving',
      (tester) async {
    var catalog = fixtureSnapshot().catalog;
    late BuildContext routeContext;
    await pump(tester, Builder(builder: (context) {
      routeContext = context;
      return TrainingBankSelector(
          catalog: catalog,
          categoryKey: mathCategory,
          members: fixtureContent().members,
          refreshCatalog: () async => catalog,
          onOpenBank: (name) async {
            await Navigator.push<void>(
                routeContext,
                MaterialPageRoute(
                    builder: (_) =>
                        Scaffold(appBar: AppBar(title: Text(name)))));
          });
    }));
    await tester.tap(find.byTooltip('查看题库详情：高数'));
    await tester.pumpAndSettle();
    catalog = TrainingCatalogSnapshot(
        categories: fixtureSnapshot().catalog.categories,
        banks:
            fixtureSnapshot().catalog.banks.where((b) => b.bankName != '高数'));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byTooltip('查看题库详情：高数'), findsNothing);
    expect(find.byTooltip('移除 高数'), findsOneWidget);
    expect(find.text('已选择 2 个题库'), findsOneWidget);
  });

  testWidgets(
      'missing and invalidated members have no detail action; fresh deletion blocks navigation',
      (tester) async {
    final opened = <String>[];
    final missing = TrainingContentMember(
        bankName: '已删除库',
        weightPercent: 0,
        position: 2,
        bindingStatus: TrainingBindingStatus.invalidated,
        invalidationReason: TrainingBindingInvalidationReason.bankMissing);
    await pump(
        tester,
        TrainingBankSelector(
            catalog: fixtureSnapshot().catalog,
            categoryKey: mathCategory,
            members: [...fixtureContent(invalid: true).members, missing],
            refreshCatalog: () async => TrainingCatalogSnapshot(
                categories: [mathCategory], banks: const []),
            onOpenBank: (name) async => opened.add(name)));
    expect(find.byTooltip('查看题库详情：高数'), findsNothing);
    expect(find.byTooltip('查看题库详情：已删除库'), findsNothing);
    await tester.tap(find.byTooltip('查看题库详情：线代'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.text('题库已变化或暂不可用，请检查后再选择。'), findsOneWidget);
    expect(find.text('已选择 3 个题库'), findsOneWidget);
  });

  testWidgets(
      'editor detail return preserves unsaved draft and save performs existing stale CAS once',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    late BuildContext routeContext;
    await pump(tester, Builder(builder: (context) {
      routeContext = context;
      return TrainingConfigurationPage(
          controller: controller,
          onOpenBank: (name) async {
            await Navigator.push<void>(
                routeContext,
                MaterialPageRoute(
                    builder: (_) =>
                        Scaffold(appBar: AppBar(title: Text('详情 $name')))));
          });
    }));
    await tester.tap(find.text('高数 + 线代'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '未保存草稿');
    await tester.scrollUntilVisible(find.text('编辑题库'), 250,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('编辑题库'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看题库详情：线代'));
    await tester.pumpAndSettle();
    fake.contentFailure = HomeTrainingFailure.stale;
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 个题库'), findsOneWidget);
    expect(fake.calls, isEmpty);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    final editor = tester
        .widget<TrainingContentEditor>(find.byType(TrainingContentEditor));
    expect(editor.draft.name, '未保存草稿');
    expect(editor.draft.members.map((m) => m.bankName), ['高数', '线代']);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(fake.calls.single, isA<UpdateTrainingContentRequest>());
    expect(find.textContaining('配置已变化'), findsOneWidget);
  });

  testWidgets('menus preserve current selection and simple ordering',
      (tester) async {
    final fake = ConfigurationFake();
    final controller = fake.controller();
    addTearDown(controller.dispose);
    await pump(tester, TrainingConfigurationPage(controller: controller));
    await tester.tap(find.byTooltip('更多操作 第二配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为当前'));
    await tester.pumpAndSettle();
    expect(fake.calls.single, isA<SelectTrainingContentRequest>());
    await tester.tap(find.byTooltip('调整顺序 第二配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上移'));
    await tester.pumpAndSettle();
    expect(fake.calls.last, isA<MoveTrainingContentRequest>());
  });

  for (final width in [320.0, 390.0, 1024.0]) {
    for (final dark in [false, true]) {
      testWidgets(
          'three screens remain usable at width=$width scale=1.5 dark=$dark',
          (tester) async {
        final fake = ConfigurationFake()
          ..value = fixtureSnapshot(visual: CategoryVisualKey.math);
        final controller = fake.controller();
        addTearDown(controller.dispose);
        final key = GlobalKey();
        await pump(tester, TrainingConfigurationPage(controller: controller),
            width: width, scale: 1.5, dark: dark, boundary: key);
        expect(tester.takeException(), isNull);
        await screenshot(tester, key, 'list-$width-$dark-large');
        await pump(
            tester,
            TrainingBankSelector(
                catalog: fake.value.catalog,
                categoryKey: mathCategory,
                members: fixtureContent().members,
                onOpenBank: (_) async {}),
            width: width,
            scale: 1.5,
            dark: dark,
            boundary: key);
        final semantics = tester.ensureSemantics();
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('查看题库详情：高数'), findsOneWidget);
        expect(find.bySemanticsLabel('选择题库：高数'), findsOneWidget);
        expect(tester.getSize(find.byTooltip('查看题库详情：高数')).width,
            greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
        await screenshot(tester, key, 'selector-$width-$dark-large');
        semantics.dispose();
        await pump(
            tester,
            TrainingContentEditor(
                controller: controller,
                catalog: fake.value.catalog,
                draft: TrainingContentDraft(
                    categoryKey: mathCategory,
                    preference: fake.value.categories.first.preference,
                    content: fixtureContent())),
            width: width,
            scale: 1.5,
            dark: dark,
            boundary: key);
        await screenshot(tester, key, 'editor-$width-$dark-large');
        await tester.scrollUntilVisible(find.byType(TrainingRatioOverview), 220,
            scrollable: find
                .descendant(
                    of: find.byType(ListView).last,
                    matching: find.byType(Scrollable))
                .first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('reference scale three-screen visual evidence', (tester) async {
    final fake = ConfigurationFake()
      ..value = fixtureSnapshot(visual: CategoryVisualKey.math);
    final controller = fake.controller();
    addTearDown(controller.dispose);
    final key = GlobalKey();
    await pump(tester, TrainingConfigurationPage(controller: controller),
        boundary: key);
    await screenshot(tester, key, 'list-390');
    await pump(
        tester,
        TrainingBankSelector(
            catalog: fake.value.catalog,
            categoryKey: mathCategory,
            members: fixtureContent().members,
            onOpenBank: (_) async {}),
        boundary: key);
    await screenshot(tester, key, 'selector-390');
    await pump(
        tester,
        TrainingContentEditor(
            controller: controller,
            catalog: fake.value.catalog,
            draft: TrainingContentDraft(
                categoryKey: mathCategory,
                preference: fake.value.categories.first.preference,
                content: fixtureContent())),
        boundary: key);
    await screenshot(tester, key, 'editor-390');
    expect(tester.takeException(), isNull);
  });
}
