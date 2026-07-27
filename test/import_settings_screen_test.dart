import 'dart:async';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/ui/pages/import_settings_screen.dart';

void main() {
  Future<void> pumpScreen(
    WidgetTester tester, {
    ThemeData? theme,
    Size size = const Size(900, 1400),
    TextScaler textScaler = TextScaler.noScaling,
    ImportSettingsScreen screen = const ImportSettingsScreen(),
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
        home: screen,
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
    expect(find.text('保留选择题与填空题解析'), findsOneWidget);
    expect(find.text('关闭时仅导入题干、选项和标准答案'), findsOneWidget);
    expect(
      find.text('开启后会保留详细解析，可能增加处理时间和校对问题'),
      findsOneWidget,
    );
    expect(find.text('推荐关闭'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('retention setting defaults off and exposes row and switch taps',
      (tester) async {
    final changes = <bool>[];
    await pumpScreen(
      tester,
      screen: ImportSettingsScreen(
        onRetainObjectiveExplanationsChanged: changes.add,
      ),
    );

    final row =
        find.byKey(const ValueKey<String>('retain-objective-explanations-row'));
    final switchFinder = find.byKey(
      const ValueKey<String>('retain-objective-explanations-switch'),
    );
    expect(tester.getSize(row).height, inInclusiveRange(76, 88));
    expect(tester.widget<Switch>(switchFinder).value, isFalse);

    await tester.tap(row);
    await tester.pump();

    expect(tester.widget<Switch>(switchFinder).value, isTrue);
    expect(changes, [true]);
    expect(
      tester
              .getSemantics(
                find.byKey(
                  const ValueKey<String>('import-parse-mode-vision'),
                ),
              )
              .flagsCollection
              .isSelected ==
          ui.Tristate.isTrue,
      isTrue,
    );

    await tester.tap(switchFinder);
    await tester.pump();

    expect(tester.widget<Switch>(switchFinder).value, isFalse);
    expect(changes, [true, false]);
  });

  testWidgets('retention setting accepts an enabled initial value',
      (tester) async {
    await pumpScreen(
      tester,
      screen: const ImportSettingsScreen(
        retainObjectiveExplanations: true,
      ),
    );

    expect(
      tester
          .widget<Switch>(
            find.byKey(
              const ValueKey<String>('retain-objective-explanations-switch'),
            ),
          )
          .value,
      isTrue,
    );
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

  testWidgets('text mode disables camera and gallery but allows clipboard',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('文本（最快）'));
    await tester.pumpAndSettle();

    final camera = tester.widget<ElevatedButton>(
      find.byKey(const ValueKey<String>('import-camera-button')),
    );
    final gallery = tester.widget<ElevatedButton>(
      find.byKey(const ValueKey<String>('import-gallery-button')),
    );
    final clipboard = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey<String>('import-clipboard-button')),
    );
    final cameraSemantics = tester.getSemantics(
      find.byKey(const ValueKey<String>('import-camera-button')),
    );

    expect(camera.onPressed, isNull);
    expect(gallery.onPressed, isNull);
    expect(clipboard.onPressed, isNotNull);
    expect(
      cameraSemantics.flagsCollection.isEnabled == ui.Tristate.isFalse,
      isTrue,
    );
  });

  testWidgets('vision mode enables image entries and disables clipboard',
      (tester) async {
    await pumpScreen(tester);

    expect(
      tester
          .widget<ElevatedButton>(
            find.byKey(const ValueKey<String>('import-camera-button')),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<ElevatedButton>(
            find.byKey(const ValueKey<String>('import-gallery-button')),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey<String>('import-clipboard-button')),
          )
          .onPressed,
      isNull,
    );
    final clipboardSemantics = tester.getSemantics(
      find.byKey(const ValueKey<String>('import-clipboard-button')),
    );
    expect(
      clipboardSemantics.flagsCollection.isEnabled == ui.Tristate.isFalse,
      isTrue,
    );
  });

  testWidgets('OCR mode enables image entries and disables clipboard',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('OCR（扫描）'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<ElevatedButton>(
            find.byKey(const ValueKey<String>('import-camera-button')),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<ElevatedButton>(
            find.byKey(const ValueKey<String>('import-gallery-button')),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey<String>('import-clipboard-button')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('disabled image entry neither picks an image nor dispatches',
      (tester) async {
    var pickCalls = 0;
    var dispatchCalls = 0;
    await pumpScreen(
      tester,
      screen: ImportSettingsScreen(
        pickImage: (source) async {
          pickCalls++;
          return null;
        },
        taskDispatcher: (source, parseTask) {
          dispatchCalls++;
        },
      ),
    );
    await tester.tap(find.text('文本（最快）'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('import-camera-button')),
    );
    await tester.pump();

    expect(pickCalls, 0);
    expect(dispatchCalls, 0);
  });

  testWidgets('vision mode rejects ZIP DOCX TXT and MD as one selection',
      (tester) async {
    var dispatchCalls = 0;
    await pumpScreen(
      tester,
      screen: ImportSettingsScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'archive.zip', path: 'archive.zip', size: 0),
          PlatformFile(name: 'paper.docx', path: 'paper.docx', size: 0),
          PlatformFile(name: 'notes.txt', path: 'notes.txt', size: 0),
          PlatformFile(name: 'quiz.md', path: 'quiz.md', size: 0),
        ]),
        taskDispatcher: (source, parseTask) {
          dispatchCalls++;
        },
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('import-file-button')),
    );
    await tester.pumpAndSettle();

    expect(dispatchCalls, 0);
    expect(
      find.textContaining('视觉模式不支持 ZIP、DOCX 或纯文本文件'),
      findsOneWidget,
    );
    expect(find.textContaining('archive.zip'), findsOneWidget);
    expect(find.textContaining('paper.docx'), findsOneWidget);
    expect(find.textContaining('notes.txt'), findsOneWidget);
    expect(find.textContaining('quiz.md'), findsOneWidget);
  });

  testWidgets('OCR mode rejects files other than PDF PNG and JPG',
      (tester) async {
    var dispatchCalls = 0;
    await pumpScreen(
      tester,
      screen: ImportSettingsScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'paper.docx', path: 'paper.docx', size: 0),
        ]),
        taskDispatcher: (source, parseTask) {
          dispatchCalls++;
        },
      ),
    );
    await tester.tap(find.text('OCR（扫描）'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('import-file-button')),
    );
    await tester.pumpAndSettle();

    expect(dispatchCalls, 0);
    expect(
      find.textContaining('OCR 模式仅支持 PDF、PNG 和 JPG/JPEG'),
      findsOneWidget,
    );
  });

  testWidgets('mixed compatible and incompatible files are rejected together',
      (tester) async {
    var dispatchCalls = 0;
    await pumpScreen(
      tester,
      screen: ImportSettingsScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'scan.pdf', path: 'scan.pdf', size: 0),
          PlatformFile(name: 'notes.txt', path: 'notes.txt', size: 0),
        ]),
        taskDispatcher: (source, parseTask) {
          dispatchCalls++;
        },
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('import-file-button')),
    );
    await tester.pumpAndSettle();

    expect(dispatchCalls, 0);
    expect(find.textContaining('notes.txt'), findsOneWidget);
  });

  testWidgets('text mode rejects images without changing the selected mode',
      (tester) async {
    var dispatchCalls = 0;
    await pumpScreen(
      tester,
      screen: ImportSettingsScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'photo.png', path: 'photo.png', size: 0),
        ]),
        taskDispatcher: (source, parseTask) {
          dispatchCalls++;
        },
      ),
    );
    await tester.tap(find.text('文本（最快）'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('import-file-button')),
    );
    await tester.pumpAndSettle();

    final textSemantics = tester.getSemantics(
      find.byKey(const ValueKey<String>('import-parse-mode-text')),
    );
    expect(dispatchCalls, 0);
    expect(
      find.textContaining('文本模式不支持图片，请改用视觉或 OCR 模式'),
      findsOneWidget,
    );
    expect(
      textSemantics.flagsCollection.isSelected == ui.Tristate.isTrue,
      isTrue,
    );
  });

  testWidgets('file request carries the enabled explanation retention mode',
      (tester) async {
    final captured = Completer<ImportParseRequest>();
    await pumpScreen(
      tester,
      screen: ImportSettingsScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'paper.pdf', path: 'paper.pdf', size: 0),
        ]),
        requestParser: (request) async {
          captured.complete(request);
          return ImportParseResult(
            questions: const <Map<String, dynamic>>[],
            explanationRetentionMode: request.explanationRetentionMode,
          );
        },
        taskDispatcher: (source, parseTask) {
          unawaited(parseTask('settings-file-task'));
        },
      ),
    );

    await tester.tap(
      find.byKey(
        const ValueKey<String>('retain-objective-explanations-row'),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('import-file-button')),
    );
    await tester.pump();

    final request = await captured.future;
    expect(
      request.explanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );
  });

  testWidgets('image request carries the default retention mode',
      (tester) async {
    final captured = Completer<ImportParseRequest>();
    await pumpScreen(
      tester,
      screen: ImportSettingsScreen(
        pickImage: (source) async => XFile('photo.png'),
        requestParser: (request) async {
          captured.complete(request);
          return ImportParseResult(
            questions: const <Map<String, dynamic>>[],
            explanationRetentionMode: request.explanationRetentionMode,
          );
        },
        taskDispatcher: (source, parseTask) {
          unawaited(parseTask('settings-image-task'));
        },
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('import-gallery-button')),
    );
    await tester.pump();

    final request = await captured.future;
    expect(
      request.explanationRetentionMode,
      ExplanationRetentionMode.subjectiveOnly,
    );
  });

  testWidgets('changing parse mode preserves the retention selection',
      (tester) async {
    await pumpScreen(tester);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('retain-objective-explanations-row'),
      ),
    );
    await tester.tap(find.text('文本（最快）'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Switch>(
            find.byKey(
              const ValueKey<String>('retain-objective-explanations-switch'),
            ),
          )
          .value,
      isTrue,
    );
  });
}
