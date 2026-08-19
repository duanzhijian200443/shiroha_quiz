import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/multi_file_question_merge_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_review/import_review_analyzer.dart';
import 'package:shiroha_quiz/services/import_review/import_review_issue.dart';
import 'package:shiroha_quiz/services/import_review/import_review_item.dart';

import '../../tool/import_acceptance.dart';
import '../support/memory_content_asset_store.dart';
import '../support/unsupported_ai_engine_store.dart';

class _SyntheticAiEngineRepository extends AiEngineRepository {
  _SyntheticAiEngineRepository(this.profile)
      : super(
          store: const UnsupportedAiEngineStore(),
          credentialStore: const UnsupportedEngineCredentialStore(),
        );

  final AiEngineProfile profile;

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => profile;
}

class _SyntheticOcrDocumentClient implements OcrDocumentClient {
  _SyntheticOcrDocumentClient(this.document);

  final OcrDocument document;
  int parseCallCount = 0;

  @override
  String get modelId => 'synthetic-ocr-model';

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    parseCallCount++;
    return document;
  }
}

class _RecordingRepairService extends SingleQuestionRepairService {
  int callCount = 0;

  @override
  Future<LocalAssemblyResult> repair({
    required TextQuestionRegion region,
    required LocalAssemblyResult localResult,
    required bool requireAnswer,
    required ExplanationRetentionMode explanationRetentionMode,
  }) async {
    callCount++;
    return localResult;
  }
}

void main() {
  group('legacy import characterization', () {
    test(
      'synthetic 2022 equivalent keeps 22 questions and one safe Q21 review',
      () async {
        final blocks = <OcrBlock>[
          const OcrBlock(
            blockId: 'section',
            pageIndex: 1,
            type: 'text',
            text: '三、解答题',
            bbox: <double>[],
            readingOrder: 0,
          ),
        ];
        var readingOrder = 1;
        for (var number = 1; number <= 22; number++) {
          blocks
            ..add(
              OcrBlock(
                blockId: 'q_$number',
                pageIndex: 1,
                type: 'text',
                text: '$number. Synthetic prompt marker $number.',
                bbox: const <double>[],
                readingOrder: readingOrder++,
              ),
            )
            ..add(
              OcrBlock(
                blockId: 'answer_$number',
                pageIndex: 1,
                type: 'text',
                text: '答案：synthetic-result-$number',
                bbox: const <double>[],
                readingOrder: readingOrder++,
              ),
            )
            ..add(
              OcrBlock(
                blockId: 'explanation_$number',
                pageIndex: 1,
                type: 'text',
                text: number == 21
                    ? r'解析：Synthetic \(\begin{matrix}1\end{pmatrix}\)'
                    : '解析：Synthetic rationale marker $number.',
                bbox: const <double>[],
                readingOrder: readingOrder++,
              ),
            );
        }
        final document = OcrDocument(
          sourceName: 'synthetic_2022_equivalent',
          pages: <OcrPage>[
            OcrPage(pageIndex: 1, blocks: blocks),
          ],
          markdown: '',
          rawResponses: const <Map<String, dynamic>>[],
          usage: const <String, dynamic>{},
        );
        final ocrClient = _SyntheticOcrDocumentClient(document);
        final repairService = _RecordingRepairService();
        final service = OcrImportService(
          ocrClient: ocrClient,
          assetStore: MemoryContentAssetStore(),
          engineRepository: _SyntheticAiEngineRepository(
            const AiEngineProfile(
              id: 'synthetic-ocr',
              engineType: AiEngineType.ocr,
              name: 'synthetic-zhipu-ocr',
              apiKey: 'not-used',
              baseUrl: 'https://open.bigmodel.cn/api/paas',
              modelName: 'synthetic-ocr-model',
              temperature: 0,
              reasoningEffort: '',
              isActive: true,
            ),
          ),
          repairService: repairService,
        );

        final result = await service.tryParse(
          filePath: 'synthetic-only',
          sourceName: 'synthetic_2022_equivalent',
          format: ImportFormat.pdf,
          explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
        );
        expect(result, isNotNull);
        expect(result!.usedOcr, isTrue);
        final audited = result.questions;
        final quality = runAcceptanceQualityChecks(
          questions: audited,
          testCase: ImportAcceptanceCase(
            schemaVersion: 1,
            caseId: 'synthetic_2022_equivalent',
            pdf: 'synthetic-only',
            expectedQuestionCount: 22,
            expectedNumbers: List<int>.generate(22, (index) => index + 1),
            allowDuplicateNumbers: false,
          ),
        );

        expect(audited, hasLength(22));
        expect(
          audited.map((question) => question['question_number']),
          List<int>.generate(22, (index) => index + 1),
        );
        expect(quality.structureVerdict, 'pass');
        expect(quality.missingNumbers, isEmpty);
        expect(quality.duplicateNumbers, isEmpty);
        expect(
          quality.questionReports.where((report) => !report.hasStandardAnswer),
          isEmpty,
        );
        expect(
          quality.questionReports[20].issues.map((issue) => issue.code),
          <String>['latex_unrenderable'],
        );
        expect(
          quality.questionReports
              .where((report) => report.questionNumber != 21)
              .expand((report) => report.issues),
          isEmpty,
        );

        final review = ImportReviewAnalyzer.analyzeItems(
          audited
              .asMap()
              .entries
              .map(
                (entry) => ImportReviewItem.fromMap(entry.value, entry.key),
              )
              .toList(growable: false),
        );
        expect(review.summary.missingAnswerCount, 0);
        expect(review.summary.errorCount, 0);
        expect(review.summary.warningCount, 1);
        expect(review.issues, hasLength(1));
        expect(
          review.issues.single.code,
          ImportReviewIssueCode.latexUnrenderable,
        );
        expect(review.issues.single.questionIndex, 20);

        final ordinaryRepairCandidates = audited.expand<String>((question) {
          final metadata = question['_import_review'];
          if (metadata is! Map) return const <String>[];
          final codes = metadata['repairCandidateCodes'];
          return codes is List
              ? codes.map((code) => code.toString())
              : const <String>[];
        }).toList(growable: false);
        expect(ordinaryRepairCandidates, isEmpty);
        expect(ocrClient.parseCallCount, 1);
        expect(repairService.callCount, 0);
        expect(result.diagnostics['repairEligibleCount'], 0);
        expect(result.diagnostics['repairAttemptedCount'], 0);

        final serialized = jsonEncode(audited);
        for (final forbidden in const <String>[
          'Authorization',
          'Bearer ',
          'api_key',
          'provider_body',
          r'C:\Users\',
          '/Users/',
        ]) {
          expect(serialized, isNot(contains(forbidden)));
        }
      },
    );

    test(
      'synthetic 2019 equivalent keeps parenthesized questions and Roman subquestions',
      () {
        final blocks = <OcrBlock>[
          const OcrBlock(
            blockId: 'section',
            pageIndex: 1,
            type: 'text',
            text: '一、选择题',
            bbox: <double>[],
            readingOrder: 0,
          ),
        ];
        var readingOrder = 1;
        for (var number = 1; number <= 23; number++) {
          blocks.add(
            OcrBlock(
              blockId: 'q_$number',
              pageIndex: 1,
              type: 'text',
              text: '（$number）Synthetic prompt marker $number.',
              bbox: const <double>[],
              readingOrder: readingOrder++,
            ),
          );
          if (number == 15) {
            blocks
              ..add(
                OcrBlock(
                  blockId: 'q_15_roman_1',
                  pageIndex: 1,
                  type: 'text',
                  text: '（Ⅰ）Synthetic subpart one.',
                  bbox: const <double>[],
                  readingOrder: readingOrder++,
                ),
              )
              ..add(
                OcrBlock(
                  blockId: 'q_15_roman_2',
                  pageIndex: 1,
                  type: 'text',
                  text: '（Ⅱ）Synthetic subpart two.',
                  bbox: const <double>[],
                  readingOrder: readingOrder++,
                ),
              );
          }
        }

        final result = const OcrQuestionRegionizer().regionize(
          OcrDocument(
            sourceName: 'synthetic_2019_equivalent',
            pages: <OcrPage>[
              OcrPage(pageIndex: 1, blocks: blocks),
            ],
            markdown: '',
            rawResponses: const <Map<String, dynamic>>[],
            usage: const <String, dynamic>{},
          ),
        );

        expect(result.regions, hasLength(23));
        expect(
          result.regions.map((region) => region.number),
          List<int>.generate(23, (index) => index + 1),
        );
        expect(result.diagnostics['parenthesizedArabicAcceptedCount'], 23);
        expect(result.diagnostics['romanSubquestionCount'], 2);
        final question15 =
            result.regions.singleWhere((region) => region.number == 15);
        expect(question15.stemText, contains('（Ⅰ）'));
        expect(question15.stemText, contains('（Ⅱ）'));
      },
    );

    test(
      'synthetic 2019 stem and answer maps merge 23 to 23 by question number',
      () {
        final stems = List<Map<String, dynamic>>.generate(23, (index) {
          final number = index + 1;
          return <String, dynamic>{
            'q_num': '（$number）',
            'content': 'Synthetic stem marker $number with complete structure.',
            'options': const <String>['A', 'B', 'C', 'D'],
            'standard_answer': '',
            'explanation': '',
            'source_page_indices': <int>[number],
            'source_block_ids': <String>['stem_$number'],
          };
        });
        final answers = List<Map<String, dynamic>>.generate(23, (index) {
          final number = index + 1;
          return <String, dynamic>{
            'q_num': '$number.',
            'content': '无题干',
            'options': const <String>[],
            'standard_answer': 'A',
            'explanation': 'Synthetic rationale marker $number.',
            'source_page_indices': <int>[number + 100],
            'source_block_ids': <String>['answer_$number'],
          };
        });

        final result = const MultiFileQuestionMergeService().merge(
          <MultiFileQuestionBatch>[
            MultiFileQuestionBatch(fileIndex: 0, questions: stems),
            MultiFileQuestionBatch(fileIndex: 1, questions: answers),
          ],
        );

        expect(result.mergedQuestions, hasLength(23));
        expect(
          result.mergedQuestions.map((question) => question['question_number']),
          List<int>.generate(23, (index) => index + 1),
        );
        expect(result.residualFragments, isEmpty);
        expect(result.conflictFragments, isEmpty);
        expect(result.metrics.finalQuestionCount, 23);
        expect(result.metrics.answerOnlyMergeCount, 23);
        expect(result.requiresReview, isFalse);
        expect(result.blocked, isFalse);
      },
    );
  });
}
