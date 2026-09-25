import 'import_target_selection.dart';

final class ImportTargetSummary {
  const ImportTargetSummary({
    required this.bankName,
    this.folderName,
    required this.questionCount,
  });

  final String bankName;
  final String? folderName;
  final int questionCount;

  String get displayPath =>
      folderName == null ? bankName : '$folderName / $bankName';
}

abstract interface class ImportTargetCatalogPort {
  Future<List<ImportTargetSummary>> listImportTargets();
  Future<List<String>> listAvailableFolders();
}

abstract interface class ImportTargetSelectionStore {
  Future<ImportTargetSelection?> getLastImportTarget();
  Future<void> setLastImportTarget(ImportTargetSelection? selection);
}

enum ImportTargetSelectionFailure { duplicateName, invalidExisting }

final class ImportTargetSelectionException implements Exception {
  const ImportTargetSelectionException(this.failure);
  final ImportTargetSelectionFailure failure;
}

/// One Application read/write seam for the import target selector.
final class ImportTargetCatalogService {
  const ImportTargetCatalogService({
    required ImportTargetCatalogPort catalog,
    required ImportTargetSelectionStore selectionStore,
  })  : _catalog = catalog,
        _selectionStore = selectionStore;

  final ImportTargetCatalogPort _catalog;
  final ImportTargetSelectionStore _selectionStore;

  Future<List<ImportTargetSummary>> listTargets() =>
      _catalog.listImportTargets();
  Future<List<String>> listFolders() => _catalog.listAvailableFolders();

  Future<ImportTargetSelection?> restore() async {
    final saved = await _selectionStore.getLastImportTarget();
    if (saved == null) return null;
    final existing = (await listTargets())
        .where((entry) => entry.bankName == saved.bankName)
        .firstOrNull;
    if (saved.targetKind == ImportTargetKind.existing && existing == null) {
      await _selectionStore.setLastImportTarget(null);
      return null;
    }
    if (existing != null) {
      if (saved.targetKind == ImportTargetKind.proposedNew &&
          saved.folderName != existing.folderName) {
        await _selectionStore.setLastImportTarget(null);
        return null;
      }
      final selection = ImportTargetSelection(
        bankName: existing.bankName,
        folderName: existing.folderName,
        targetKind: ImportTargetKind.existing,
      );
      if (selection != saved) {
        await _selectionStore.setLastImportTarget(selection);
      }
      return selection;
    }
    return saved;
  }

  Future<ImportTargetSelection> selectExisting(ImportTargetSummary bank) async {
    final selection = ImportTargetSelection(
      bankName: bank.bankName,
      folderName: bank.folderName,
      targetKind: ImportTargetKind.existing,
    );
    await _selectionStore.setLastImportTarget(selection);
    return selection;
  }

  Future<ImportTargetSelection> proposeNew({
    required String bankName,
    String? folderName,
  }) async {
    final selection = ImportTargetSelection(
      bankName: bankName,
      folderName: folderName,
      targetKind: ImportTargetKind.proposedNew,
    );
    if ((await listTargets())
        .any((entry) => entry.bankName == selection.bankName)) {
      throw const ImportTargetSelectionException(
        ImportTargetSelectionFailure.duplicateName,
      );
    }
    await _selectionStore.setLastImportTarget(selection);
    return selection;
  }

  /// Revalidates remembered identity immediately before creating a new task.
  Future<ImportTargetSelection?> validateForDispatch(
      ImportTargetSelection selection) async {
    final existing = (await listTargets())
        .where((entry) => entry.bankName == selection.bankName)
        .firstOrNull;
    if (selection.targetKind == ImportTargetKind.existing) {
      if (existing == null) {
        await _selectionStore.setLastImportTarget(null);
        return null;
      }
      return ImportTargetSelection(
        bankName: existing.bankName,
        folderName: existing.folderName,
        targetKind: ImportTargetKind.existing,
      );
    }
    if (existing != null && existing.folderName != selection.folderName) {
      throw const ImportTargetSelectionException(
        ImportTargetSelectionFailure.duplicateName,
      );
    }
    return existing == null ? selection : selectExisting(existing);
  }
}
