import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import/import_advanced_preferences.dart';
import 'package:shiroha_quiz/ui/pages/import_advanced_settings_screen.dart';

class _FakePreferencesStore {
  _FakePreferencesStore(this.stored);

  ImportAdvancedPreferences stored;
  int loadCalls = 0;
  int saveCalls = 0;

  Future<ImportAdvancedPreferences> load() async {
    loadCalls++;
    return stored;
  }

  Future<void> save(ImportAdvancedPreferences preferences) async {
    saveCalls++;
    stored = preferences;
  }
}

void main() {
  Future<void> pumpScreen(
    WidgetTester tester, {
    ThemeData? theme,
    Size size = const Size(900, 1400),
    TextScaler textScaler = TextScaler.noScaling,
    _FakePreferencesStore? store,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final effectiveStore =
        store ?? _FakePreferencesStore(const ImportAdvancedPreferences());
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: ImportAdvancedSettingsScreen(
          preferencesLoader: effectiveStore.load,
          preferencesSaver: effectiveStore.save,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const flowSteps = <String>[
    '选择文件',
    '解析内容',
    '生成候选题目',
    '待校对',
    '确认入库',
  ];

  const sliderKey = ValueKey<String>('advanced-ocr-concurrency-slider');
  const badgeKey = ValueKey<String>('advanced-ocr-concurrency-value');

  Finder rowOf(String key) => find.byKey(ValueKey<String>(key));

  Slider sliderOf(WidgetTester tester) =>
      tester.widget<Slider>(find.byKey(sliderKey));

  Switch switchOf(WidgetTester tester, String key) {
    return tester.widget<Switch>(find.byKey(ValueKey<String>(key)));
  }

  Future<void> dragSlider(WidgetTester tester, double dx) async {
    await tester.drag(find.byKey(sliderKey), Offset(dx, 0));
    await tester.pumpAndSettle();
  }

  void expectBudget(WidgetTester tester, int expected) {
    expect(sliderOf(tester).value, expected.toDouble());
    expect(
      find.descendant(
          of: find.byKey(badgeKey), matching: find.text('$expected')),
      findsOneWidget,
      reason: 'the badge must show the active budget',
    );
    expect(find.text('当前并行任务数：'), findsOneWidget);
    expect(
      find.descendant(
        of: rowOf('advanced-ocr-concurrency-card'),
        matching: find.text('$expected'),
      ),
      findsWidgets,
    );
  }

  testWidgets('presents the fixed import pipeline as a read-only flow',
      (tester) async {
    await pumpScreen(tester);

    final strip = find.byKey(const ValueKey<String>('import-flow-strip'));
    expect(strip, findsOneWidget);
    for (final step in flowSteps) {
      expect(
        find.descendant(of: strip, matching: find.text(step)),
        findsOneWidget,
        reason: '$step must be part of the flow strip',
      );
    }
    // Five connected stages render as four arrows; a missing or reordered stage
    // breaks this count.
    expect(
      find.descendant(of: strip, matching: find.byIcon(Icons.arrow_forward)),
      findsNWidgets(4),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('import-flow-review-note')),
        matching: find.text('正式入库前需经过人工校对。'),
      ),
      findsOneWidget,
    );
    expect(find.text('入库行为'), findsNothing);
  });

  testWidgets('explains both document processing routes without a control',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('文档处理说明'), findsOneWidget);
    expect(find.text('文本直读'), findsOneWidget);
    expect(
      find.text('可直接提取文字的 PDF 或文本类文档，不经过 OCR，直接读取文字并解析。'),
      findsOneWidget,
    );
    expect(find.text('OCR 扫描'), findsOneWidget);
    expect(find.text('扫描版 PDF 或图片内容使用 OCR 识别。'), findsOneWidget);
  });

  testWidgets('offers the OCR task concurrency slider from 1 to 10',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('OCR 并行任务数'), findsOneWidget);
    expect(
      find.text('这是整个 App 的 OCR 服务请求并发上限。较高并发可能提升批量导入速度，'
          '但也可能更容易触发服务限流。单个 PDF 内仍按串行方式处理。'),
      findsOneWidget,
    );

    final slider = sliderOf(tester);
    expect(slider.min, 1);
    expect(slider.max, 10);
    expect(
      slider.divisions,
      9,
      reason: 'every whole number in 1..10 must be reachable in one step',
    );
    expectBudget(tester, ImportAdvancedPreferences.defaultOcrTaskConcurrency);
  });

  testWidgets('dragging to either end stays inside the 1..10 budget',
      (tester) async {
    await pumpScreen(tester);

    await dragSlider(tester, -2000);
    expectBudget(tester, ImportAdvancedPreferences.minOcrTaskConcurrency);

    await dragSlider(tester, 2000);
    expectBudget(tester, ImportAdvancedPreferences.maxOcrTaskConcurrency);
  });

  testWidgets('the value badge sits over the thumb it reports', (tester) async {
    await pumpScreen(tester);

    await dragSlider(tester, 150);
    final value = sliderOf(tester).value;
    expect(value, greaterThan(1));
    expect(value, lessThan(10));

    // Pressing exactly at the badge reports the same value only while the
    // badge still covers the thumb.
    await tester.tapAt(
      Offset(
        tester.getCenter(find.byKey(badgeKey)).dx,
        tester.getCenter(find.byKey(sliderKey)).dy,
      ),
    );
    await tester.pumpAndSettle();

    expect(sliderOf(tester).value, value);
  });

  testWidgets('planned exception handling rows stay inert', (tester) async {
    await pumpScreen(tester);

    expect(find.text('异常处理'), findsOneWidget);
    expect(find.text('自动重试'), findsOneWidget);
    expect(find.text('保留未识别内容'), findsOneWidget);
    expect(find.text('规划中'), findsNWidgets(2));
    expect(find.text('即将推出'), findsNWidgets(2));

    for (final key in const <String>[
      'advanced-auto-retry-switch',
      'advanced-retain-unresolved-switch',
    ]) {
      final row = rowOf(
        key == 'advanced-auto-retry-switch'
            ? 'advanced-auto-retry-row'
            : 'advanced-retain-unresolved-row',
      );
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byType(InkWell)),
        findsNothing,
        reason: 'a planned row must not look tappable',
      );
      final toggle = switchOf(tester, key);
      expect(
        toggle.onChanged,
        isNull,
        reason: 'an unimplemented capability must not be settable',
      );
      expect(toggle.value, isFalse);
    }
  });

  testWidgets('loads the persisted budget into the slider', (tester) async {
    final store = _FakePreferencesStore(
      const ImportAdvancedPreferences(
        ocrTaskConcurrency: 7,
        autoRetryEnabled: false,
        retainUnresolvedFragments: false,
      ),
    );
    await pumpScreen(tester, store: store);

    expect(store.loadCalls, 1);
    expectBudget(tester, 7);
  });

  testWidgets('pending load cannot save defaults or accept edits',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final delayed = Completer<ImportAdvancedPreferences>();
    final saved = <ImportAdvancedPreferences>[];
    await tester.pumpWidget(MaterialApp(
      home: ImportAdvancedSettingsScreen(
        preferencesLoader: () => delayed.future,
        preferencesSaver: (value) async => saved.add(value),
      ),
    ));

    expect(sliderOf(tester).onChanged, isNull);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey<String>('advanced-settings-done')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(
                const ValueKey<String>('advanced-settings-reset-defaults')),
          )
          .onPressed,
      isNull,
    );
    expect(saved, isEmpty);

    delayed.complete(const ImportAdvancedPreferences(ocrTaskConcurrency: 7));
    await tester.pumpAndSettle();
    expectBudget(tester, 7);
    expect(sliderOf(tester).onChanged, isNotNull);
    expect(saved, isEmpty);
  });

  testWidgets('editing starts only after delayed initialization resolves',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final delayed = Completer<ImportAdvancedPreferences>();
    ImportAdvancedPreferences? saved;
    await tester.pumpWidget(MaterialApp(
      home: ImportAdvancedSettingsScreen(
        preferencesLoader: () => delayed.future,
        preferencesSaver: (value) async => saved = value,
      ),
    ));
    expect(sliderOf(tester).onChanged, isNull);

    delayed.complete(const ImportAdvancedPreferences(ocrTaskConcurrency: 7));
    await tester.pumpAndSettle();
    expectBudget(tester, 7);
    sliderOf(tester).onChanged!(5);
    await tester.pump();
    expectBudget(tester, 5);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('advanced-settings-done')),
    );
    await tester
        .tap(find.byKey(const ValueKey<String>('advanced-settings-done')));
    await tester.pumpAndSettle();
    expect(saved?.ocrTaskConcurrency, 5);
  });

  testWidgets('edits stay local until the done action', (tester) async {
    final store = _FakePreferencesStore(const ImportAdvancedPreferences());
    await pumpScreen(tester, store: store);

    await dragSlider(tester, 2000);

    expectBudget(tester, ImportAdvancedPreferences.maxOcrTaskConcurrency);
    expect(
      store.saveCalls,
      0,
      reason: 'moving the slider must never persist by itself',
    );
  });

  testWidgets('reset defaults restores the working copy without saving',
      (tester) async {
    final store = _FakePreferencesStore(
      const ImportAdvancedPreferences(ocrTaskConcurrency: 9),
    );
    await pumpScreen(tester, store: store);

    expectBudget(tester, 9);

    await tester.tap(
      find.byKey(const ValueKey<String>('advanced-settings-reset-defaults')),
    );
    await tester.pumpAndSettle();

    expectBudget(tester, ImportAdvancedPreferences.defaultOcrTaskConcurrency);
    expect(
      store.saveCalls,
      0,
      reason: '恢复默认 must only reset the local working copy',
    );
    expect(store.stored.ocrTaskConcurrency, 9);
  });

  testWidgets('the done action persists the working copy and pops',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = _FakePreferencesStore(const ImportAdvancedPreferences());
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ImportAdvancedSettingsScreen(
                      preferencesLoader: store.load,
                      preferencesSaver: store.save,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(ImportAdvancedSettingsScreen), findsOneWidget);

    await dragSlider(tester, -2000);
    final slider = find.byKey(sliderKey);
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();

    final done = find.byKey(const ValueKey<String>('advanced-settings-done'));
    await tester.ensureVisible(done);
    await tester.pumpAndSettle();
    await tester.tap(done);
    await tester.pumpAndSettle();

    expect(find.byType(ImportAdvancedSettingsScreen), findsNothing);
    expect(store.saveCalls, 1);
    expect(store.stored.ocrTaskConcurrency, 1);
  });

  testWidgets('read-only rows are not interactive', (tester) async {
    await pumpScreen(tester);

    for (final key in const <String>[
      'import-flow-strip',
      'import-flow-review-note',
      'advanced-text-direct-read-row',
      'advanced-ocr-scan-row',
    ]) {
      final row = find.byKey(ValueKey<String>(key));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byType(InkWell)),
        findsNothing,
        reason: '$key must not look tappable',
      );
      expect(
        find.descendant(of: row, matching: find.byType(GestureDetector)),
        findsNothing,
        reason: '$key must not look tappable',
      );
    }
  });

  testWidgets('read-only rows are inert', (tester) async {
    await pumpScreen(tester);

    final row = find.byKey(const ValueKey<String>('advanced-ocr-scan-row'));

    // The hit test must not even reach the read-only row content: nothing above
    // it is an interactive target, so a pointer there is never absorbed by a
    // hidden affordance.
    expect(
      tester.hitTestOnBinding(tester.getCenter(row)).path.any(
            (entry) => entry.target.toString().contains('_AdvancedInfoRow'),
          ),
      isFalse,
    );

    await tester.tap(row, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(ImportAdvancedSettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders in light and dark themes', (tester) async {
    for (final brightness in Brightness.values) {
      await pumpScreen(
        tester,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: brightness,
          ),
        ),
      );

      expect(find.text('流程说明'), findsOneWidget);
      expect(find.text('OCR 并行任务数'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('narrow screen with larger text does not overflow',
      (tester) async {
    await pumpScreen(
      tester,
      size: const Size(360, 1800),
      textScaler: const TextScaler.linear(1.3),
    );

    expect(find.text('流程说明'), findsOneWidget);
    expect(find.text('OCR 并行任务数'), findsOneWidget);
    expect(find.text('异常处理'), findsOneWidget);
    for (final step in flowSteps) {
      expect(find.text(step), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop sizes do not overflow', (tester) async {
    for (final size in const <Size>[Size(1280, 900), Size(900, 1200)]) {
      await pumpScreen(tester, size: size);

      expect(find.text('流程说明'), findsOneWidget);
      expect(find.text('OCR 并行任务数'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
