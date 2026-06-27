import '../latex_import_repair.dart';
import 'import_parse_result.dart';
import 'question_fragment.dart';
import 'question_fusion_service.dart';

class ImportQuestionFusionCoordinator {
  final QuestionFusionService fusionService;
  final LatexImportRepairService latexRepairService;

  const ImportQuestionFusionCoordinator({
    this.fusionService = const QuestionFusionService(),
    this.latexRepairService = LatexImportRepairService.instance,
  });

  ImportParseResult fuseTextAndVision({
    required List<Map<String, dynamic>> textQuestions,
    required List<Map<String, dynamic>> visionQuestions,
    required String sourceName,
    bool repairLatexAfterFusion = true,
  }) {
    final fragments = <QuestionFragment>[
      ...textQuestions.asMap().entries.map(
            (entry) => QuestionFragment.fromMap(
              entry.value,
              source: QuestionFragmentSource.text,
              originalIndex: entry.key,
            ),
          ),
      ...visionQuestions.asMap().entries.map(
            (entry) => QuestionFragment.fromMap(
              entry.value,
              source: QuestionFragmentSource.vision,
              originalIndex: textQuestions.length + entry.key,
            ),
          ),
    ];

    final fusion = fusionService.fuse(fragments);
    final LatexImportRepairBatchResult? repairResult = repairLatexAfterFusion
        ? latexRepairService.repairAllSafelyWithDiagnostics(fusion.questions)
        : null;
    final questions = repairResult?.questions ?? fusion.questions;
    final latexRepairDiagnostics = repairResult?.diagnostics ??
        {
          'mode': 'skipped',
          'total': fusion.questions.length,
          'changedCount': 0,
          'fallbackCount': 0,
        };

    return ImportParseResult(
      questions: questions,
      warnings: fusion.diagnostics,
      diagnostics: {
        sourceName: {
          'fusionMergedCount': fusion.mergedCount,
          'fusionOrphanCount': fusion.orphanCount,
          'latexRepairAfterFusion': repairLatexAfterFusion,
          'latexRepair': latexRepairDiagnostics,
          if (fusion.diagnostics.isNotEmpty)
            'fusionDiagnostics': fusion.diagnostics,
        },
      },
    );
  }
}
