import 'dart:math' as math;

import 'document_signals.dart';

class ImportQualityGateInput {
  const ImportQualityGateInput({
    required this.regionCount,
    required this.actualQuestionCount,
    required this.maxQuestionNumberDetected,
    required this.answerCount,
    required this.documentSignals,
    required this.criticalDiagnostics,
  });

  final int regionCount;
  final int actualQuestionCount;
  final int maxQuestionNumberDetected;
  final int answerCount;
  final DocumentSignals? documentSignals;
  final List<String> criticalDiagnostics;
}

class ImportQualityGateResult {
  const ImportQualityGateResult({
    required this.blocked,
    required this.severity,
    required this.expectedCount,
    required this.actualCount,
    required this.completionRate,
    required this.warnings,
    required this.diagnostics,
  });

  final bool blocked;
  final String severity;
  final int expectedCount;
  final int actualCount;
  final double completionRate;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;
}

class ImportQualityGate {
  const ImportQualityGate();

  ImportQualityGateResult evaluateDocx(ImportQualityGateInput input) {
    final signalQuestionCount = input.documentSignals?.questionMarkerCount ?? 0;

    final expectedCount = [
      input.regionCount,
      input.maxQuestionNumberDetected,
      input.answerCount,
      signalQuestionCount,
    ].fold<int>(0, math.max);

    final actualCount = input.actualQuestionCount;

    final completionRate = expectedCount == 0
        ? 0.0
        : actualCount / expectedCount;

    if (input.regionCount == 0) {
      return _blocked(
        severity: 'regionizer_empty',
        expectedCount: expectedCount,
        actualCount: actualCount,
        completionRate: completionRate,
        warnings: const [
          'DOCX 未检测到稳定题号骨架，已拒绝全文 AI 兜底。',
        ],
        extra: {
          'policy': 'no_full_text_ai_fallback_for_docx',
        },
      );
    }

    if (expectedCount >= 10 && actualCount < expectedCount * 0.8) {
      return _blocked(
        severity: 'critical_under_parse',
        expectedCount: expectedCount,
        actualCount: actualCount,
        completionRate: completionRate,
        warnings: [
          'DOCX 解析完整率过低：检测到 $expectedCount 个题号信号，仅生成 $actualCount 题。',
        ],
      );
    }

    if (input.criticalDiagnostics.isNotEmpty) {
      return _blocked(
        severity: 'critical_diagnostics',
        expectedCount: expectedCount,
        actualCount: actualCount,
        completionRate: completionRate,
        warnings: [
          'DOCX 解析存在严重结构错误：${input.criticalDiagnostics.join('；')}',
        ],
        extra: {
          'criticalDiagnostics': input.criticalDiagnostics,
        },
      );
    }

    return ImportQualityGateResult(
      blocked: false,
      severity: 'ok',
      expectedCount: expectedCount,
      actualCount: actualCount,
      completionRate: completionRate,
      warnings: const [],
      diagnostics: {
        'blocked': false,
        'severity': 'ok',
        'expectedCount': expectedCount,
        'actualCount': actualCount,
        'completionRate': completionRate,
      },
    );
  }

  ImportQualityGateResult _blocked({
    required String severity,
    required int expectedCount,
    required int actualCount,
    required double completionRate,
    required List<String> warnings,
    Map<String, dynamic> extra = const {},
  }) {
    return ImportQualityGateResult(
      blocked: true,
      severity: severity,
      expectedCount: expectedCount,
      actualCount: actualCount,
      completionRate: completionRate,
      warnings: warnings,
      diagnostics: {
        'blocked': true,
        'severity': severity,
        'expectedCount': expectedCount,
        'actualCount': actualCount,
        'completionRate': completionRate,
        ...extra,
      },
    );
  }
}
