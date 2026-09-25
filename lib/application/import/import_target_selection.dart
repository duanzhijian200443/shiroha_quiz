enum ImportTargetKind { existing, proposedNew }

/// Origin kind only; bankName/folderName remain the durable target authority.
const String importTargetKindMarkerKey = '_importTargetKind';

/// The next import's selection. A task copies its bank and folder at dispatch.
final class ImportTargetSelection {
  ImportTargetSelection({
    required String bankName,
    String? folderName,
    required this.targetKind,
  })  : bankName = bankName.trim(),
        folderName =
            folderName?.trim().isEmpty == true ? null : folderName?.trim() {
    if (this.bankName.isEmpty) {
      throw ArgumentError.value(bankName, 'bankName');
    }
  }

  final String bankName;
  final String? folderName;
  final ImportTargetKind targetKind;

  String get displayPath =>
      folderName == null ? bankName : '${folderName!} / $bankName';

  Map<String, Object?> toJson() => <String, Object?>{
        'bankName': bankName,
        'folderName': folderName,
        'targetKind': targetKind.name,
      };

  static ImportTargetSelection? fromJson(Object? value) {
    if (value is! Map) return null;
    final name = value['bankName'];
    final folder = value['folderName'];
    final kind = value['targetKind'];
    if (name is! String ||
        name.trim().isEmpty ||
        (folder != null && folder is! String) ||
        kind is! String) {
      return null;
    }
    final targetKind = ImportTargetKind.values
        .where((entry) => entry.name == kind)
        .firstOrNull;
    if (targetKind == null) return null;
    return ImportTargetSelection(
      bankName: name,
      folderName: folder as String?,
      targetKind: targetKind,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ImportTargetSelection &&
      other.bankName == bankName &&
      other.folderName == folderName &&
      other.targetKind == targetKind;

  @override
  int get hashCode => Object.hash(bankName, folderName, targetKind);
}
