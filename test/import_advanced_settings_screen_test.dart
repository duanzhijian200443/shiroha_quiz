import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/pages/import_advanced_settings_screen.dart';

void main() {
  Future<void> pumpScreen(
    WidgetTester tester, {
    ThemeData? theme,
    Size size = const Size(900, 1400),
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: const ImportAdvancedSettingsScreen(),
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

  testWidgets('offers no automatic text/OCR routing toggle', (tester) async {
    await pumpScreen(tester);

    expect(find.textContaining('自动优先'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(Radio), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  // None of these controls has a backend consumer, so they stay out of the
  // page: OCR does not read ImportParseRequest.maxConcurrency, the provider
  // retry loops have no off-switch, and a failed batch is dropped rather than
  // staged for review. With nothing to change there is also nothing to reset.
  testWidgets('does not ship the design mock decoy strategy settings',
      (tester) async {
    await pumpScreen(tester);

    expect(find.textContaining('稳定优先'), findsNothing);
    expect(find.textContaining('速度优先'), findsNothing);
    expect(find.textContaining('处理策略'), findsNothing);
    expect(find.textContaining('自动重试'), findsNothing);
    expect(find.textContaining('失败项保留'), findsNothing);
    expect(find.textContaining('异常处理'), findsNothing);
    expect(find.textContaining('恢复默认'), findsNothing);
  });

  // The OCR path does not consume ImportParseRequest.maxConcurrency, so no
  // selectable parallelism control may be published. This locks that in.
  testWidgets('reports OCR concurrency as system-managed, with no control',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('OCR 并行度'), findsOneWidget);
    expect(find.text('OCR 并发：当前由系统自动管理'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('advanced-ocr-concurrency-row')),
      findsOneWidget,
    );
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(SegmentedButton<Object>), findsNothing);
    expect(find.byType(DropdownButton<Object>), findsNothing);
  });

  testWidgets('read-only rows are not interactive', (tester) async {
    await pumpScreen(tester);

    for (final key in const <String>[
      'import-flow-strip',
      'import-flow-review-note',
      'advanced-text-direct-read-row',
      'advanced-ocr-scan-row',
      'advanced-ocr-concurrency-row',
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

    final row =
        find.byKey(const ValueKey<String>('advanced-ocr-concurrency-row'));

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

  testWidgets('the done action pops the page', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ImportAdvancedSettingsScreen(),
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

    final done = find.byKey(const ValueKey<String>('advanced-settings-done'));
    await tester.ensureVisible(done);
    await tester.pumpAndSettle();
    await tester.tap(done);
    await tester.pumpAndSettle();

    expect(find.byType(ImportAdvancedSettingsScreen), findsNothing);
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
    expect(find.text('OCR 并行度'), findsOneWidget);
    for (final step in flowSteps) {
      expect(find.text(step), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop sizes do not overflow', (tester) async {
    for (final size in const <Size>[Size(1280, 900), Size(900, 1200)]) {
      await pumpScreen(tester, size: size);

      expect(find.text('流程说明'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
