import 'dart:convert';

import '../../data/repositories/ai_engine_repository.dart';
import '../llm_api_client.dart';
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
      _engineRepository ?? AiEngineRepository.instance;

  Future<LocalAssemblyResult> repair({
    required TextQuestionRegion region,
    required LocalAssemblyResult localResult,
  }) async {
    final profile = await engineRepository.getActiveTextEngine();

    if (profile == null) {
      return _appendDiagnostic(localResult, 'repair_skipped_no_active_engine');
    }

    final prompt = _buildPrompt(region, localResult);

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

      final canonical = _canonicalizeRepairedMap(
        repaired,
        fallback: localResult.question,
        regionNumber: region.number,
      );

      return LocalAssemblyResult(
        question: canonical,
        diagnostics: [
          ...localResult.diagnostics,
          'ai_repair_applied',
        ],
        repairRecommended: false,
        rejected: false,
      );
    } catch (e) {
      // ignore: avoid_print
      print('SingleQuestionRepairService: repair failed: $e');
      return _appendDiagnostic(localResult, 'repair_failed:$e');
    }
  }

  String _buildPrompt(
    TextQuestionRegion region,
    LocalAssemblyResult localResult,
  ) {
    final local =
        const JsonEncoder.withIndent('  ').convert(localResult.question);

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
9. 只有 type=3 的解答题/证明题允许输出 explanation/raw_explanation；type=0/1/2 必须设为空。

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
    final explanation = type == 3
        ? _readString(
            repaired['explanation'],
            fallback: fallback['explanation'],
          )
        : '';
    final rawExplanation = type == 3
        ? _readNullableString(
            repaired['raw_explanation'],
            fallback: repaired['explanation'] ?? fallback['raw_explanation'],
          )
        : null;

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

  LocalAssemblyResult _appendDiagnostic(
    LocalAssemblyResult result,
    String diagnostic,
  ) {
    final question = Map<String, dynamic>.from(result.question);
    final oldDiagnostics = question['diagnostics'];

    question['diagnostics'] = [
      if (oldDiagnostics is List) ...oldDiagnostics.map((e) => e.toString()),
      diagnostic,
    ];

    return LocalAssemblyResult(
      question: question,
      diagnostics: [...result.diagnostics, diagnostic],
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
