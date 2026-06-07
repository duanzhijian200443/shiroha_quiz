import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/parsed_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_signals.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_image_asset.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_fragment.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';

void main() {
  group('1. ParsedDocument Contract Tests', () {
    test(
        'toPlainTextForParsing() outputs text, tables, and image placeholders in order',
        () {
      final doc = ParsedDocument(
        sourceName: 'test.docx',
        format: ImportFormat.docx,
        parts: [
          const TextPart(
              order: 10, text: 'First paragraph', role: TextRole.paragraph),
          const TablePart(
            order: 20,
            rows: [
              ['Col 1', 'Col 2'],
              ['Val 1', 'Val 2'],
            ],
          ),
          const ImagePart(
            order: 30,
            path: 'word/media/image1.png',
            assetId: 'asset_0',
            resolvedPath: 'local/temp/0_image1.png',
            altText: 'A cute cat',
          ),
          const TextPart(
              order: 40, text: 'Last paragraph', role: TextRole.paragraph),
        ],
        signals: const DocumentSignals(),
      );

      final plainText = doc.toPlainTextForParsing();

      // Check text parts output in order
      expect(plainText.contains('First paragraph'), true);
      expect(plainText.contains('Last paragraph'), true);
      expect(
          plainText.indexOf('First paragraph') <
              plainText.indexOf('Last paragraph'),
          true);

      // Check table markdown-like formatting
      expect(plainText.contains('| Col 1 | Col 2 |'), true);
      expect(plainText.contains('|---|---|'), true);
      expect(plainText.contains('| Val 1 | Val 2 |'), true);

      // Check image asset stable formatting
      expect(
          plainText.contains(
              '[Image asset=asset_0 alt=A cute cat source=local/temp/0_image1.png]'),
          true);
    });

    test('toDiagnostics() includes all required fields and custom diagnostics',
        () {
      final asset = const DocumentImageAsset(
        id: 'asset_0',
        order: 1,
        sourceName: 'test.docx',
        originalPath: 'word/media/image1.png',
        extractedPath: 'local/temp/0_image1.png',
        isResolvable: true,
      );

      final doc = ParsedDocument(
        sourceName: 'test.docx',
        format: ImportFormat.docx,
        parts: [],
        signals:
            const DocumentSignals(questionMarkerCount: 3, answerMarkerCount: 2),
        fallbackUsed: true,
        diagnostics: {'custom_error': 'Failed to read zip footer'},
        imageAssets: [asset],
      );

      final diag = doc.toDiagnostics();

      expect(diag['sourceName'], 'test.docx');
      expect(diag['format'], 'docx');
      expect(diag['partCount'], 0);
      expect(diag['fallbackUsed'], true);
      expect(diag['custom_error'], 'Failed to read zip footer');

      final signalsMap = diag['signals'] as Map<String, dynamic>;
      expect(signalsMap['questionMarkerCount'], 3);
      expect(signalsMap['answerMarkerCount'], 2);

      final assetsList = diag['imageAssets'] as List;
      expect(assetsList.length, 1);
      expect(assetsList[0]['id'], 'asset_0');
      expect(assetsList[0]['isResolvable'], true);
    });
  });

  group('2. DocumentSignals Contract Tests', () {
    test('toMap() output keys are strictly stable and matches contract', () {
      const signals = DocumentSignals(
        questionMarkerCount: 5,
        answerMarkerCount: 4,
        imageCount: 3,
        tableCount: 2,
        formulaLikeCount: 1,
        hasTailAnswerBlock: true,
        hasInlineAnswers: true,
      );

      final map = signals.toMap();

      expect(map.containsKey('questionMarkerCount'), true);
      expect(map.containsKey('answerMarkerCount'), true);
      expect(map.containsKey('imageCount'), true);
      expect(map.containsKey('tableCount'), true);
      expect(map.containsKey('formulaLikeCount'), true);
      expect(map.containsKey('hasTailAnswerBlock'), true);
      expect(map.containsKey('hasInlineAnswers'), true);

      expect(map['questionMarkerCount'], 5);
      expect(map['answerMarkerCount'], 4);
      expect(map['imageCount'], 3);
      expect(map['tableCount'], 2);
      expect(map['formulaLikeCount'], 1);
      expect(map['hasTailAnswerBlock'], true);
      expect(map['hasInlineAnswers'], true);
    });

    test('operator + correctly accumulates values and merges booleans using OR',
        () {
      const sig1 = DocumentSignals(
        questionMarkerCount: 2,
        answerMarkerCount: 1,
        imageCount: 1,
        tableCount: 0,
        formulaLikeCount: 3,
        hasTailAnswerBlock: false,
        hasInlineAnswers: true,
      );

      const sig2 = DocumentSignals(
        questionMarkerCount: 3,
        answerMarkerCount: 2,
        imageCount: 0,
        tableCount: 2,
        formulaLikeCount: 1,
        hasTailAnswerBlock: true,
        hasInlineAnswers: false,
      );

      final combined = sig1 + sig2;

      expect(combined.questionMarkerCount, 5);
      expect(combined.answerMarkerCount, 3);
      expect(combined.imageCount, 1);
      expect(combined.tableCount, 2);
      expect(combined.formulaLikeCount, 4);
      expect(combined.hasTailAnswerBlock, true); // false || true => true
      expect(combined.hasInlineAnswers, true); // true || false => true
    });
  });

  group('3. DocumentImageAsset Contract Tests', () {
    test('toDiagnostics() outputs all asset fields correctly', () {
      const asset = DocumentImageAsset(
        id: 'img_abc',
        order: 5,
        sourceName: 'sub_doc.md',
        originalPath: 'images/pic.png',
        extractedPath: '/absolute/path/to/extracted/0_pic.png',
        altText: 'Schema diagram',
        byteLength: 4096,
        isResolvable: true,
      );

      final diag = asset.toDiagnostics();

      expect(diag['id'], 'img_abc');
      expect(diag['order'], 5);
      expect(diag['sourceName'], 'sub_doc.md');
      expect(diag['originalPath'], 'images/pic.png');
      expect(diag['extractedPath'], '/absolute/path/to/extracted/0_pic.png');
      expect(diag['altText'], 'Schema diagram');
      expect(diag['byteLength'], 4096);
      expect(diag['isResolvable'], true);
    });

    test(
        'unresolvable asset preserves originalPath and lists correct attributes',
        () {
      const asset = DocumentImageAsset(
        id: 'img_unresolved',
        order: 2,
        sourceName: 'doc.md',
        originalPath: 'https://external.website.com/image.jpg',
        isResolvable: false,
      );

      final diag = asset.toDiagnostics();

      expect(diag['id'], 'img_unresolved');
      expect(diag['originalPath'], 'https://external.website.com/image.jpg');
      expect(diag['extractedPath'], null);
      expect(diag['isResolvable'], false);
    });
  });

  group('4. QuestionFragment Minimum Contract Tests', () {
    test('placeholder answers (Chinese & English) are detected as invalid', () {
      final placeholders = [
        '无',
        '未提供',
        '未见答案',
        '暂无',
        'null',
        'none',
        'NULL',
        'NONE'
      ];
      for (final ph in placeholders) {
        final f = QuestionFragment.fromMap({
          'content': '1. Who is the father of Flutter?',
          'standard_answer': ph,
        }, source: QuestionFragmentSource.text, originalIndex: 0);

        expect(f.hasAnswer, false);
        expect(f.kind, QuestionFragmentKind.stemOnly);
      }
    });

    test(
        'answerOnly can be correctly derived from standard_answer or short content',
        () {
      // Case 1: no content, only valid standard_answer
      final f1 = QuestionFragment.fromMap({
        'standard_answer': 'A',
      }, source: QuestionFragmentSource.text, originalIndex: 0);
      expect(f1.kind, QuestionFragmentKind.answerOnly);
      expect(f1.hasAnswerPatch, true);
      expect(f1.answerPatch, 'A');

      // Case 2: very short content (like choice letter) with no standard_answer
      final f2 = QuestionFragment.fromMap({
        'content': 'B',
      }, source: QuestionFragmentSource.text, originalIndex: 1);
      expect(f2.kind, QuestionFragmentKind.answerOnly);
      expect(f2.hasAnswerPatch, true);
      expect(f2.answerPatch, 'B');
    });

    test('orphan represents invalid structure but must not be discarded', () {
      final f = QuestionFragment.fromMap({
        'explanation': 'Some explanation but no content and no answer',
      }, source: QuestionFragmentSource.text, originalIndex: 0);

      expect(f.kind, QuestionFragmentKind.orphan);
      expect(f.hasStem, false);
      expect(f.hasAnswer, false);
    });
  });

  group('5. ImportParseResult Diagnostics Contract Tests', () {
    test(
        'ImportParseResult fields conform to contract types and empty result != failure',
        () {
      const result = ImportParseResult(
        questions: [],
        warnings: ['Answer conflict on Q1', 'Missing visual metadata'],
        diagnostics: {
          'adapter_logs': {
            'file_parsed': 'test.zip',
            'sub_files': ['a.txt', 'b.txt'],
          }
        },
      );

      expect(result.questions, isEmpty);
      expect(result.warnings.length, 2);
      expect(result.warnings[0], 'Answer conflict on Q1');
      expect(result.diagnostics['adapter_logs']['file_parsed'], 'test.zip');
      expect(
          result.diagnostics['adapter_logs']['sub_files'], contains('a.txt'));
    });
  });
}
