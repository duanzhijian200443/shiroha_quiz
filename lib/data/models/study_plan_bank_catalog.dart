import 'dart:collection';
import 'dart:math';

class StudyPlanBank {
  const StudyPlanBank({
    required this.bankName,
    required this.folderName,
    required this.total,
    required this.mastered,
    required this.dailyQuota,
    required this.daysLeft,
  });

  final String bankName;
  final String folderName;
  final int total;
  final int mastered;
  final int dailyQuota;
  final int daysLeft;

  int get unmastered => max(0, total - mastered);

  double get progress {
    if (total <= 0) return 0.0;
    return (mastered / total).clamp(0.0, 1.0);
  }

  bool get isGlobalWrongBook => bankName == '错题本';

  Map<String, dynamic> toLegacyMap() {
    return {
      'bank_name': bankName,
      'folder_name': folderName,
      'total': total,
      'mastered': mastered,
      'daily_quota': dailyQuota,
      'days_left': daysLeft,
    };
  }

  factory StudyPlanBank.fromLegacyMap(Map<String, dynamic> map) {
    final rawBankName = map['bank_name']?.toString().trim() ?? '';
    final rawFolderName = map['folder_name']?.toString().trim() ?? '';

    final bankName = rawBankName.isEmpty ? '未知题库' : rawBankName;
    final folderName = rawFolderName.isEmpty
        ? StudyPlanBankCatalog.uncategorizedFolderName
        : rawFolderName;

    final total = max(0, _readInt(map['total']) ?? 0);
    final mastered = max(0, _readInt(map['mastered']) ?? 0);

    int dailyQuota = _readInt(map['daily_quota']) ?? 40;
    if (dailyQuota <= 0) dailyQuota = 40;

    final unmastered = max(0, total - mastered);
    final daysLeft = (unmastered / dailyQuota).ceil();

    return StudyPlanBank(
      bankName: bankName,
      folderName: folderName,
      total: total,
      mastered: mastered,
      dailyQuota: dailyQuota,
      daysLeft: daysLeft,
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

class StudyPlanFolderGroup {
  const StudyPlanFolderGroup({
    required this.folderName,
    required this.banks,
  });

  final String folderName;
  final List<StudyPlanBank> banks;

  bool containsBank(String bankName) {
    return banks.any((b) => b.bankName == bankName);
  }
}

class StudyPlanBankCatalog {
  const StudyPlanBankCatalog._({
    required this.banks,
    required this.groups,
    required this.banksByName,
  });

  static const uncategorizedFolderName = '📁 未分类题库';
  static const priorityFolderName = '🚨 重点突破';

  final List<StudyPlanBank> banks;
  final List<StudyPlanFolderGroup> groups;
  final Map<String, StudyPlanBank> banksByName;

  StudyPlanBank? bankByName(String bankName) => banksByName[bankName];

  factory StudyPlanBankCatalog.fromBanks(Iterable<StudyPlanBank> bankIterable) {
    final banksByName = <String, StudyPlanBank>{};
    final validBanks = <StudyPlanBank>[];

    int compareFolder(String a, String b) {
      if (a == priorityFolderName && b != priorityFolderName) return -1;
      if (b == priorityFolderName && a != priorityFolderName) return 1;
      if (a == uncategorizedFolderName && b != uncategorizedFolderName)
        return 1;
      if (b == uncategorizedFolderName && a != uncategorizedFolderName)
        return -1;
      return a.compareTo(b);
    }

    final groupsMap = SplayTreeMap<String, List<StudyPlanBank>>(compareFolder);

    for (final bank in bankIterable) {
      if (bank.bankName == '未知题库' || bank.bankName.isEmpty) continue;

      final existing = banksByName[bank.bankName];
      if (existing != null)
        continue; // Deduplicate by keeping the first encountered

      banksByName[bank.bankName] = bank;
      validBanks.add(bank);

      groupsMap.putIfAbsent(bank.folderName, () => []).add(bank);
    }

    final groups = groupsMap.entries.map((e) {
      return StudyPlanFolderGroup(
        folderName: e.key,
        banks: UnmodifiableListView(e.value),
      );
    }).toList();

    return StudyPlanBankCatalog._(
      banks: UnmodifiableListView(validBanks),
      groups: UnmodifiableListView(groups),
      banksByName: UnmodifiableMapView(banksByName),
    );
  }
}
