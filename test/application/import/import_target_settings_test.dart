import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import/import_target_catalog_service.dart';
import 'package:shiroha_quiz/application/import/import_target_selection.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/settings_repository.dart';

final class _SettingsDb extends Fake implements DatabaseHelper {
  final Map<String, String> values = {};

  @override
  Future<String?> getSetting(String key) async => values[key];

  @override
  Future<void> saveSetting(String key, String value) async {
    values[key] = value;
  }
}

final class _Catalog implements ImportTargetCatalogPort {
  List<ImportTargetSummary> banks = [
    const ImportTargetSummary(
        bankName: '考研数学一', folderName: '数学', questionCount: 5),
  ];

  @override
  Future<List<ImportTargetSummary>> listImportTargets() async => banks;

  @override
  Future<List<String>> listAvailableFolders() async => ['数学'];
}

void main() {
  test('existing target survives repository reload and deletion clears it',
      () async {
    final db = _SettingsDb();
    final catalog = _Catalog();
    final service = ImportTargetCatalogService(
      catalog: catalog,
      selectionStore: SettingsRepository(databaseHelper: db),
    );
    final selected = await service.selectExisting(catalog.banks.single);
    final reloaded = ImportTargetCatalogService(
      catalog: catalog,
      selectionStore: SettingsRepository(databaseHelper: db),
    );
    expect(await reloaded.restore(), selected);
    catalog.banks = [];
    expect(await reloaded.restore(), isNull);
    expect(await SettingsRepository(databaseHelper: db).getLastImportTarget(),
        isNull);
  });

  test(
      'proposed target persists without creating bank and duplicate is rejected',
      () async {
    final db = _SettingsDb();
    final catalog = _Catalog();
    final service = ImportTargetCatalogService(
      catalog: catalog,
      selectionStore: SettingsRepository(databaseHelper: db),
    );
    final proposed = await service.proposeNew(
      bankName: ' 线性代数专项 ',
      folderName: '数学',
    );
    expect(proposed.targetKind, ImportTargetKind.proposedNew);
    expect(catalog.banks, hasLength(1));
    expect(await service.restore(), proposed);
    await expectLater(
      service.proposeNew(bankName: '考研数学一'),
      throwsA(isA<ImportTargetSelectionException>().having(
        (e) => e.failure,
        'failure',
        ImportTargetSelectionFailure.duplicateName,
      )),
    );
    catalog.banks = [
      ...catalog.banks,
      const ImportTargetSummary(
          bankName: '线性代数专项', folderName: '数学', questionCount: 2),
    ];
    expect((await service.restore())?.targetKind, ImportTargetKind.existing);
  });
}
