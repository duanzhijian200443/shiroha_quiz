import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import/import_advanced_preferences.dart';
import 'package:shiroha_quiz/application/import/import_target_catalog_service.dart';
import 'package:shiroha_quiz/application/import/import_target_selection.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/ui/pages/import_settings_screen.dart';
import 'package:shiroha_quiz/ui/pages/paste_text_screen.dart';

final class _TargetStore implements ImportTargetSelectionStore {
  _TargetStore(this.value);
  ImportTargetSelection? value;

  @override
  Future<ImportTargetSelection?> getLastImportTarget() async => value;

  @override
  Future<void> setLastImportTarget(ImportTargetSelection? selection) async {
    value = selection;
  }
}

final class _Catalog implements ImportTargetCatalogPort {
  @override
  Future<List<ImportTargetSummary>> listImportTargets() async => const [
        ImportTargetSummary(
            bankName: '考研数学一', folderName: '数学', questionCount: 10),
        ImportTargetSummary(
            bankName: '408', folderName: '计算机', questionCount: 5),
      ];

  @override
  Future<List<String>> listAvailableFolders() async => const ['数学', '计算机'];
}

void main() {
  final catalog = _Catalog();
  ImportTargetCatalogService service(_TargetStore store) =>
      ImportTargetCatalogService(catalog: catalog, selectionStore: store);

  Future<void> pump(
    WidgetTester tester, {
    required _TargetStore store,
    required ImportTaskDispatcher dispatcher,
    Future<FilePickerResult?> Function()? picker,
  }) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: ImportSettingsScreen(
        targetCatalogService: service(store),
        importPreferencesLoader: () async => ImportAdvancedPreferences.defaults,
        pickFiles: picker,
        requestParser: (request) async =>
            const ImportParseResult(questions: <Map<String, dynamic>>[]),
        taskDispatcher: dispatcher,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('target is between mode and source; remembered path is silent',
      (tester) async {
    await pump(tester,
        store: _TargetStore(ImportTargetSelection(
            bankName: '考研数学一',
            folderName: '数学',
            targetKind: ImportTargetKind.existing)),
        dispatcher: (_, __, ___) {});
    expect(find.text('数学 / 考研数学一'), findsOneWidget);
    expect(find.text('记住本次选择'), findsNothing);
    expect(find.text('单题拍照识别请前往「拍照识题」入口。'), findsNothing);
    expect(tester.getTopLeft(find.text('解析模式')).dy,
        lessThan(tester.getTopLeft(find.text('导入到')).dy));
    expect(tester.getTopLeft(find.text('导入到')).dy,
        lessThan(tester.getTopLeft(find.text('导入来源')).dy));
  });

  testWidgets('no target disables both document intake actions',
      (tester) async {
    var dispatched = 0;
    await pump(tester,
        store: _TargetStore(null), dispatcher: (_, __, ___) => dispatched++);
    expect(find.text('选择或新建题库'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey<String>('import-file-button')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey<String>('import-clipboard-button')))
            .onPressed,
        isNull);
    expect(dispatched, 0);
  });

  testWidgets('selector lists paths and rejects duplicate proposed bank',
      (tester) async {
    final store = _TargetStore(null);
    await pump(tester, store: store, dispatcher: (_, __, ___) {});
    await tester
        .tap(find.byKey(const ValueKey<String>('import-target-selector')));
    await tester.pumpAndSettle();
    expect(find.text('数学 / 考研数学一'), findsOneWidget);
    expect(find.text('10 题'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('import-create-bank')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey<String>('import-new-bank-name')), '考研数学一');
    await tester
        .tap(find.byKey(const ValueKey<String>('import-create-bank-confirm')));
    await tester.pump();
    expect(find.text('该题库已存在，请直接选择已有题库。'), findsOneWidget);
    expect(store.value, isNull);
  });

  testWidgets(
      'new-bank action selects a proposal without creating an empty bank',
      (tester) async {
    final store = _TargetStore(null);
    await pump(tester, store: store, dispatcher: (_, __, ___) {});
    await tester
        .tap(find.byKey(const ValueKey<String>('import-target-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('import-create-bank')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey<String>('import-new-bank-name')), '线性代数专项');
    await tester.enterText(
        find.byKey(const ValueKey<String>('import-new-bank-folder')), '数学');
    await tester
        .tap(find.byKey(const ValueKey<String>('import-create-bank-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('数学 / 线性代数专项'), findsOneWidget);
    expect(store.value?.targetKind, ImportTargetKind.proposedNew);
    expect((await catalog.listImportTargets()), hasLength(2));
  });

  testWidgets('file and batch dispatch keep the target captured before picker',
      (tester) async {
    final selected = ImportTargetSelection(
      bankName: '考研数学一',
      folderName: '数学',
      targetKind: ImportTargetKind.existing,
    );
    final store = _TargetStore(selected);
    final picked = Completer<FilePickerResult?>();
    final targets = <ImportTargetSelection>[];
    await pump(tester,
        store: store,
        picker: () => picked.future,
        dispatcher: (_, __, target) => targets.add(target));
    await tester.tap(find.byKey(const ValueKey<String>('import-file-button')));
    await tester.pump();
    await tester
        .tap(find.byKey(const ValueKey<String>('import-target-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('计算机 / 408'));
    await tester.pumpAndSettle();
    picked.complete(FilePickerResult([
      for (final year in [2019, 2020, 2021])
        PlatformFile(name: '$year.pdf', path: '$year.pdf', size: 0),
    ]));
    await tester.pumpAndSettle();
    expect(targets, hasLength(3));
    expect(targets, everyElement(selected));
    expect(store.value?.bankName, '408');
  });

  testWidgets('clipboard dispatch binds the current target', (tester) async {
    final target = ImportTargetSelection(
      bankName: '考研数学一',
      folderName: '数学',
      targetKind: ImportTargetKind.existing,
    );
    final targets = <ImportTargetSelection>[];
    await pump(tester,
        store: _TargetStore(target),
        dispatcher: (_, __, selected) => targets.add(selected));
    await tester
        .tap(find.byKey(const ValueKey<String>('import-clipboard-button')));
    await tester.pumpAndSettle();
    expect(find.byType(PasteTextScreen), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Synthetic question text');
    await tester.tap(find.text('确认提取'));
    await tester.pumpAndSettle();
    expect(targets, [target]);
  });
}
