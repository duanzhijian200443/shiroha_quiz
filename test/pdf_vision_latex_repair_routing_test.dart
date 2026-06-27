import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/ai_vision_parse_service.dart';
import 'package:shiroha_quiz/services/llm_api_client.dart';
import 'package:shiroha_quiz/services/vision_asset_builder.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/llm_providers/llm_provider_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_fusion_coordinator.dart';

class _MockLlmApiClient extends LlmApiClient {
  final String responseText;

  _MockLlmApiClient(this.responseText);

  @override
  Future<String> callVision({
    required AiEngineProfile profile,
    required String prompt,
    required List<LlmVisionAsset> assets,
    double? temperature,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    return responseText;
  }
}

/// Stub builder that returns an empty inline asset, avoiding filesystem I/O.
class _StubAssetBuilder extends VisionAssetBuilder {
  const _StubAssetBuilder();

  @override
  Future<List<LlmVisionAsset>> buildInlineImageAssets(
    List<String> imagePaths, {
    int compressionThresholdBytes = 500 * 1024,
  }) async {
    return [
      LlmVisionAsset.inline(
        mimeType: 'image/jpeg',
        base64Data: '/9j/4AAQSkZJRg==',
      ),
    ];
  }
}

class _MockEngineRepository extends AiEngineRepository {
  final AiEngineProfile? profile;

  _MockEngineRepository(this.profile);

  @override
  Future<AiEngineProfile?> getActiveVisionEngine() async {
    return profile;
  }
}

void main() {
  const profile = AiEngineProfile(
    id: 'test_vision',
    engineType: AiEngineType.vision,
    name: 'test_vision',
    apiKey: 'key',
    baseUrl: 'url',
    modelName: 'model',
    temperature: 0.0,
    reasoningEffort: '',
    isActive: true,
  );

  const rawLatexJson = '''
{
  "questions": [
    {
      "q_num": "18",
      "type": 3,
      "content": "计算 I = \\\\iint_D \\\\frac{(x-y)^2}{x^2+y^2} dxdy",
      "options": [],
      "standard_answer": "0",
      "explanation": "令 r = \\\\sqrt{x^2+y^2}"
    },
    {
      "q_num": "19",
      "type": 0,
      "content": "设 \\\\sin\\\\theta = \\\\frac{3}{5}，求 \\\\cos\\\\theta。",
      "options": ["A. \\\\frac{4}{5}", "B. \\\\frac{3}{4}"],
      "standard_answer": "A"
    }
  ]
}
''';

  group('AiVisionParseService repairLatex routing', () {
    test(
      'repairLatex=false leaves bare LaTeX untouched',
      () async {
        final service = AiVisionParseService(
          apiClient: _MockLlmApiClient(rawLatexJson),
          engineRepository: _MockEngineRepository(profile),
          assetBuilder: const _StubAssetBuilder(),
        );

        final questions = await service.parseImages(
          ['test_page.jpg'],
          repairLatex: false,
        );

        expect(questions.length, 2);

        // Q18 content should still contain bare LaTeX after sanitizer decoding
        final q18content = questions[0]['content'].toString();
        expect(q18content, contains(r'\iint'));
        expect(q18content, contains(r'\frac'));

        // Q19 content should still contain bare LaTeX
        final q19content = questions[1]['content'].toString();
        expect(q19content, contains(r'\sin'));
      },
    );

    test(
      'repairLatex=true wraps bare LaTeX via repairAll',
      () async {
        final service = AiVisionParseService(
          apiClient: _MockLlmApiClient(rawLatexJson),
          engineRepository: _MockEngineRepository(profile),
          assetBuilder: const _StubAssetBuilder(),
        );

        final questions = await service.parseImages(
          ['test_page.jpg'],
          repairLatex: true,
        );

        expect(questions.length, 2);

        // Q18 content should be wrapped: \iint_D \frac → \(...\) or \[...\]
        final q18content = questions[0]['content'].toString();
        expect(
          q18content.contains(r'\(') || q18content.contains(r'\['),
          isTrue,
          reason: 'q18 content should be wrapped after repairLatex=true',
        );
        final q18expl = questions[0]['explanation'].toString();
        expect(
          q18expl.contains(r'\(') || q18expl.contains(r'\['),
          isTrue,
          reason: 'q18 explanation should also be wrapped',
        );

        // Q19 content should be wrapped
        final q19content = questions[1]['content'].toString();
        expect(
          q19content.contains(r'\(') || q19content.contains(r'\['),
          isTrue,
          reason: 'q19 content should be wrapped after repairLatex=true',
        );
      },
    );

    test(
      'repairLatex default (false) does not repair',
      () async {
        final service = AiVisionParseService(
          apiClient: _MockLlmApiClient(rawLatexJson),
          engineRepository: _MockEngineRepository(profile),
          assetBuilder: const _StubAssetBuilder(),
        );

        // Call without repairLatex — should default to false
        final questions = await service.parseImages(['test_page.jpg']);

        expect(questions.length, 2);
        final q18content = questions[0]['content'].toString();
        // Without repair, bare LaTeX should still be present
        expect(q18content, contains(r'\iint'));
      },
    );
  });

  group('ImportQuestionFusionCoordinator pure vision repair routing', () {
    const coordinator = ImportQuestionFusionCoordinator();

    test('PDF vision-only path skips repairAll for bare matrix', () {
      final result = coordinator.fuseTextAndVision(
        sourceName: 'vision_pdf_page',
        textQuestions: [],
        visionQuestions: [
          {
            'q_num': '20',
            'content': r'\begin{pmatrix}1&2\\3&4\end{pmatrix}',
            'standard_answer': 'A',
          },
        ],
        repairLatexAfterFusion: false,
      );

      final q = result.questions.single;
      expect(
        q['content'],
        r'\begin{pmatrix}1&2\\3&4\end{pmatrix}',
      );
      expect(
        (q['content'] as String).contains(r'\['),
        false,
      );
      expect(
        (q['content'] as String).contains(r'\('),
        false,
      );
      expect(
        result.diagnostics['vision_pdf_page']['latexRepairAfterFusion'],
        false,
      );
    });

    test('standalone image vision path also skips repairAll', () {
      final result = coordinator.fuseTextAndVision(
        sourceName: 'vision_image_file',
        textQuestions: [],
        visionQuestions: [
          {
            'q_num': '20',
            'content': r'Compute \frac{1}{2}',
            'standard_answer': r'\sqrt{x}',
          },
        ],
        repairLatexAfterFusion: false,
      );

      final q = result.questions.single;
      expect(q['content'], r'Compute \frac{1}{2}');
      expect(q['standard_answer'], r'\sqrt{x}');
      expect((q['content'] as String).contains(r'\('), false);
      expect((q['standard_answer'] as String).contains(r'\('), false);
      expect(
        result.diagnostics['vision_image_file']['latexRepairAfterFusion'],
        false,
      );
    });

    test('default path wraps bare LaTeX with repairAll', () {
      final result = coordinator.fuseTextAndVision(
        sourceName: 'formula.md',
        textQuestions: [],
        visionQuestions: [
          {
            'q_num': '21',
            'content': r'\begin{pmatrix}1&2\\3&4\end{pmatrix}',
            'standard_answer': 'B',
          },
        ],
      );

      final q = result.questions.single;
      expect(
        (q['content'] as String).contains(r'\(') ||
            (q['content'] as String).contains(r'\['),
        isTrue,
      );
      expect(
        result.diagnostics['formula.md']['latexRepairAfterFusion'],
        true,
      );
    });

    test('diagnostics records latexRepairAfterFusion in all paths', () {
      final withRepair = coordinator.fuseTextAndVision(
        sourceName: 'with.md',
        textQuestions: [],
        visionQuestions: [
          {'q_num': '22', 'content': r'\frac{a}{b}'},
        ],
        repairLatexAfterFusion: true,
      );

      expect(
        withRepair.diagnostics['with.md']['latexRepairAfterFusion'],
        true,
      );

      final withoutRepair = coordinator.fuseTextAndVision(
        sourceName: 'without.md',
        textQuestions: [],
        visionQuestions: [
          {'q_num': '23', 'content': r'\frac{a}{b}'},
        ],
        repairLatexAfterFusion: false,
      );

      expect(
        withoutRepair.diagnostics['without.md']['latexRepairAfterFusion'],
        false,
      );
    });
  });
}
