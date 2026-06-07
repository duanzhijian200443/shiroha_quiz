import 'package:flutter/foundation.dart';

import 'answer_block_matcher.dart';
import 'import_quality_gate.dart';
import 'local_question_assembler.dart';
import 'single_question_repair_service.dart';
import 'text_question_regionizer.dart';
import 'document_signals.dart';

class DocxTextFirstParseResult {
  const DocxTextFirstParseResult({
    required this.questions,
    required this.warnings,
    required this.diagnostics,
    required this.blocked,
  });

  final List<Map<String, dynamic>> questions;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;
  final bool blocked;
}

class DocxTextFirstParseService {
  const DocxTextFirstParseService({
    AnswerBlockMatcher answerMatcher = const AnswerBlockMatcher(),
    TextQuestionRegionizer regionizer = const TextQuestionRegionizer(),
    LocalQuestionAssembler assembler = const LocalQuestionAssembler(),
    SingleQuestionRepairService repairService = const SingleQuestionRepairService(),
    ImportQualityGate qualityGate = const ImportQualityGate(),
  })  : _answerMatcher = answerMatcher,
        _regionizer = regionizer,
        _assembler = assembler,
        _repairService = repairService,
        _qualityGate = qualityGate;

  final AnswerBlockMatcher _answerMatcher;
  final TextQuestionRegionizer _regionizer;
  final LocalQuestionAssembler _assembler;
  final SingleQuestionRepairService _repairService;
  final ImportQualityGate _qualityGate;

  Future<DocxTextFirstParseResult> parseDocxText({
    required String rawText,
    required String sourceName,
    String? taskId,
    DocumentSignals? documentSignals,
  }) async {
    debugPrint('🧱 [DOCX Text-First] 启动确定性结构解析: $sourceName');
    debugPrint('🧱 [DOCX Text-First] rawTextLength=${rawText.length}');

    final diagnostics = <String, dynamic>{
      'sourceName': sourceName,
      'rawTextLength': rawText.length,
      'rawTextLineCount': rawText.split('\n').length,
      'rawTextPreview':
          rawText.length > 8000 ? rawText.substring(0, 8000) : rawText,
    };

    final answerSplit = _answerMatcher.splitAnswerBlock(rawText);

    final regionResult =
        _regionizer.split(answerSplit.questionBodyText, answerSplit.answers);

    diagnostics['regionizer'] = regionResult.diagnostics;
    diagnostics['answerCount'] = answerSplit.answers.length;

    final maxQuestionNumberDetected =
        (regionResult.diagnostics['maxQuestionNumberDetected'] as int?) ?? 0;

    debugPrint(
      '🧱 [DOCX Text-First] regions=${regionResult.regions.length}, '
      'answers=${answerSplit.answers.length}, '
      'maxNo=$maxQuestionNumberDetected',
    );

    if (regionResult.regions.isEmpty) {
      final gate = _qualityGate.evaluateDocx(
        ImportQualityGateInput(
          regionCount: 0,
          actualQuestionCount: 0,
          maxQuestionNumberDetected: maxQuestionNumberDetected,
          answerCount: answerSplit.answers.length,
          documentSignals: documentSignals,
          criticalDiagnostics: const [],
        ),
      );

      diagnostics['qualityGate'] = gate.diagnostics;

      return DocxTextFirstParseResult(
        questions: const [],
        warnings: gate.warnings,
        diagnostics: diagnostics,
        blocked: true,
      );
    }

    final questionsByNumber = <int, Map<String, dynamic>>{};
    final criticalDiagnostics = <String>[];
    var repairCount = 0;
    var rejectedCount = 0;

    for (final region in regionResult.regions) {
      final answer = answerSplit.answers[region.number];

      final enrichedRegion = region.copyWith(answerText: answer);

      var assembly = _assembler.assemble(enrichedRegion);

      if (assembly.rejected) {
        rejectedCount++;
        criticalDiagnostics.add('region_${region.number}_rejected');
        continue;
      }

      if (assembly.repairRecommended) {
        repairCount++;
        assembly = await _repairService.repair(
          region: enrichedRegion,
          localResult: assembly,
        );
      }

      final questionNumber = _readQuestionNumber(assembly.question);
      if (questionNumber == null) {
        criticalDiagnostics
            .add('region_${region.number}_missing_question_number');
        continue;
      }

      if (questionNumber != region.number) {
        criticalDiagnostics.add('region_${region.number}_number_mismatch');
        continue;
      }

      final existing = questionsByNumber[questionNumber];
      if (existing == null ||
          _contentLength(assembly.question) > _contentLength(existing)) {
        questionsByNumber[questionNumber] = assembly.question;
      }
    }

    final questions = questionsByNumber.values.toList()
      ..sort((a, b) {
        final ai = _readQuestionNumber(a) ?? 0;
        final bi = _readQuestionNumber(b) ?? 0;
        return ai.compareTo(bi);
      });

    final gate = _qualityGate.evaluateDocx(
      ImportQualityGateInput(
        regionCount: regionResult.regions.length,
        actualQuestionCount: questions.length,
        maxQuestionNumberDetected: maxQuestionNumberDetected,
        answerCount: answerSplit.answers.length,
        documentSignals: documentSignals,
        criticalDiagnostics: criticalDiagnostics,
      ),
    );

    diagnostics['assembly'] = {
      'questionCount': questions.length,
      'repairCount': repairCount,
      'rejectedCount': rejectedCount,
      'criticalDiagnostics': criticalDiagnostics,
    };

    diagnostics['qualityGate'] = gate.diagnostics;

    debugPrint(
      '🧱 [DOCX Text-First] assembled=${questions.length}, '
      'repair=$repairCount, rejected=$rejectedCount, '
      'blocked=${gate.blocked}, severity=${gate.severity}',
    );

    return DocxTextFirstParseResult(
      questions: questions,
      warnings: gate.warnings,
      diagnostics: diagnostics,
      blocked: gate.blocked,
    );
  }

  int? _readQuestionNumber(Map<String, dynamic> question) {
    final value = question['question_number'] ?? question['number'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  int _contentLength(Map<String, dynamic> question) {
    return question['content']?.toString().trim().length ?? 0;
  }
}
