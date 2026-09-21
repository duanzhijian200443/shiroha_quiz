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

  Finder strategyCard(String key) => find.byKey(ValueKey<String>(key));

  Finder selectedIconOf(String cardKey) => find.descendant(
        of: strategyCard(cardKey),
        matching: find.byIcon(Icons.check_circle),
      );

  Finder unselectedIconOf(String cardKey) => find.descendant(
        of: strategyCard(cardKey),
        matching: find.byIcon(Icons.radio_button_unchecked),
      );

  Switch switchOf(WidgetTester tester, String key) {
    return tester.widget<Switch>(find.byKey(ValueKey<String>(key)));
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

  testWidgets('offers the three processing strategies with automatic selected',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('处理策略'), findsOneWidget);
    expect(find.text('自动（推荐）'), findsOneWidget);
    expect(find.text('稳定优先'), findsOneWidget);
    expect(find.text('速度优先'), findsOneWidget);

    expect(selectedIconOf('advanced-strategy-automatic'), findsOneWidget);
    expect(unselectedIconOf('advanced-strategy-stability'), findsOneWidget);
    expect(unselectedIconOf('advanced-strategy-speed'), findsOneWidget);
  });

  testWidgets('exception handling toggles default to on', (tester) async {
    await pumpScreen(tester);

    expect(find.text('异常处理'), findsOneWidget);
    expect(find.text('自动重试'), findsOneWidget);
    expect(find.text('保留未识别内容'), findsOneWidget);
    expect(switchOf(tester, 'advanced-auto-retry-switch').value, isTrue);
    expect(switchOf(tester, 'advanced-retain-unresolved-switch').value, isTrue);
  });

  testWidgets('loads persisted preferences into the controls', (tester) async {
    final store = _FakePreferencesStore(
      const ImportAdvancedPreferences(
        processingStrategy: ImportProcessingStrategy.stability,
        autoRetryEnabled: false,
        retainUnresolvedFragments: false,
      ),
    );
    await pumpScreen(tester, store: store);

    expect(store.loadCalls, 1);
    expect(selectedIconOf('advanced-strategy-stability'), findsOneWidget);
    expect(switchOf(tester, 'advanced-auto-retry-switch').value, isFalse);
    expect(
      switchOf(tester, 'advanced-retain-unresolved-switch').value,
      isFalse,
    );
  });

  testWidgets('edits stay local until the done action', (tester) async {
    final store = _FakePreferencesStore(const ImportAdvancedPreferences());
    await pumpScreen(tester, store: store);

    await tester.tap(strategyCard('advanced-strategy-speed'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>(
      'advanced-auto-retry-switch',
    )));
    await tester.pumpAndSettle();

    expect(selectedIconOf('advanced-strategy-speed'), findsOneWidget);
    expect(unselectedIconOf('advanced-strategy-automatic'), findsOneWidget);
    expect(switchOf(tester, 'advanced-auto-retry-switch').value, isFalse);
    expect(
      store.saveCalls,
      0,
      reason: 'tapping a control must never persist by itself',
    );
  });

  testWidgets('reset defaults restores the working copy without saving',
      (tester) async {
    final store = _FakePreferencesStore(
      const ImportAdvancedPreferences(
        processingStrategy: ImportProcessingStrategy.speed,
        autoRetryEnabled: false,
      ),
    );
    await pumpScreen(tester, store: store);

    expect(selectedIconOf('advanced-strategy-speed'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('advanced-settings-reset-defaults')),
    );
    await tester.pumpAndSettle();

    expect(selectedIconOf('advanced-strategy-automatic'), findsOneWidget);
    expect(switchOf(tester, 'advanced-auto-retry-switch').value, isTrue);
    expect(switchOf(tester, 'advanced-retain-unresolved-switch').value, isTrue);
    expect(
      store.saveCalls,
      0,
      reason: '恢复默认 must only reset the local working copy',
    );
    expect(store.stored.processingStrategy, ImportProcessingStrategy.speed);
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

    await tester.tap(strategyCard('advanced-strategy-stability'));
    await tester.pumpAndSettle();
    final retainSwitch =
        find.byKey(const ValueKey<String>('advanced-retain-unresolved-switch'));
    await tester.ensureVisible(retainSwitch);
    await tester.pumpAndSettle();
    await tester.tap(retainSwitch);
    await tester.pumpAndSettle();

    final done = find.byKey(const ValueKey<String>('advanced-settings-done'));
    await tester.ensureVisible(done);
    await tester.pumpAndSettle();
    await tester.tap(done);
    await tester.pumpAndSettle();

    expect(find.byType(ImportAdvancedSettingsScreen), findsNothing);
    expect(store.saveCalls, 1);
    expect(
      store.stored,
      const ImportAdvancedPreferences(
        processingStrategy: ImportProcessingStrategy.stability,
        retainUnresolvedFragments: false,
      ),
    );
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
      expect(find.text('处理策略'), findsOneWidget);
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
    expect(find.text('处理策略'), findsOneWidget);
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
      expect(find.text('处理策略'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
