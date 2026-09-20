import 'dart:async';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/ui/pages/import_advanced_settings_screen.dart';
import 'package:shiroha_quiz/ui/pages/import_settings_screen.dart';
import 'package:shiroha_quiz/ui/pages/paste_text_screen.dart';

class _RecordingNavigatorObserver extends NavigatorObserver {
  int pushCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount++;
    super.didPush(route, previousRoute);
  }
}

void main() {
  Future<void> pumpScreen(
    WidgetTester tester, {
    ThemeData? theme,
    Size size = const Size(900, 1400),
    TextScaler textScaler = TextScaler.noScaling,
    ImportSettingsScreen screen = const ImportSettingsScreen(),
    NavigatorObserver? navigatorObserver,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        navigatorObservers: <NavigatorObserver>[
          if (navigatorObserver != null) navigatorObserver,
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: screen,
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder ocrCard() =>
      find.byKey(const ValueKey<String>('import-parse-mode-ocr'));
  Finder textCard() =>
      find.byKey(const ValueKey<String>('import-parse-mode-text'));
  Finder fileButton() =>
      find.byKey(const ValueKey<String>('import-file-button'));
  Finder clipboardButton() =>
      find.byKey(const ValueKey<String>('import-clipboard-button'));

  ImportSettingsScreen fileScreen({
    required Future<FilePickerResult?> Function() pickFiles,
    required List<ImportParseRequest> requests,
    ImportTaskDispatcher? taskDispatcher,
  }) {
    var dispatchedTaskIndex = 0;
    return ImportSettingsScreen(
      pickFiles: pickFiles,
      requestParser: (request) async {
        requests.add(request);
        return ImportParseResult(
          questions: const <Map<String, dynamic>>[],
          explanationRetentionMode: request.explanationRetentionMode,
        );
      },
      taskDispatcher: taskDispatcher ??
          (source, parseTask) {
            unawaited(parseTask('settings-task-${dispatchedTaskIndex++}'));
          },
    );
  }

  testWidgets('exposes only the OCR and text-direct parse modes',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('OCR 扫描'), findsOneWidget);
    expect(
      find.text('适用于扫描版 PDF、图片及无法直接提取文字的文档。'),
      findsOneWidget,
    );
    expect(find.text('文本直读'), findsOneWidget);
    expect(
      find.text('适用于可提取文字的 PDF 与纯文本内容，直接读取文字并解析，不经过 OCR，速度更快。'),
      findsOneWidget,
    );
    expect(ocrCard(), findsOneWidget);
    expect(textCard(), findsOneWidget);
    // OCR leads the list, matching its default selection.
    expect(
      tester.getTopLeft(ocrCard()).dy,
      lessThan(tester.getTopLeft(textCard()).dy),
    );
  });

  testWidgets('does not expose vision as a document import mode',
      (tester) async {
    await pumpScreen(tester);

    expect(
      find.byKey(const ValueKey<String>('import-parse-mode-vision')),
      findsNothing,
    );
    expect(find.text('视觉'), findsNothing);
    expect(find.textContaining('视觉'), findsNothing);
  });

  testWidgets('carries no marketing labels or retention toggle',
      (tester) async {
    await pumpScreen(tester);

    expect(find.textContaining('推荐'), findsNothing);
    expect(find.textContaining('最快'), findsNothing);
    expect(find.text('保留选择题与填空题解析'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('retain-objective-explanations-row')),
      findsNothing,
    );
    expect(
      find.byKey(
          const ValueKey<String>('retain-objective-explanations-switch')),
      findsNothing,
    );
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('does not expose camera or gallery actions', (tester) async {
    await pumpScreen(tester);

    expect(
      find.byKey(const ValueKey<String>('import-camera-button')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('import-gallery-button')),
      findsNothing,
    );
    expect(find.text('拍照识别'), findsNothing);
    expect(find.text('相册选图'), findsNothing);
  });

  testWidgets('defaults to OCR and exposes radio selection semantics',
      (tester) async {
    await pumpScreen(tester);

    final ocrSemantics = tester.getSemantics(ocrCard());
    final textSemantics = tester.getSemantics(textCard());

    expect(
      ocrSemantics.flagsCollection.isSelected == ui.Tristate.isTrue,
      isTrue,
    );
    expect(
      ocrSemantics.flagsCollection.isInMutuallyExclusiveGroup,
      isTrue,
    );
    expect(
      textSemantics.flagsCollection.isSelected == ui.Tristate.isTrue,
      isFalse,
    );
    expect(
      textSemantics.flagsCollection.isInMutuallyExclusiveGroup,
      isTrue,
    );
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('selecting text direct read moves the exclusive selection',
      (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('文本直读'));
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(textCard()).flagsCollection.isSelected ==
          ui.Tristate.isTrue,
      isTrue,
    );
    expect(
      tester.getSemantics(ocrCard()).flagsCollection.isSelected ==
          ui.Tristate.isTrue,
      isFalse,
    );
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('clipboard stays actionable while OCR is selected',
      (tester) async {
    await pumpScreen(tester);

    final clipboard = tester.widget<OutlinedButton>(clipboardButton());

    expect(clipboard.onPressed, isNotNull);
    expect(
      tester.getSemantics(clipboardButton()).flagsCollection.isEnabled ==
          ui.Tristate.isFalse,
      isFalse,
    );
    expect(
      tester.getSemantics(ocrCard()).flagsCollection.isSelected ==
          ui.Tristate.isTrue,
      isTrue,
    );
  });

  testWidgets('clipboard opens the text paste entry while OCR is selected',
      (tester) async {
    await pumpScreen(tester);

    expect(ocrCard(), findsOneWidget);
    await tester.tap(clipboardButton());
    await tester.pumpAndSettle();

    expect(find.byType(PasteTextScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file action under OCR dispatches an OCR request',
      (tester) async {
    final requests = <ImportParseRequest>[];
    await pumpScreen(
      tester,
      screen: fileScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'paper.pdf', path: 'paper.pdf', size: 0),
        ]),
        requests: requests,
      ),
    );

    await tester.tap(fileButton());
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(requests.single.mode, ImportParseMode.ocr);
  });

  testWidgets('file action under text direct read dispatches a text request',
      (tester) async {
    final requests = <ImportParseRequest>[];
    await pumpScreen(
      tester,
      screen: fileScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'notes.txt', path: 'notes.txt', size: 0),
        ]),
        requests: requests,
      ),
    );

    await tester.tap(find.text('文本直读'));
    await tester.pumpAndSettle();
    await tester.tap(fileButton());
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(requests.single.mode, ImportParseMode.text);
  });

  testWidgets('every new import fixes the explanation retention policy',
      (tester) async {
    final requests = <ImportParseRequest>[];
    await pumpScreen(
      tester,
      screen: fileScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'paper.pdf', path: 'paper.pdf', size: 0),
        ]),
        requests: requests,
      ),
    );

    await tester.tap(fileButton());
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(
      requests.single.explanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );
    expect(
      newDocumentImportExplanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
      reason: 'the fixed document import policy must stay retain-everything',
    );
  });

  testWidgets('multi-file batch keeps the fixed retention policy',
      (tester) async {
    final requests = <ImportParseRequest>[];
    await pumpScreen(
      tester,
      screen: fileScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'a.pdf', path: 'a.pdf', size: 0),
          PlatformFile(name: 'b.pdf', path: 'b.pdf', size: 0),
        ]),
        requests: requests,
      ),
    );

    await tester.tap(fileButton());
    await tester.pumpAndSettle();

    expect(requests, hasLength(2));
    expect(
      requests.every(
        (request) =>
            request.explanationRetentionMode ==
            ExplanationRetentionMode.allQuestionTypes,
      ),
      isTrue,
    );
  });

  testWidgets('OCR rejects text and archive documents with new guidance',
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

    await tester.tap(fileButton());
    await tester.pumpAndSettle();

    expect(dispatchCalls, 0);
    expect(
      find.textContaining('OCR 扫描仅支持 PDF 和图片；文本类文档请使用文本直读。'),
      findsOneWidget,
    );
    expect(find.textContaining('archive.zip'), findsOneWidget);
    expect(find.textContaining('paper.docx'), findsOneWidget);
    expect(find.textContaining('notes.txt'), findsOneWidget);
    expect(find.textContaining('quiz.md'), findsOneWidget);
  });

  testWidgets('text direct read rejects images with new guidance',
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

    await tester.tap(find.text('文本直读'));
    await tester.pumpAndSettle();
    await tester.tap(fileButton());
    await tester.pumpAndSettle();

    expect(dispatchCalls, 0);
    expect(
      find.textContaining('图片无法使用文本直读，请改用 OCR 扫描或拍照识题。'),
      findsOneWidget,
    );
    expect(find.textContaining('photo.png'), findsOneWidget);
    expect(
      tester.getSemantics(textCard()).flagsCollection.isSelected ==
          ui.Tristate.isTrue,
      isTrue,
      reason: 'a rejected selection must not silently change the chosen mode',
    );
  });

  testWidgets('never advises switching to the removed vision mode',
      (tester) async {
    await pumpScreen(
      tester,
      screen: ImportSettingsScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'photo.png', path: 'photo.png', size: 0),
        ]),
        taskDispatcher: (source, parseTask) {},
      ),
    );

    await tester.tap(find.text('文本直读'));
    await tester.pumpAndSettle();
    await tester.tap(fileButton());
    await tester.pumpAndSettle();

    expect(find.textContaining('视觉模式'), findsNothing);
    expect(find.textContaining('改用视觉'), findsNothing);
  });

  testWidgets('file support hint reflects the selected mode', (tester) async {
    await pumpScreen(tester);
    final hint = find.byKey(const ValueKey<String>('import-file-support-hint'));

    expect(hint, findsOneWidget);
    expect(tester.widget<Text>(hint).data, contains('PDF'));
    expect(tester.widget<Text>(hint).data, contains('PNG'));
    expect(tester.widget<Text>(hint).data, isNot(contains('ZIP')));

    await tester.tap(find.text('文本直读'));
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(hint).data, contains('DOCX'));
    expect(tester.widget<Text>(hint).data, contains('ZIP'));
    expect(tester.widget<Text>(hint).data, isNot(contains('PNG')));
  });

  testWidgets('JSON import format help stays reachable as a secondary action',
      (tester) async {
    await pumpScreen(tester);

    final entry =
        find.byKey(const ValueKey<String>('import-json-format-entry'));
    expect(entry, findsOneWidget);

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.text('标准 JSON 导入格式'), findsWidgets);
    expect(find.textContaining('"standard_answer"'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"standard_answer"'), findsNothing);
  });

  testWidgets('advanced settings entry opens the advanced settings page',
      (tester) async {
    await pumpScreen(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('import-advanced-settings-entry')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ImportAdvancedSettingsScreen), findsOneWidget);
  });

  testWidgets('keeps the file action as the visually primary source action',
      (tester) async {
    await pumpScreen(tester);

    final fileTop = tester.getTopLeft(fileButton()).dy;
    final clipboardTop = tester.getTopLeft(clipboardButton()).dy;

    expect(fileTop, lessThan(clipboardTop));
  });

  testWidgets('renders in light and dark themes from the active color scheme',
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
              of: ocrCard(),
              matching: find.byType(Material),
            )
            .first,
      );
      final unselectedMaterial = tester.widget<Material>(
        find
            .descendant(
              of: textCard(),
              matching: find.byType(Material),
            )
            .first,
      );

      expect(selectedMaterial.color, colorScheme.primaryContainer);
      expect(unselectedMaterial.color, colorScheme.surface);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('narrow screen with larger text does not overflow',
      (tester) async {
    await pumpScreen(
      tester,
      size: const Size(360, 1600),
      textScaler: const TextScaler.linear(1.3),
    );

    expect(find.text('OCR 扫描'), findsOneWidget);
    expect(find.text('文本直读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop width does not overflow', (tester) async {
    await pumpScreen(tester, size: const Size(1280, 900));

    expect(find.text('OCR 扫描'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tall narrow desktop does not overflow', (tester) async {
    await pumpScreen(tester, size: const Size(900, 1200));

    expect(find.text('OCR 扫描'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multi-file selection dispatches one request per file in order',
      (tester) async {
    final sources = <String>[];
    final requests = <ImportParseRequest>[];
    final navigatorObserver = _RecordingNavigatorObserver();
    var dispatchedTaskIndex = 0;
    await pumpScreen(
      tester,
      navigatorObserver: navigatorObserver,
      screen: ImportSettingsScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'first.pdf', path: 'first.pdf', size: 0),
          PlatformFile(name: 'same.pdf', path: 'second.pdf', size: 0),
          PlatformFile(name: 'same.pdf', path: 'third.pdf', size: 0),
          PlatformFile(name: 'fourth.pdf', path: 'fourth.pdf', size: 0),
        ]),
        requestParser: (request) async {
          requests.add(request);
          return ImportParseResult(
            questions: const <Map<String, dynamic>>[],
            explanationRetentionMode: request.explanationRetentionMode,
          );
        },
        taskDispatcher: (source, parseTask) {
          sources.add(source);
          unawaited(parseTask('settings-task-${dispatchedTaskIndex++}'));
        },
      ),
    );
    final initialPushCount = navigatorObserver.pushCount;

    await tester.tap(fileButton());
    await tester.pump();

    expect(
        sources, <String>['first.pdf', 'same.pdf', 'same.pdf', 'fourth.pdf']);
    expect(requests, hasLength(4));
    expect(
      requests.map((request) => request.filePaths.single),
      <String>['first.pdf', 'second.pdf', 'third.pdf', 'fourth.pdf'],
    );
    expect(requests.every((request) => request.filePaths.length == 1), isTrue);
    expect(navigatorObserver.pushCount, initialPushCount);
  });

  testWidgets('multi-image selection under OCR dispatches one request',
      (tester) async {
    final sources = <String>[];
    final requests = <ImportParseRequest>[];
    var dispatchedTaskIndex = 0;
    await pumpScreen(
      tester,
      screen: ImportSettingsScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'img1.png', path: 'img1.png', size: 0),
          PlatformFile(name: 'img2.png', path: 'img2.png', size: 0),
        ]),
        requestParser: (request) async {
          requests.add(request);
          return ImportParseResult(
            questions: const <Map<String, dynamic>>[],
            explanationRetentionMode: request.explanationRetentionMode,
          );
        },
        taskDispatcher: (source, parseTask) {
          sources.add(source);
          unawaited(parseTask('settings-task-${dispatchedTaskIndex++}'));
        },
      ),
    );

    await tester.tap(fileButton());
    await tester.pump();

    expect(sources, <String>['img1.png 等 2 个文件']);
    expect(requests, hasLength(1));
    expect(requests.single.filePaths, <String>['img1.png', 'img2.png']);
  });

  testWidgets('TXT Markdown and DOCX dispatch one aggregated request',
      (tester) async {
    final sources = <String>[];
    final requests = <ImportParseRequest>[];
    var dispatchedTaskIndex = 0;
    await pumpScreen(
      tester,
      screen: ImportSettingsScreen(
        pickFiles: () async => FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'notes1.txt', path: 'notes1.txt', size: 0),
          PlatformFile(name: 'notes2.md', path: 'notes2.md', size: 0),
          PlatformFile(name: 'notes3.docx', path: 'notes3.docx', size: 0),
        ]),
        requestParser: (request) async {
          requests.add(request);
          return ImportParseResult(
            questions: const <Map<String, dynamic>>[],
            explanationRetentionMode: request.explanationRetentionMode,
          );
        },
        taskDispatcher: (source, parseTask) {
          sources.add(source);
          unawaited(parseTask('settings-task-${dispatchedTaskIndex++}'));
        },
      ),
    );

    await tester.tap(find.text('文本直读'));
    await tester.pumpAndSettle();
    await tester.tap(fileButton());
    await tester.pump();

    expect(sources, <String>['notes1.txt 等 3 个文件']);
    expect(requests, hasLength(1));
    expect(
      requests.single.filePaths,
      <String>['notes1.txt', 'notes2.md', 'notes3.docx'],
    );
    expect(requests.single.mode, ImportParseMode.text);
  });
}
