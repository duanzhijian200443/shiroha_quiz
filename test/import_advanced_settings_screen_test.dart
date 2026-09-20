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

  testWidgets('states the fixed post-import review flow as read-only',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('导入后流程'), findsOneWidget);
    expect(find.text('识别完成后进入校对页'), findsOneWidget);
    expect(find.text('确认题目、答案和解析后再收入题库。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('import-flow-review-row')),
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

  testWidgets('does not ship the design mock decoy strategy settings',
      (tester) async {
    await pumpScreen(tester);

    expect(find.textContaining('稳定优先'), findsNothing);
    expect(find.textContaining('速度优先'), findsNothing);
    expect(find.textContaining('处理策略'), findsNothing);
    expect(find.textContaining('自动重试'), findsNothing);
    expect(find.textContaining('失败项保留'), findsNothing);
    expect(find.textContaining('异常处理'), findsNothing);
    expect(find.textContaining('流程说明'), findsNothing);
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
      'import-flow-review-row',
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

      expect(find.text('导入后流程'), findsOneWidget);
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

    expect(find.text('导入后流程'), findsOneWidget);
    expect(find.text('OCR 并行度'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop sizes do not overflow', (tester) async {
    for (final size in const <Size>[Size(1280, 900), Size(900, 1200)]) {
      await pumpScreen(tester, size: size);

      expect(find.text('导入后流程'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
