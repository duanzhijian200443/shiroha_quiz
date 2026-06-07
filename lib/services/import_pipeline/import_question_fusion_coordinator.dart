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
    final repaired = latexRepairService.repairAll(fusion.questions);

    return ImportParseResult(
      questions: repaired,
      warnings: fusion.diagnostics,
      diagnostics: {
        sourceName: {
          'fusionMergedCount': fusion.mergedCount,
          'fusionOrphanCount': fusion.orphanCount,
          if (fusion.diagnostics.isNotEmpty)
            'fusionDiagnostics': fusion.diagnostics,
        },
      },
    );
  }
}
