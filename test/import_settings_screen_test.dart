import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/pages/import_settings_screen.dart';

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
        home: const ImportSettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows three mutually exclusive parse mode cards',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('视觉（推荐）'), findsOneWidget);
    expect(find.text('适合图片、扫描 PDF 与复杂公式'), findsOneWidget);
    expect(find.text('文本（最快）'), findsOneWidget);
    expect(find.text('适合可提取文字的 PDF 与剪贴板文本'), findsOneWidget);
    expect(find.text('OCR（扫描）'), findsOneWidget);
    expect(find.text('先识别文字再解析，适合扫描文档'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('defaults to vision and exposes radio selection semantics',
      (tester) async {
    await pumpScreen(tester);

    final visionSemantics = tester.getSemantics(
      find.byKey(const ValueKey<String>('import-parse-mode-vision')),
    );
    final textSemantics = tester.getSemantics(
      find.byKey(const ValueKey<String>('import-parse-mode-text')),
    );

    expect(
      visionSemantics.flagsCollection.isSelected == ui.Tristate.isTrue,
      isTrue,
    );
    expect(
      visionSemantics.flagsCollection.isInMutuallyExclusiveGroup,
      isTrue,
    );
    expect(
      textSemantics.flagsCollection.isSelected == ui.Tristate.isTrue,
      isFalse,
    );
    expect(find.text('多图并发线程上限'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('selecting another mode hides vision concurrency controls',
      (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('文本（最快）'));
    await tester.pumpAndSettle();

    final textSemantics = tester.getSemantics(
      find.byKey(const ValueKey<String>('import-parse-mode-text')),
    );
    final visionSemantics = tester.getSemantics(
      find.byKey(const ValueKey<String>('import-parse-mode-vision')),
    );
    expect(
      textSemantics.flagsCollection.isSelected == ui.Tristate.isTrue,
      isTrue,
    );
    expect(
      visionSemantics.flagsCollection.isSelected == ui.Tristate.isTrue,
      isFalse,
    );
    expect(find.text('多图并发线程上限'), findsNothing);

    await tester.tap(find.text('OCR（扫描）'));
    await tester.pumpAndSettle();
    final ocrSemantics = tester.getSemantics(
      find.byKey(const ValueKey<String>('import-parse-mode-ocr')),
    );
    expect(
      ocrSemantics.flagsCollection.isSelected == ui.Tristate.isTrue,
      isTrue,
    );
    expect(find.text('多图并发线程上限'), findsNothing);
  });

  testWidgets('uses the active ColorScheme in light and dark themes',
      (tester) async {
    for (final brightness in Brightness.values) {
      final colorScheme = ColorScheme.fromSeed(
        seedColor: Colors.indigo,
        brightness: brightness,
      );
      await pumpScreen(
        tester,
        theme: ThemeData(colorScheme: colorScheme),
      );

      final selectedMaterial = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(
                const ValueKey<String>('import-parse-mode-vision'),
              ),
              matching: find.byType(Material),
            )
            .first,
      );
      final unselectedMaterial = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(
                const ValueKey<String>('import-parse-mode-text'),
              ),
              matching: find.byType(Material),
            )
            .first,
      );

      expect(selectedMaterial.color, colorScheme.primaryContainer);
      expect(unselectedMaterial.color, colorScheme.surface);
    }
  });

  testWidgets('mode cards support a narrow screen and larger text',
      (tester) async {
    await pumpScreen(
      tester,
      size: const Size(360, 1800),
      textScaler: const TextScaler.linear(1.3),
    );

    expect(find.text('视觉（推荐）'), findsOneWidget);
    expect(find.text('OCR（扫描）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
