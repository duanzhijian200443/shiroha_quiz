import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../core/database/database_helper.dart';
import '../data/models/ai_engine_profile.dart';
import '../data/repositories/ai_engine_repository.dart';
import 'llm_api_client.dart';

/// LaTeX 历史数据迁移服务（一次性使用）
/// 扫描题库中的裸 LaTeX 字段，通过 AI 引擎统一添加 \( \) 或 \[ \] 定界符。
class LatexMigrationService {
  LatexMigrationService._();
  static final instance = LatexMigrationService._();

  final AiEngineRepository _engineRepository = AiEngineRepository.instance;
  final LlmApiClient _apiClient = const LlmApiClient();

  /// 检测字段是否含有裸 LaTeX
  static bool _hasBareLatex(String? text) {
    if (text == null || text.isEmpty) return false;
    const patterns = [
      r'\frac',
      r'\sqrt',
      r'\sum',
      r'\int',
      r'\lim',
      r'\prod',
      r'\oint',
      r'\iint',
      r'\iiint',
      r'\begin',
      r'\partial',
      r'\infty',
      r'\alpha',
      r'\beta',
      r'\gamma',
      r'\theta',
      r'\pi',
      r'\sigma',
      r'\lambda',
      r'\Delta',
      r'\Sigma',
    ];
    return patterns.any((p) => text.contains(p));
  }

  static const String _migrationSystemPrompt =
      r'You are a LaTeX formatting expert. Your ONLY task is to add correct LaTeX delimiters to math formulas in the given text.'
      '\n\nRules:\n'
      r'1. Inline formulas, single variables, math symbols: wrap with \( ... \)'
      '\n'
      r'2. Block formulas, standalone equations, matrix environments: wrap with \[ ... \]'
      '\n'
      r'3. Already wrapped with \(...\) or \[...\]: keep as-is'
      '\n'
      r'4. Wrapped with $...$: convert to \(...\)'
      '\n'
      r'5. Wrapped with $$...$$: convert to \[...\]'
      '\n'
      r'6. Bare LaTeX commands (like \frac{}{}, \sqrt{}, \int_{} not inside any delimiter): add \(...\) or \[...\]'
      '\n'
      '7. NEVER modify formula content itself\n'
      '8. Keep all Chinese text exactly as-is\n'
      r'9. Keep blank-fill underscores ___ unwrapped'
      '\n\n'
      'Input: JSON object {"content": "...", "standard_answer": "...", "explanation": "..."}\n'
      'Output: same-structure JSON object, only delimiter wrapping changed\n'
      'Output ONLY the JSON, no explanations, no code block markers.';

  /// 调用 AI 引擎，为单道题的三个字段统一添加定界符
  Future<Map<String, String>?> _fixQuestionLatex(
    AiEngineProfile profile,
    String content,
    String stdAns,
    String expl,
  ) async {
    if (!profile.isComplete) {
      debugPrint(
        '[Migration] AI engine profile is incomplete: ${profile.missingFields.join(', ')}',
      );
      return null;
    }

    final userMsg = jsonEncode({
      'content': content,
      'standard_answer': stdAns,
      'explanation': expl,
    });

    try {
      final responseText = await _apiClient.callText(
        profile: profile,
        prompt: '$_migrationSystemPrompt\n\n$userMsg',
        temperature: 0.0,
        reasoningEffort: '',
        maxTokens: 8192,
        jsonResponse: true,
        timeout: const Duration(minutes: 2),
      );

      final result = jsonDecode(responseText) as Map<String, dynamic>;
      return {
        'content': result['content']?.toString() ?? content,
        'standard_answer': result['standard_answer']?.toString() ?? stdAns,
        'explanation': result['explanation']?.toString() ?? expl,
      };
    } catch (e) {
      debugPrint('[Migration] AI call failed: $e');
      return null;
    }
  }

  /// 运行迁移。通过 [onProgress] 回调报告进度（已处理数, 总数, 当前状态描述）。
  Future<MigrationResult> runMigration({
    required void Function(int processed, int total, String status) onProgress,
  }) async {
    final profile = await _engineRepository.getActiveTextEngine();
    if (profile == null) {
      return MigrationResult(
        success: false,
        message: '未找到激活的文本 AI 引擎，请先在设置中配置并激活引擎。',
      );
    }

    final db = await DatabaseHelper.instance.database;
    final allQuestions = await db.query('questions');
    final total = allQuestions.length;

    if (total == 0) {
      return MigrationResult(success: true, message: '数据库中暂无题目，无需迁移。');
    }

    int processed = 0;
    int updated = 0;
    int skipped = 0;
    int failed = 0;

    onProgress(0, total, '开始扫描 $total 道题目...');

    for (final q in allQuestions) {
      final qId = q['id']?.toString() ?? '';
      final content = q['content']?.toString() ?? '';
      final stdAns = q['standard_answer']?.toString() ?? '';
      final expl = q['explanation']?.toString() ?? '';

      processed++;

      if (!_hasBareLatex(content) &&
          !_hasBareLatex(stdAns) &&
          !_hasBareLatex(expl)) {
        skipped++;
        onProgress(processed, total,
            '[$processed/$total] 跳过（无裸 LaTeX）: ${qId.substring(0, qId.length.clamp(0, 20))}...');
        continue;
      }

      onProgress(processed, total,
          '[$processed/$total] AI 修复中: ${qId.substring(0, qId.length.clamp(0, 20))}...');

      final result = await _fixQuestionLatex(profile, content, stdAns, expl);

      if (result == null) {
        failed++;
        continue;
      }

      // 只在确实有变化时才写回数据库
      if (result['content'] != content ||
          result['standard_answer'] != stdAns ||
          result['explanation'] != expl) {
        await db.update(
          'questions',
          {
            'content': result['content'],
            'standard_answer': result['standard_answer'],
            'explanation': result['explanation'],
          },
          where: 'id = ?',
          whereArgs: [qId],
        );
        updated++;
      } else {
        skipped++;
      }

      // 稍作冷却，避免触发 API 频率限制
      await Future.delayed(const Duration(milliseconds: 300));
    }

    final msg = '迁移完成！共 $total 题：$updated 道已修复，$skipped 道无需修改，$failed 道失败。';
    return MigrationResult(
      success: failed == 0,
      message: msg,
      updatedCount: updated,
      skippedCount: skipped,
      failedCount: failed,
    );
  }
}

class MigrationResult {
  final bool success;
  final String message;
  final int updatedCount;
  final int skippedCount;
  final int failedCount;

  const MigrationResult({
    required this.success,
    required this.message,
    this.updatedCount = 0,
    this.skippedCount = 0,
    this.failedCount = 0,
  });
}
