import 'dart:convert';

import '../../data/models/import_question_validation.dart';
import '../../data/repositories/ai_engine_repository.dart';
import '../llm_api_client.dart';
import 'final_question_latex_audit.dart';
import 'import_question_field_policy.dart';
import 'latex_sanity_checker.dart';
import 'local_question_assembler.dart';
import 'text_question_region.dart';

class SingleQuestionRepairService {
  const SingleQuestionRepairService({
    LlmApiClient apiClient = const LlmApiClient(),
    AiEngineRepository? engineRepository,
  })  : _apiClient = apiClient,
        _engineRepository = engineRepository;

  final LlmApiClient _apiClient;
  final AiEngineRepository? _engineRepository;

  AiEngineRepository get engineRepository =>
      _engineRepository ?? (throw const AiEngineDependencyException());

  Future<LocalAssemblyResult> repair({
    required TextQuestionRegion region,
    required LocalAssemblyResult localResult,
    required bool requireAnswer,
    required ExplanationRetentionMode explanationRetentionMode,
  }) async {
    final profile = await engineRepository.getActiveTextEngine();

    if (profile == null) {
      return _appendDiagnostic(localResult, 'repair_skipped_no_active_engine');
    }

    final prompt = _buildPrompt(
      region,
      localResult,
      explanationRetentionMode,
    );

    try {
      final responseText = await _apiClient.callText(
        profile: profile,
        prompt: prompt,
        temperature: 0.0,
        jsonResponse: true,
      );

      final repaired = _parseSingleQuestionObject(responseText);
      final questionNumber = _readInt(
        repaired['question_number'] ?? repaired['number'],
      );

      if (questionNumber != region.number) {
        return _appendDiagnostic(
          localResult,
          'repair_rejected_question_number_changed',
        );
      }

      final canonical = finalizeAndAuditImportQuestion(
        _canonicalizeRepairedMap(
          repaired,
          fallback: localResult.question,
          regionNumber: region.number,
        ),
        mode: explanationRetentionMode,
      );
      final latexAudit = auditFinalQuestionLatex(canonical);
      if (!_isStructurallyValidRepair(
            latexAudit.question,
            requireAnswer: requireAnswer,
          ) ||
          latexAudit.hasUnrenderableLatex) {
        return _appendDiagnostic(
          localResult,
          'repair_rejected_structural_invalid',
        );
      }

      return LocalAssemblyResult(
        question: latexAudit.question,
        diagnostics: [
          ...localResult.diagnostics,
          'ai_repair_applied',
        ],
        repairRecommended: false,
        rejected: false,
      );
    } catch (e) {
      return _appendDiagnostics(
        localResult,
        [
          'repair_failed',
          'repair_failure_type:${e.runtimeType}',
        ],
      );
    }
  }

  String _buildPrompt(
    TextQuestionRegion region,
    LocalAssemblyResult localResult,
    ExplanationRetentionMode explanationRetentionMode,
  ) {
    final local =
        const JsonEncoder.withIndent('  ').convert(localResult.question);
    final explanationRule =
        explanationRetentionMode == ExplanationRetentionMode.allQuestionTypes
            ? '所有题型都允许保留现有来源中的 explanation；不得凭空新增或扩写。'
            : 'type=3 保留 explanation；type=0/1/2 的 explanation 必须为空。';

    return '''
你正在修复导入流程中的【第 ${region.number} 题】。

硬性规则：
1. 只能输出第 ${region.number} 题。
2. 禁止新增题目。
3. 禁止改变 question_number。
4. 禁止输出数组。
5. 禁止输出 Markdown。
6. 无法修复时，也必须返回一个 JSON object，并尽量保留原始文本。
7. options 必须是字符串数组，例如 ["A. ...", "B. ..."]。
8. 字段只能使用：
   question_number, type, content, options, standard_answer, explanation, raw_explanation
9. $explanationRule raw_explanation 只能保留现有来源文本，不得新增或扩写。

现有本地解析结果：
$local

原始题区文本：
${region.rawText}

请只返回 JSON object：
{
  "question_number": ${region.number},
  "type": 0,
  "content": "...",
  "options": ["A. ...", "B. ..."],
  "standard_answer": "...",
  "explanation": "...",
  "raw_explanation": "..."
}
''';
  }

  Map<String, dynamic> _parseSingleQuestionObject(String responseText) {
    final trimmed = responseText.trim();

    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      final objectText = _extractFirstJsonObject(trimmed);
      decoded = jsonDecode(objectText);
    }

    if (decoded is List) {
      throw FormatException('repair returned array, expected object');
    }

    if (decoded is! Map) {
      throw FormatException('repair returned non-object JSON');
    }

    return decoded.cast<String, dynamic>();
  }

  String _extractFirstJsonObject(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');

    if (start < 0 || end <= start) {
      throw FormatException('no JSON object found');
    }

    return text.substring(start, end + 1);
  }

  Map<String, dynamic> _canonicalizeRepairedMap(
    Map<String, dynamic> repaired, {
    required Map<String, dynamic> fallback,
    required int regionNumber,
  }) {
    final fallbackType = _readInt(fallback['type']) ?? 3;
    final repairedType = _readInt(repaired['type']) ?? fallbackType;
    final type = fallbackType == 0 || fallbackType == 1 || fallbackType == 2
        ? fallbackType
        : repairedType;
    final options = repaired['options'];
    final explanation = _readString(
      repaired['explanation'],
      fallback: fallback['explanation'],
    );
    final rawExplanation = _readNullableString(
      repaired['raw_explanation'],
      fallback: repaired['explanation'] ?? fallback['raw_explanation'],
    );

    return {
      'question_number': regionNumber,
      'type': type,
      'content': _readString(
        repaired['content'],
        fallback: fallback['content'],
      ),
      'options': options is List
          ? options.map((e) => e.toString()).toList(growable: false)
          : (fallback['options'] is List
              ? List<String>.from(fallback['options'] as List)
              : const <String>[]),
      'standard_answer': _readString(
        repaired['standard_answer'],
        fallback: repaired['answer'] ?? fallback['standard_answer'],
      ),
      'explanation': explanation,
      'raw_explanation': rawExplanation,
      'source': 'docx_text_ai_repair',
      'diagnostics': [
        if (fallback['diagnostics'] is List)
          ...(fallback['diagnostics'] as List).map((e) => e.toString()),
        if (repairedType != type) 'repair_type_clamped_to_fallback',
        'ai_repair_applied',
      ],
    };
  }

  bool _isStructurallyValidRepair(
    Map<String, dynamic> question, {
    required bool requireAnswer,
  }) {
    if (_readString(question['content']).isEmpty) return false;

    final type = _readInt(question['type']);
    final options = question['options'];
    if ((type == 0 || type == 1) &&
        !hasAtLeastTwoMeaningfulOptions(options is List ? options : null)) {
      return false;
    }

    if (requireAnswer &&
        (type == 0 || type == 1) &&
        !isMeaningfulAnswer(_readString(question['standard_answer']))) {
      return false;
    }

    const checker = LatexSanityChecker();
    final values = <String>[
      _readString(question['content']),
      _readString(question['standard_answer']),
      _readString(question['explanation']),
      if (options is List) ...options.map((value) => value.toString()),
    ];
    return !values.any(checker.hasDanglingDelimiters);
  }

  LocalAssemblyResult _appendDiagnostic(
    LocalAssemblyResult result,
    String diagnostic,
  ) =>
      _appendDiagnostics(result, [diagnostic]);

  LocalAssemblyResult _appendDiagnostics(
    LocalAssemblyResult result,
    List<String> diagnostics,
  ) {
    final question = Map<String, dynamic>.from(result.question);
    final oldDiagnostics = question['diagnostics'];

    question['diagnostics'] = [
      if (oldDiagnostics is List) ...oldDiagnostics.map((e) => e.toString()),
      ...diagnostics,
    ];

    return LocalAssemblyResult(
      question: question,
      diagnostics: [...result.diagnostics, ...diagnostics],
      repairRecommended: false,
      rejected: result.rejected,
    );
  }

  int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  String _readString(dynamic value, {dynamic fallback}) {
    final primary = value?.toString().trim();
    if (primary != null && primary.isNotEmpty) return primary;

    final secondary = fallback?.toString().trim();
    if (secondary != null && secondary.isNotEmpty) return secondary;

    return '';
  }

  String? _readNullableString(dynamic value, {dynamic fallback}) {
    final primary = value?.toString().trim();
    if (primary != null && primary.isNotEmpty) return primary;

    final secondary = fallback?.toString().trim();
    if (secondary != null && secondary.isNotEmpty) return secondary;

    return null;
  }
}
