import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import/import_advanced_preferences.dart';
import 'package:shiroha_quiz/application/import/import_processing_policy_resolver.dart';

void main() {
  const resolver = ImportProcessingPolicyResolver();

  group('ImportProcessingPolicyResolver', () {
    test('stability always resolves to single-file execution', () {
      for (final limit in <int>[1, 2, 4, 8]) {
        expect(
          resolver
              .resolve(
                ImportProcessingStrategy.stability,
                providerSafeLimit: limit,
              )
              .effectiveOcrConcurrency,
          1,
          reason: 'stability must stay serial at safe limit $limit',
        );
      }
    });

    test('automatic resolves to two within the provider-safe limit', () {
      expect(
        resolver
            .resolve(ImportProcessingStrategy.automatic, providerSafeLimit: 4)
            .effectiveOcrConcurrency,
        2,
      );
      expect(
        resolver
            .resolve(ImportProcessingStrategy.automatic, providerSafeLimit: 1)
            .effectiveOcrConcurrency,
        1,
        reason: 'the provider-safe limit always wins over the strategy cap',
      );
    });

    test('speed raises concurrency up to the provider-safe limit', () {
      expect(
        resolver
            .resolve(ImportProcessingStrategy.speed, providerSafeLimit: 4)
            .effectiveOcrConcurrency,
        4,
      );
      expect(
        resolver
            .resolve(ImportProcessingStrategy.speed, providerSafeLimit: 2)
            .effectiveOcrConcurrency,
        2,
      );
      expect(
        resolver
            .resolve(ImportProcessingStrategy.speed, providerSafeLimit: 1)
            .effectiveOcrConcurrency,
        1,
      );
    });

    test('default limit is the zhipu provider-safe ceiling', () {
      expect(
        resolver
            .resolve(ImportProcessingStrategy.speed)
            .effectiveOcrConcurrency,
        OcrProviderSafeLimits.zhipuGlmOcr,
      );
      expect(
        resolver
            .resolve(ImportProcessingStrategy.automatic)
            .effectiveOcrConcurrency,
        2,
      );
    });

    test('a non-positive safe limit still yields a runnable budget', () {
      expect(
        resolver
            .resolve(ImportProcessingStrategy.speed, providerSafeLimit: 0)
            .effectiveOcrConcurrency,
        1,
      );
    });
  });

  group('ImportAdvancedPreferences', () {
    test('defaults match the frozen product defaults', () {
      const preferences = ImportAdvancedPreferences();
      expect(
          preferences.processingStrategy, ImportProcessingStrategy.automatic);
      expect(preferences.autoRetryEnabled, isTrue);
      expect(preferences.retainUnresolvedFragments, isTrue);
    });

    test('json round trip preserves every field', () {
      const preferences = ImportAdvancedPreferences(
        processingStrategy: ImportProcessingStrategy.speed,
        autoRetryEnabled: false,
        retainUnresolvedFragments: false,
      );
      expect(
        ImportAdvancedPreferences.fromJson(preferences.toJson()),
        preferences,
      );
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
          'processingStrategy': 'stability',
        }).processingStrategy,
        ImportProcessingStrategy.stability,
      );
    });

    test('copyWith replaces only the requested fields', () {
      const preferences = ImportAdvancedPreferences();
      final updated = preferences.copyWith(
        processingStrategy: ImportProcessingStrategy.stability,
      );
      expect(updated.processingStrategy, ImportProcessingStrategy.stability);
      expect(updated.autoRetryEnabled, preferences.autoRetryEnabled);
      expect(
        updated.retainUnresolvedFragments,
        preferences.retainUnresolvedFragments,
      );
    });
  });
}
