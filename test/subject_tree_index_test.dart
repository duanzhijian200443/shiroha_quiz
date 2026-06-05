import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/subject_tree_index.dart';

void main() {
  group('SubjectTreeIndex', () {
    test('handles empty tree', () {
      final index = SubjectTreeIndex.fromRawTree({});
      expect(index.foldersByName, isEmpty);
      expect(index.banksByName, isEmpty);
      expect(index.folderByBankName, isEmpty);
      expect(index.availableBanksAndFolders, isEmpty);
      expect(index.availableFolders, isEmpty);
    });

    test('ignores empty folder and bank names', () {
      final rawTree = {
        '   ': [
          {'name': 'Valid Bank'}
        ], // empty folder
        'Valid Folder': [
          {'name': '  '}, // empty bank
          {'name': null}, // null bank
          {'name': 'Actual Bank'}
        ],
      };

      final index = SubjectTreeIndex.fromRawTree(rawTree);
      expect(index.foldersByName.keys, ['Valid Folder']);
      expect(index.banksByName.keys, ['Actual Bank']);
    });

    test('supports fallback from bank_name to name', () {
      final rawTree = {
        'Folder': [
          {'bank_name': 'Bank 1'},
          {'name': 'Bank 2'},
          {'name': 'Bank 3', 'bank_name': 'Ignored'},
        ],
      };

      final index = SubjectTreeIndex.fromRawTree(rawTree);
      expect(index.banksByName.keys.toSet(), {'Bank 1', 'Bank 2', 'Bank 3'});
    });

    test('reads count defensively from int, string, or null', () {
      final rawTree = {
        'Folder': [
          {'name': 'B1', 'count': 42},
          {'name': 'B2', 'count': '99'},
          {'name': 'B3', 'count': null},
          {'name': 'B4'}, // missing count
        ],
      };

      final index = SubjectTreeIndex.fromRawTree(rawTree);
      expect(index.banksByName['B1']?.count, 42);
      expect(index.banksByName['B2']?.count, 99);
      expect(index.banksByName['B3']?.count, 0);
      expect(index.banksByName['B4']?.count, 0);
    });

    test('filters default subject and uncategorized folder from candidates',
        () {
      final rawTree = {
        SubjectTreeIndex.defaultSubjectName: [
          {'name': 'Bank 1'},
        ],
        SubjectTreeIndex.uncategorizedFolderName: [
          {'name': 'Bank 2'},
        ],
        'Normal Folder': [
          {'name': 'Bank 3'},
        ],
      };

      final index = SubjectTreeIndex.fromRawTree(rawTree);

      expect(
        index.availableBanksAndFolders,
        ['Bank 1', 'Bank 2', 'Bank 3', 'Normal Folder'],
      );

      expect(
        index.availableFolders,
        ['Normal Folder', SubjectTreeIndex.defaultSubjectName],
      );

      expect(
          index.foldersByName[SubjectTreeIndex.defaultSubjectName]
              ?.isDefaultSubject,
          isTrue);
      expect(
          index.foldersByName[SubjectTreeIndex.uncategorizedFolderName]
              ?.isUncategorized,
          isTrue);
    });

    test('handles duplicate bank names stably', () {
      final rawTree = {
        'Folder A': [
          {'name': 'Shared Bank', 'count': 10},
        ],
        'Folder B': [
          {'name': 'Shared Bank', 'count': 20},
        ],
      };

      final index = SubjectTreeIndex.fromRawTree(rawTree);
      expect(index.banksByName.length, 1);
      // It should keep the latest one encountered
      expect(index.banksByName['Shared Bank']?.count, 20);
      expect(index.banksByName['Shared Bank']?.folderName, 'Folder B');

      expect(
        index.availableBanksAndFolders,
        ['Folder A', 'Folder B', 'Shared Bank'],
      );
    });

    test('returns unmodifiable collections', () {
      final rawTree = {
        'Folder': [
          {'name': 'Bank'}
        ]
      };

      final index = SubjectTreeIndex.fromRawTree(rawTree);

      expect(
        () => (index.foldersByName as Map).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (index.banksByName as Map).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (index.folderByBankName as Map).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (index.availableBanksAndFolders as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (index.availableFolders as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (index.foldersByName['Folder']?.banks as List).clear(),
        throwsUnsupportedError,
      );
    });

    test('copyWithBanks returns a folder with immutable bank list', () {
      final node = SubjectFolderNode(
        name: 'Original',
        banks: const [],
        isUncategorized: false,
        isDefaultSubject: false,
      );

      final banks = [
        QuestionBankNode(name: 'Bank', count: 1, folderName: 'Original'),
      ];

      final copy = node.copyWithBanks(banks);

      expect(copy.name, 'Original');
      expect(copy.banks.length, 1);
      expect(copy.banks.first.name, 'Bank');
      expect(() => (copy.banks as List).clear(), throwsUnsupportedError);
    });
  });
}
