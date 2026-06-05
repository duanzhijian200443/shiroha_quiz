import 'dart:collection';

class QuestionBankNode {
  const QuestionBankNode({
    required this.name,
    required this.count,
    required this.folderName,
  });

  final String name;
  final int count;
  final String folderName;
}

class SubjectFolderNode {
  const SubjectFolderNode({
    required this.name,
    required this.banks,
    required this.isUncategorized,
    required this.isDefaultSubject,
  });

  final String name;
  final List<QuestionBankNode> banks;
  final bool isUncategorized;
  final bool isDefaultSubject;
}

class SubjectTreeIndex {
  const SubjectTreeIndex._({
    required this.foldersByName,
    required this.banksByName,
    required this.folderByBankName,
    required this.availableBanksAndFolders,
    required this.availableFolders,
  });

  static const defaultSubjectName = '默认学科';
  static const uncategorizedFolderName = '📁 未分类题库';

  final Map<String, SubjectFolderNode> foldersByName;
  final Map<String, QuestionBankNode> banksByName;
  final Map<String, String> folderByBankName;
  final List<String> availableBanksAndFolders;
  final List<String> availableFolders;

  factory SubjectTreeIndex.fromRawTree(
      Map<String, List<Map<String, dynamic>>> rawTree) {
    final splayFoldersByName = SplayTreeMap<String, SubjectFolderNode>();
    final banksByName = <String, QuestionBankNode>{};
    final folderByBankName = <String, String>{};
    final banksAndFoldersSet = SplayTreeSet<String>();
    final foldersSet = SplayTreeSet<String>();

    for (final entry in rawTree.entries) {
      final folderName = entry.key.trim();
      if (folderName.isEmpty) continue;

      final banks = <QuestionBankNode>[];

      for (final bank in entry.value) {
        final bankName = (bank['name'] ?? bank['bank_name'])?.toString().trim();
        if (bankName == null || bankName.isEmpty) continue;

        final count = _readInt(bank['count']) ?? 0;
        final bankNode = QuestionBankNode(
          name: bankName,
          count: count,
          folderName: folderName,
        );

        banks.add(bankNode);
        banksByName[bankName] = bankNode;
        folderByBankName[bankName] = folderName;
        banksAndFoldersSet.add(bankName);
      }

      splayFoldersByName[folderName] = SubjectFolderNode(
        name: folderName,
        banks: UnmodifiableListView(banks),
        isUncategorized: folderName == uncategorizedFolderName,
        isDefaultSubject: folderName == defaultSubjectName,
      );

      banksAndFoldersSet.add(folderName);
      foldersSet.add(folderName);
    }

    banksAndFoldersSet.remove(defaultSubjectName);
    banksAndFoldersSet.remove(uncategorizedFolderName);
    foldersSet.remove(uncategorizedFolderName);

    return SubjectTreeIndex._(
      foldersByName: UnmodifiableMapView(splayFoldersByName),
      banksByName: UnmodifiableMapView(banksByName),
      folderByBankName: UnmodifiableMapView(folderByBankName),
      availableBanksAndFolders:
          UnmodifiableListView(banksAndFoldersSet.toList()),
      availableFolders: UnmodifiableListView(foldersSet.toList()),
    );
  }

  static int? _readInt(dynamic value) {
    return switch (value) {
      final int raw => raw,
      final num raw => raw.toInt(),
      final String raw => int.tryParse(raw.trim()),
      _ => null,
    };
  }
}
