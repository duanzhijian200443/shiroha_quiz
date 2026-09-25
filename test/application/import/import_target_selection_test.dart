import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import/import_target_selection.dart';

void main() {
  test('normalizes, round trips, and rejects malformed selections', () {
    final target = ImportTargetSelection(
      bankName: ' 考研数学一 ',
      folderName: ' 数学 ',
      targetKind: ImportTargetKind.proposedNew,
    );
    expect(target.bankName, '考研数学一');
    expect(target.folderName, '数学');
    expect(target.displayPath, '数学 / 考研数学一');
    expect(ImportTargetSelection.fromJson(target.toJson()), target);
    expect(ImportTargetSelection.fromJson({'bankName': ''}), isNull);
    expect(
        ImportTargetSelection.fromJson({'bankName': 'A', 'targetKind': 'bad'}),
        isNull);
    expect(
      ImportTargetSelection(
        bankName: 'A',
        folderName: ' ',
        targetKind: ImportTargetKind.existing,
      ).folderName,
      isNull,
    );
  });
}
