import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/study_plan_bank_catalog.dart';

void main() {
  group('StudyPlanBankCatalog & Models', () {
    test('handles empty banks array', () {
      final catalog = StudyPlanBankCatalog.fromBanks([]);
      expect(catalog.banks, isEmpty);
      expect(catalog.groups, isEmpty);
      expect(catalog.banksByName, isEmpty);
    });

    test(
        'sorts priority folder first and uncategorized last, others alphabetically',
        () {
      final banks = [
        StudyPlanBank.fromLegacyMap(
            {'bank_name': 'Bank A', 'folder_name': 'Folder Z'}),
        StudyPlanBank.fromLegacyMap({
          'bank_name': 'Bank B',
          'folder_name': StudyPlanBankCatalog.uncategorizedFolderName
        }),
        StudyPlanBank.fromLegacyMap(
            {'bank_name': 'Bank C', 'folder_name': 'Folder A'}),
        StudyPlanBank.fromLegacyMap({
          'bank_name': 'Bank D',
          'folder_name': StudyPlanBankCatalog.priorityFolderName
        }),
      ];

      final catalog = StudyPlanBankCatalog.fromBanks(banks);
      final groups = catalog.groups;

      expect(groups.length, 4);
      expect(groups[0].folderName, StudyPlanBankCatalog.priorityFolderName);
      expect(groups[1].folderName, 'Folder A');
      expect(groups[2].folderName, 'Folder Z');
      expect(
          groups[3].folderName, StudyPlanBankCatalog.uncategorizedFolderName);
    });

    test('banksByName allows O(1) retrieval', () {
      final banks = [
        StudyPlanBank.fromLegacyMap(
            {'bank_name': 'Target Bank', 'folder_name': 'Folder'}),
      ];
      final catalog = StudyPlanBankCatalog.fromBanks(banks);

      final bank = catalog.bankByName('Target Bank');
      expect(bank, isNotNull);
      expect(bank?.bankName, 'Target Bank');

      expect(catalog.bankByName('Nonexistent'), isNull);
    });

    test('progress calculates safely with boundaries', () {
      // 0 total
      final bank1 = StudyPlanBank.fromLegacyMap(
          {'bank_name': 'B1', 'total': 0, 'mastered': 0});
      expect(bank1.progress, 0.0);

      // mastered > total
      final bank2 = StudyPlanBank.fromLegacyMap(
          {'bank_name': 'B2', 'total': 10, 'mastered': 20});
      expect(bank2.progress, 1.0);
      expect(bank2.unmastered, 0);

      // normal
      final bank3 = StudyPlanBank.fromLegacyMap(
          {'bank_name': 'B3', 'total': 100, 'mastered': 25});
      expect(bank3.progress, 0.25);
    });

    test('dailyQuota <= 0 does not cause division by zero', () {
      final bank1 = StudyPlanBank.fromLegacyMap(
          {'bank_name': 'B1', 'total': 100, 'mastered': 0, 'daily_quota': 0});
      expect(bank1.dailyQuota, 40); // default
      expect(bank1.daysLeft, 3); // ceil(100 / 40)

      final bank2 = StudyPlanBank.fromLegacyMap(
          {'bank_name': 'B2', 'total': 100, 'mastered': 0, 'daily_quota': -10});
      expect(bank2.dailyQuota, 40);
    });

    test('handles duplicate bank names stably by keeping the first', () {
      final banks = [
        StudyPlanBank.fromLegacyMap({
          'bank_name': 'Shared Bank',
          'folder_name': 'Folder A',
          'total': 10
        }),
        StudyPlanBank.fromLegacyMap({
          'bank_name': 'Shared Bank',
          'folder_name': 'Folder B',
          'total': 20
        }),
      ];

      final catalog = StudyPlanBankCatalog.fromBanks(banks);
      expect(catalog.banks.length, 1);
      expect(catalog.bankByName('Shared Bank')?.folderName, 'Folder A');
      expect(catalog.bankByName('Shared Bank')?.total, 10);
    });

    test('returns unmodifiable collections', () {
      final banks = [
        StudyPlanBank.fromLegacyMap(
            {'bank_name': 'Bank', 'folder_name': 'Folder'})
      ];
      final catalog = StudyPlanBankCatalog.fromBanks(banks);

      expect(() => (catalog.banks as List).clear(), throwsUnsupportedError);
      expect(() => (catalog.groups as List).clear(), throwsUnsupportedError);
      expect(
          () => (catalog.banksByName as Map).clear(), throwsUnsupportedError);
      expect(() => (catalog.groups.first.banks as List).clear(),
          throwsUnsupportedError);
    });
  });
}
