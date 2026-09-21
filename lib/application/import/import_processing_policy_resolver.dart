import 'import_advanced_preferences.dart';

/// Provider-safe concurrency ceilings for OCR backends.
///
/// These are named safety constants, not user-facing settings: the UI never
/// surfaces the numbers, and they may only be raised after real-provider
/// characterization proves a higher ceiling is safe.
abstract final class OcrProviderSafeLimits {
  static const int zhipuGlmOcr = 4;
}

/// The resolved execution policy for one import task.
class ImportProcessingPolicy {
  const ImportProcessingPolicy({required this.effectiveOcrConcurrency});

  /// The per-task OCR parallelism written into `ImportParseRequest`
  /// and consumed by the OCR pipeline scheduler.
  final int effectiveOcrConcurrency;
}

/// Maps an [ImportProcessingStrategy] to a concrete execution policy.
///
/// Pure and dependency-free so the mapping is unit-testable and can never
/// drift between the entry UI, the pipeline, and the retry path.
class ImportProcessingPolicyResolver {
  const ImportProcessingPolicyResolver();

  ImportProcessingPolicy resolve(
    ImportProcessingStrategy strategy, {
    int providerSafeLimit = OcrProviderSafeLimits.zhipuGlmOcr,
  }) {
    final strategyCap = switch (strategy) {
      ImportProcessingStrategy.stability => 1,
      ImportProcessingStrategy.automatic => 2,
      ImportProcessingStrategy.speed => 4,
    };
    final safeLimit = providerSafeLimit < 1 ? 1 : providerSafeLimit;
    return ImportProcessingPolicy(
      effectiveOcrConcurrency:
          strategyCap < safeLimit ? strategyCap : safeLimit,
    );
  }
}
