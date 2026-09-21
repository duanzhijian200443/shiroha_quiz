import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import/import_advanced_preferences.dart';
import 'package:shiroha_quiz/ui/pages/import_advanced_settings_screen.dart';

void main() {
  const sliderKey = ValueKey('advanced-ocr-concurrency-slider');
  const retryKey = ValueKey('advanced-auto-retry-switch');
  const repairKey = ValueKey('advanced-latex-repair-switch');
  const timeoutKey = ValueKey('advanced-ocr-timeout-selector');
  const completionKey = ValueKey('advanced-completion-selector');
  const resetKey = ValueKey('advanced-settings-reset-defaults');
  const doneKey = ValueKey('advanced-settings-done');

  Future<void> pumpScreen(
    WidgetTester tester, {
    required ImportAdvancedPreferencesLoader loader,
    required ImportAdvancedPreferencesSaver saver,
    Size size = const Size(900, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: ImportAdvancedSettingsScreen(
        preferencesLoader: loader,
        preferencesSaver: saver,
      ),
    ));
    await tester.pump();
  }

  testWidgets('shows only three functional cards', (tester) async {
    await pumpScreen(tester,
        loader: () async => ImportAdvancedPreferences.defaults,
        saver: (_) async {});
    for (final title in const [
      'OCR 并行任务数',
      '异常处理',
      '自动重试',
      'OCR 请求超时',
      '校对与修复',
      'LaTeX 异常自动尝试修补',
      '导入完成后',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    for (final removed in const [
      '保留未识别内容',
      '流程说明',
      '文档处理说明',
      '文本直读',
      'OCR 扫描',
      '规划中',
      '即将推出',
    ]) {
      expect(find.text(removed), findsNothing);
    }
    expect(find.text('设置 App 全局的 OCR 请求并行数。'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byKey(sliderKey));
    expect((slider.min, slider.max, slider.divisions, slider.value),
        (1.0, 10.0, 9, 2.0));
    expect(tester.widget<Switch>(find.byKey(retryKey)).value, isTrue);
    expect(tester.widget<Switch>(find.byKey(repairKey)).value, isFalse);
    expect(tester.widget<SegmentedButton<int>>(find.byKey(timeoutKey)).selected,
        {90});
    expect(
        tester
            .widget<SegmentedButton<ImportCompletionBehavior>>(
                find.byKey(completionKey))
            .selected,
        {ImportCompletionBehavior.notifyOnly});
  });

  testWidgets('pending load disables every control and cannot save defaults',
      (tester) async {
    final delayed = Completer<ImportAdvancedPreferences>();
    final saves = <ImportAdvancedPreferences>[];
    await pumpScreen(tester,
        loader: () => delayed.future, saver: (value) async => saves.add(value));
    expect(tester.widget<Slider>(find.byKey(sliderKey)).onChanged, isNull);
    expect(tester.widget<Switch>(find.byKey(retryKey)).onChanged, isNull);
    expect(tester.widget<Switch>(find.byKey(repairKey)).onChanged, isNull);
    expect(
        tester
            .widget<SegmentedButton<int>>(find.byKey(timeoutKey))
            .onSelectionChanged,
        isNull);
    expect(
        tester
            .widget<SegmentedButton<ImportCompletionBehavior>>(
                find.byKey(completionKey))
            .onSelectionChanged,
        isNull);
    expect(tester.widget<TextButton>(find.byKey(resetKey)).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.byKey(doneKey)).onPressed, isNull);
    expect(saves, isEmpty);

    delayed.complete(const ImportAdvancedPreferences(
      ocrTaskConcurrency: 7,
      autoRetryEnabled: false,
      ocrRequestTimeoutSeconds: 120,
      autoRepairLatexEnabled: true,
      completionBehavior: ImportCompletionBehavior.openReview,
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byKey(sliderKey)).value, 7);
    expect(tester.widget<Switch>(find.byKey(retryKey)).value, isFalse);
    expect(tester.widget<Switch>(find.byKey(repairKey)).value, isTrue);
    expect(tester.widget<SegmentedButton<int>>(find.byKey(timeoutKey)).selected,
        {120});
    expect(saves, isEmpty);
  });

  testWidgets('edits stay local, reset stays local, Done persists all fields',
      (tester) async {
    var stored = const ImportAdvancedPreferences(
      ocrTaskConcurrency: 7,
      retainUnresolvedFragments: false,
    );
    var saves = 0;
    await pumpScreen(tester,
        loader: () async => stored,
        saver: (value) async {
          saves++;
          stored = value;
        });
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byKey(sliderKey)).onChanged!(5);
    tester.widget<Switch>(find.byKey(retryKey)).onChanged!(false);
    tester.widget<Switch>(find.byKey(repairKey)).onChanged!(true);
    tester
        .widget<SegmentedButton<int>>(find.byKey(timeoutKey))
        .onSelectionChanged!({180});
    tester
        .widget<SegmentedButton<ImportCompletionBehavior>>(
            find.byKey(completionKey))
        .onSelectionChanged!({ImportCompletionBehavior.openReview});
    await tester.pump();
    expect(saves, 0);
    expect(tester.widget<Slider>(find.byKey(sliderKey)).value, 5);

    await tester.ensureVisible(find.byKey(resetKey));
    await tester.tap(find.byKey(resetKey));
    await tester.pump();
    expect(saves, 0);
    expect(tester.widget<Slider>(find.byKey(sliderKey)).value, 2);
    expect(tester.widget<Switch>(find.byKey(retryKey)).value, isTrue);
    expect(tester.widget<Switch>(find.byKey(repairKey)).value, isFalse);
    expect(tester.widget<SegmentedButton<int>>(find.byKey(timeoutKey)).selected,
        {90});

    await tester.ensureVisible(find.byKey(doneKey));
    await tester.tap(find.byKey(doneKey));
    await tester.pump();
    expect(saves, 1);
    expect(stored.ocrTaskConcurrency, 2);
    expect(stored.autoRetryEnabled, isTrue);
    expect(stored.ocrRequestTimeoutSeconds, 90);
    expect(stored.autoRepairLatexEnabled, isFalse);
    expect(stored.completionBehavior, ImportCompletionBehavior.notifyOnly);
    expect(stored.retainUnresolvedFragments, isFalse);
  });

  testWidgets('load failure never enables saving', (tester) async {
    var saves = 0;
    await pumpScreen(tester,
        loader: () async => throw StateError('load failed'),
        saver: (_) async => saves++);
    await tester.pumpAndSettle();
    expect(find.text('设置加载失败，请返回后重试。'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(doneKey)).onPressed, isNull);
    expect(saves, 0);
  });

  testWidgets('saving locks controls and prevents duplicate submission',
      (tester) async {
    final pendingSave = Completer<void>();
    var saves = 0;
    await pumpScreen(tester,
        loader: () async => ImportAdvancedPreferences.defaults,
        saver: (_) {
          saves++;
          return pendingSave.future;
        });
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(doneKey));
    await tester.tap(find.byKey(doneKey));
    await tester.pump();
    expect(saves, 1);
    expect(tester.widget<Slider>(find.byKey(sliderKey)).onChanged, isNull);
    expect(tester.widget<Switch>(find.byKey(retryKey)).onChanged, isNull);
    expect(tester.widget<Switch>(find.byKey(repairKey)).onChanged, isNull);
    expect(
        tester
            .widget<SegmentedButton<int>>(find.byKey(timeoutKey))
            .onSelectionChanged,
        isNull);
    expect(
        tester
            .widget<SegmentedButton<ImportCompletionBehavior>>(
                find.byKey(completionKey))
            .onSelectionChanged,
        isNull);
    expect(tester.widget<TextButton>(find.byKey(resetKey)).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.byKey(doneKey)).onPressed, isNull);
    pendingSave.complete();
    await tester.pumpAndSettle();
    expect(saves, 1);
  });

  testWidgets('narrow display does not overflow', (tester) async {
    await pumpScreen(tester,
        loader: () async => ImportAdvancedPreferences.defaults,
        saver: (_) async {},
        size: const Size(360, 1400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
