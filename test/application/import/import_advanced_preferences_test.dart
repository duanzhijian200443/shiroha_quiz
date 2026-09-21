import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import/import_advanced_preferences.dart';

void main() {
  group('ImportAdvancedPreferences', () {
    test('defaults to a budget inside the supported slider range', () {
      expect(ImportAdvancedPreferences.defaults.ocrTaskConcurrency, 2);
      expect(ImportAdvancedPreferences.minOcrTaskConcurrency, 1);
      expect(ImportAdvancedPreferences.maxOcrTaskConcurrency, 10);
    });

    test('every slider value survives unchanged', () {
      for (var value = ImportAdvancedPreferences.minOcrTaskConcurrency;
          value <= ImportAdvancedPreferences.maxOcrTaskConcurrency;
          value++) {
        expect(
          ImportAdvancedPreferences(ocrTaskConcurrency: value)
              .effectiveOcrTaskConcurrency,
          value,
        );
      }
    });

    test('out-of-range budgets are clamped in both directions', () {
      expect(
        ImportAdvancedPreferences(ocrTaskConcurrency: 0)
            .effectiveOcrTaskConcurrency,
        1,
      );
      expect(
        ImportAdvancedPreferences(ocrTaskConcurrency: -5)
            .effectiveOcrTaskConcurrency,
        1,
      );
      expect(
        ImportAdvancedPreferences(ocrTaskConcurrency: 11)
            .effectiveOcrTaskConcurrency,
        10,
      );
      expect(
        ImportAdvancedPreferences(ocrTaskConcurrency: 999)
            .effectiveOcrTaskConcurrency,
        10,
      );
    });

    test('a persisted payload is always inside the supported range', () {
      expect(
        ImportAdvancedPreferences(ocrTaskConcurrency: 0).toJson(),
        containsPair('ocrTaskConcurrency', 1),
      );
      expect(
        ImportAdvancedPreferences(ocrTaskConcurrency: 99).toJson(),
        containsPair('ocrTaskConcurrency', 10),
      );
      expect(
        ImportAdvancedPreferences.fromJson(const <String, dynamic>{
          'ocrTaskConcurrency': 0,
        }).ocrTaskConcurrency,
        1,
      );
      expect(
        ImportAdvancedPreferences.fromJson(const <String, dynamic>{
          'ocrTaskConcurrency': 50,
        }).ocrTaskConcurrency,
        10,
      );
      expect(
        ImportAdvancedPreferences.fromJson(const <String, dynamic>{
          'ocrTaskConcurrency': 12,
        }).ocrTaskConcurrency,
        10,
      );
    });

    test('json round trip preserves the budget', () {
      for (final value in <int>[1, 2, 5, 10]) {
        final preferences =
            ImportAdvancedPreferences(ocrTaskConcurrency: value);
        expect(ImportAdvancedPreferences.fromJson(preferences.toJson()),
            preferences);
        expect(
          ImportAdvancedPreferences.fromJson(preferences.toJson())
              .ocrTaskConcurrency,
          value,
        );
      }
    });

    test('round trip preserves the reserved exception-handling toggles', () {
      const preferences = ImportAdvancedPreferences(
        ocrTaskConcurrency: 3,
        autoRetryEnabled: false,
        retainUnresolvedFragments: false,
      );
      expect(ImportAdvancedPreferences.fromJson(preferences.toJson()),
          preferences);
    });

    test('migrates the retired processing strategy vocabulary', () {
      const migrated = <String, int>{
        'stability': 1,
        'automatic': 2,
        'speed': 4,
      };
      for (final entry in migrated.entries) {
        expect(
          ImportAdvancedPreferences.fromJson(<String, dynamic>{
            'processingStrategy': entry.key,
          }).ocrTaskConcurrency,
          entry.value,
          reason: '${entry.key} must keep its original intent',
        );
      }
    });

    test('the stored budget wins over a leftover legacy key', () {
      expect(
        ImportAdvancedPreferences.fromJson(const <String, dynamic>{
          'ocrTaskConcurrency': 7,
          'processingStrategy': 'speed',
        }).ocrTaskConcurrency,
        7,
      );
    });

    test('the retired key is no longer written back', () {
      final json = ImportAdvancedPreferences(ocrTaskConcurrency: 4).toJson();
      expect(json.containsKey('processingStrategy'), isFalse);
      expect(json, containsPair('ocrTaskConcurrency', 4));
    });

    test('decode tolerates missing, unknown and malformed values', () {
      expect(
        ImportAdvancedPreferences.fromJson(const <String, dynamic>{}),
        ImportAdvancedPreferences.defaults,
      );
      expect(
        ImportAdvancedPreferences.fromJson(const <String, dynamic>{
          'processingStrategy': 'not-a-strategy',
          'autoRetryEnabled': 'yes',
        }),
        ImportAdvancedPreferences.defaults,
      );
      expect(
        ImportAdvancedPreferences.fromJson(const <String, dynamic>{
          'ocrTaskConcurrency': 'fast',
        }),
        ImportAdvancedPreferences.defaults,
      );
      expect(
        ImportAdvancedPreferences.fromJson(const <String, dynamic>{
          'ocrTaskConcurrency': 4.6,
        }).ocrTaskConcurrency,
        5,
      );
    });

    test('copyWith replaces only the requested field', () {
      const preferences = ImportAdvancedPreferences(
        autoRetryEnabled: false,
        retainUnresolvedFragments: false,
      );
      final updated = preferences.copyWith(ocrTaskConcurrency: 8);
      expect(updated.ocrTaskConcurrency, 8);
      expect(updated.autoRetryEnabled, isFalse);
      expect(updated.retainUnresolvedFragments, isFalse);
    });
  });
}
