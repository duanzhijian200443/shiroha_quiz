import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  group('QuestionDraftV2 aggregate construction', () {
    test('represents supported kinds and preserves ordered domain fields', () {
      final sourceRefs = <SourceRef>[
        SourceRef.document(sourceId: 'source_001'),
        SourceRef.at(
          sourceId: 'source_001',
          point: SourcePoint.page(pageNumber: 2),
        ),
      ];
      final assetRefs = <SourcedAssetRef>[
        SourcedAssetRef(
          sourceId: 'source_001',
          asset: AssetRef(assetId: 'asset_001', kind: AssetKind.image),
        ),
      ];
      final issues = <ImportIssue>[
        ImportIssue(
          code: 'choice_answer_needs_review',
          severity: ImportIssueSeverity.warning,
          field: ImportIssueField.answer,
        ),
      ];
      final options = <QuestionOption>[
        QuestionOption(
          optionId: 'option_a',
          label: 'A',
          content: _text('alpha'),
          sourceRef: sourceRefs[1],
        ),
        QuestionOption(
          optionId: 'option_b',
          label: 'B',
          content: _text('beta'),
        ),
      ];

      final choice = QuestionDraftV2(
        questionId: 'question_001',
        kind: QuestionKind.singleChoice,
        questionNumber: 1,
        stem: _text('synthetic stem'),
        options: options,
        answer: ChoiceAnswer(optionIds: const ['option_b']),
        explanation: _text('synthetic explanation'),
        sourceRefs: sourceRefs,
        assetRefs: assetRefs,
        issues: issues,
      );
      final fillBlank = QuestionDraftV2(
        questionId: 'question_002',
        kind: QuestionKind.fillBlank,
        stem: _text(''),
        answer: ContentAnswer(content: _text('synthetic content answer')),
      );
      final shortAnswer = QuestionDraftV2(
        questionId: 'question_003',
        kind: QuestionKind.shortAnswer,
        stem: _text('synthetic short-answer stem'),
      );

      expect(choice.questionNumber, 1);
      expect(choice.options.map((option) => option.optionId), [
        'option_a',
        'option_b',
      ]);
      expect(choice.sourceRefs, sourceRefs);
      expect(choice.assetRefs, assetRefs);
      expect(choice.issues, issues);
      expect(choice.answer, isA<ChoiceAnswer>());
      expect(fillBlank.answer, isA<ContentAnswer>());
      expect(shortAnswer.answer, isNull);
      expect(shortAnswer.explanation, isNull);
    });

    test('deduplicates composite identities without merging different sources',
        () {
      final sourceA = SourceRef.document(sourceId: 'source_001');
      final sourceB = SourceRef.document(sourceId: 'source_002');
      final first = SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(
          assetId: 'asset_000001',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      );
      final repeated = SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(
          assetId: 'asset_000001',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      );
      final otherSource = SourcedAssetRef(
        sourceId: 'source_002',
        asset: AssetRef(
          assetId: 'asset_000001',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      );

      final draft = QuestionDraftV2(
        questionId: 'question_assets_001',
        kind: QuestionKind.shortAnswer,
        stem: _text('synthetic'),
        sourceRefs: <SourceRef>[sourceA, sourceB],
        assetRefs: <SourcedAssetRef>[first, repeated, otherSource],
      );

      expect(draft.assetRefs, <SourcedAssetRef>[first, otherSource]);
      expect(draft.assetRefs.map((ref) => ref.sourceId), <String>[
        'source_001',
        'source_002',
      ]);
    });

    test('rejects conflicting composite metadata and orphan asset sources', () {
      final source = SourceRef.document(sourceId: 'source_001');
      final png = SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(
          assetId: 'asset_000001',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      );
      final jpeg = SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(
          assetId: 'asset_000001',
          kind: AssetKind.image,
          mimeType: 'image/jpeg',
        ),
      );
      final orphan = SourcedAssetRef(
        sourceId: 'source_002',
        asset: AssetRef(
          assetId: 'asset_000001',
          kind: AssetKind.image,
        ),
      );

      expect(
        () => QuestionDraftV2(
          questionId: 'question_assets_conflict',
          kind: QuestionKind.shortAnswer,
          stem: _text('synthetic'),
          sourceRefs: <SourceRef>[source],
          assetRefs: <SourcedAssetRef>[png, jpeg],
        ),
        throwsFormatException,
      );
      expect(
        () => QuestionDraftV2(
          questionId: 'question_assets_orphan',
          kind: QuestionKind.shortAnswer,
          stem: _text('synthetic'),
          sourceRefs: <SourceRef>[source],
          assetRefs: <SourcedAssetRef>[orphan],
        ),
        throwsFormatException,
      );
    });

    test('keeps review-quality problems constructible without defaults', () {
      final missingAnswer = ImportIssue(
        code: 'missing_answer',
        severity: ImportIssueSeverity.warning,
        field: ImportIssueField.answer,
      );

      final draft = QuestionDraftV2(
        questionId: 'question_review_001',
        kind: QuestionKind.singleChoice,
        stem: RichContent(nodes: const <ContentNode>[]),
        answer: null,
        explanation: RichContent(nodes: const <ContentNode>[]),
        issues: [missingAnswer],
      );

      expect(draft.stem.nodes, isEmpty);
      expect(draft.options, isEmpty);
      expect(draft.answer, isNull);
      expect(draft.explanation, isNotNull);
      expect(draft.explanation!.nodes, isEmpty);
      expect(draft.issues, [missingAnswer]);
    });

    test('allows answer-shape mismatches for later review', () {
      final draft = QuestionDraftV2(
        questionId: 'question_review_002',
        kind: QuestionKind.fillBlank,
        stem: _text('synthetic'),
        answer: ChoiceAnswer(
          optionIds: const ['unknown_option', 'unknown_option'],
        ),
      );

      expect(
        (draft.answer! as ChoiceAnswer).optionIds,
        ['unknown_option', 'unknown_option'],
      );
    });
  });

  group('QuestionDraftV2 rich image referential integrity', () {
    final source = SourceRef.document(sourceId: 'source_001');
    final asset = SourcedAssetRef(
      sourceId: 'source_001',
      asset: AssetRef(assetId: 'asset_001', kind: AssetKind.image),
    );

    ImageNode image() {
      return ImageNode(
        sourceId: 'source_001',
        localAssetId: 'asset_001',
        alternativeText: RichContent(nodes: const <ContentNode>[
          TextNode('synthetic alt'),
        ]),
      );
    }

    TableNode tableWithImage() {
      return TableNode(
        structure: TableStructure(rows: <TableRow>[
          TableRow(cells: <TableCell>[
            TableCell(
              content: RichContent(nodes: <ContentNode>[image()]),
            ),
          ]),
        ]),
      );
    }

    test(
        'accepts reachable images in stem, options, answer, explanation, and table cells',
        () {
      final draft = QuestionDraftV2(
        questionId: 'question_image_001',
        kind: QuestionKind.shortAnswer,
        stem: RichContent(nodes: <ContentNode>[image()]),
        options: <QuestionOption>[
          QuestionOption(
            optionId: 'option_a',
            label: 'A',
            content: RichContent(nodes: <ContentNode>[image()]),
          ),
        ],
        answer: ContentAnswer(
          content: RichContent(nodes: <ContentNode>[image()]),
        ),
        explanation: RichContent(nodes: <ContentNode>[image()]),
        sourceRefs: <SourceRef>[source],
        assetRefs: <SourcedAssetRef>[asset],
      );

      expect(draft.assetRefs, <SourcedAssetRef>[asset]);
      expect(
        draft.stem.nodes.single,
        image(),
      );
      expect(
        (draft.options.single.content.nodes.single as ImageNode).localAssetId,
        'asset_001',
      );
      expect(
        (draft.answer! as ContentAnswer).content.nodes.single,
        image(),
      );
      expect(draft.explanation!.nodes.single, image());
    });

    test('rejects a missing inventory entry in every reachable location', () {
      final invalidDrafts = <String, QuestionDraftV2 Function()>{
        'stem': () => QuestionDraftV2(
              questionId: 'question_missing_stem',
              kind: QuestionKind.shortAnswer,
              stem: RichContent(nodes: <ContentNode>[image()]),
              sourceRefs: <SourceRef>[source],
            ),
        'option': () => QuestionDraftV2(
              questionId: 'question_missing_option',
              kind: QuestionKind.singleChoice,
              stem: _text('stem'),
              options: <QuestionOption>[
                QuestionOption(
                  optionId: 'option_a',
                  label: 'A',
                  content: RichContent(nodes: <ContentNode>[image()]),
                ),
              ],
              sourceRefs: <SourceRef>[source],
            ),
        'answer': () => QuestionDraftV2(
              questionId: 'question_missing_answer',
              kind: QuestionKind.shortAnswer,
              stem: _text('stem'),
              answer: ContentAnswer(
                content: RichContent(nodes: <ContentNode>[image()]),
              ),
              sourceRefs: <SourceRef>[source],
            ),
        'explanation': () => QuestionDraftV2(
              questionId: 'question_missing_explanation',
              kind: QuestionKind.shortAnswer,
              stem: _text('stem'),
              explanation: RichContent(nodes: <ContentNode>[image()]),
              sourceRefs: <SourceRef>[source],
            ),
        'table cell': () => QuestionDraftV2(
              questionId: 'question_missing_table_cell',
              kind: QuestionKind.shortAnswer,
              stem: RichContent(nodes: <ContentNode>[tableWithImage()]),
              sourceRefs: <SourceRef>[source],
            ),
      };

      for (final entry in invalidDrafts.entries) {
        expect(
          entry.value,
          throwsFormatException,
          reason: entry.key,
        );
      }
    });
  });

  group('QuestionOption identity and labels', () {
    test('allows Unicode, duplicate, and explicitly empty labels', () {
      final draft = QuestionDraftV2(
        questionId: 'question_labels_001',
        kind: QuestionKind.singleChoice,
        stem: _text('synthetic'),
        options: [
          QuestionOption(
            optionId: 'option_001',
            label: '甲',
            content: _text('first'),
          ),
          QuestionOption(
            optionId: 'option_002',
            label: '甲',
            content: _text('second'),
          ),
          QuestionOption(
            optionId: 'option_003',
            label: '',
            content: RichContent(nodes: const <ContentNode>[]),
          ),
        ],
      );

      expect(draft.options.map((option) => option.label), ['甲', '甲', '']);
    });

    test('rejects ambiguous or unsafe structural identity', () {
      final duplicateIdOptions = [
        QuestionOption(
          optionId: 'option_001',
          label: 'A',
          content: _text('first'),
        ),
        QuestionOption(
          optionId: 'option_001',
          label: 'B',
          content: _text('second'),
        ),
      ];
      expect(
        () => QuestionDraftV2(
          questionId: 'question_001',
          kind: QuestionKind.singleChoice,
          stem: _text('synthetic'),
          options: duplicateIdOptions,
        ),
        throwsFormatException,
      );

      for (final invalidId in <String>[
        '',
        'question id',
        'a' * 129,
        r'C:\private\question.json',
        '/private/question.json',
        'file://question.json',
        'https://example.invalid/question',
      ]) {
        expect(
          () => QuestionDraftV2(
            questionId: invalidId,
            kind: QuestionKind.shortAnswer,
            stem: _text('synthetic'),
          ),
          throwsFormatException,
        );
      }

      for (final invalidOptionId in <String>['', 'option id', 'a' * 129]) {
        expect(
          () => QuestionOption(
            optionId: invalidOptionId,
            label: 'A',
            content: _text('synthetic'),
          ),
          throwsFormatException,
        );
      }

      for (final invalidLabel in <String>[
        ' A',
        'A ',
        'A\n',
        'A\u009bB',
        '界' * 33,
      ]) {
        expect(
          () => QuestionOption(
            optionId: 'option_001',
            label: invalidLabel,
            content: _text('synthetic'),
          ),
          throwsFormatException,
        );
      }

      for (final invalidNumber in <int>[0, -1]) {
        expect(
          () => QuestionDraftV2(
            questionId: 'question_001',
            kind: QuestionKind.shortAnswer,
            questionNumber: invalidNumber,
            stem: _text('synthetic'),
          ),
          throwsFormatException,
        );
      }
    });
  });

  group('QuestionAnswer value semantics', () {
    test('preserves single, multiple, duplicate, and unknown option IDs', () {
      final input = <String>['option_b', 'option_a', 'option_a', 'future_id'];
      final answer = ChoiceAnswer(optionIds: input);
      input
        ..clear()
        ..add('changed');

      expect(answer.optionIds, [
        'option_b',
        'option_a',
        'option_a',
        'future_id',
      ]);
      expect(() => answer.optionIds.add('later'), throwsUnsupportedError);
      expect(
        answer,
        ChoiceAnswer(
          optionIds: const [
            'option_b',
            'option_a',
            'option_a',
            'future_id',
          ],
        ),
      );
    });

    test('rejects empty or unsafe choice identity lists', () {
      expect(
        () => ChoiceAnswer(optionIds: const []),
        throwsFormatException,
      );
      expect(
        () => ChoiceAnswer(optionIds: const ['option id']),
        throwsFormatException,
      );
    });

    test('compares content answers by RichContent value', () {
      final first = ContentAnswer(content: _futureContent(reverseKeys: false));
      final equal = ContentAnswer(content: _futureContent(reverseKeys: true));
      final different = ContentAnswer(content: _text('different'));

      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect(different, isNot(first));
    });
  });

  group('QuestionDraftV2 defensive immutability and equality', () {
    test('copies and freezes every aggregate collection', () {
      final options = <QuestionOption>[
        QuestionOption(
          optionId: 'option_001',
          label: 'A',
          content: _text('first'),
        ),
      ];
      final sources = <SourceRef>[
        SourceRef.document(sourceId: 'source_001'),
      ];
      final assets = <SourcedAssetRef>[
        SourcedAssetRef(
          sourceId: 'source_001',
          asset: AssetRef(assetId: 'asset_001', kind: AssetKind.image),
        ),
      ];
      final issues = <ImportIssue>[
        ImportIssue(
          code: 'missing_answer',
          severity: ImportIssueSeverity.warning,
        ),
      ];
      final draft = QuestionDraftV2(
        questionId: 'question_001',
        kind: QuestionKind.singleChoice,
        stem: _text('synthetic'),
        options: options,
        sourceRefs: sources,
        assetRefs: assets,
        issues: issues,
      );
      final originalHash = draft.hashCode;

      options.clear();
      sources.clear();
      assets.clear();
      issues.clear();

      expect(draft.options, hasLength(1));
      expect(draft.sourceRefs, hasLength(1));
      expect(draft.assetRefs, hasLength(1));
      expect(draft.issues, hasLength(1));
      expect(draft.hashCode, originalHash);
      expect(() => draft.options.clear(), throwsUnsupportedError);
      expect(() => draft.sourceRefs.clear(), throwsUnsupportedError);
      expect(() => draft.assetRefs.clear(), throwsUnsupportedError);
      expect(() => draft.issues.clear(), throwsUnsupportedError);
    });

    test('compares all semantic fields and ordered RichContent deeply', () {
      final first = QuestionDraftV2(
        questionId: 'question_001',
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: _futureContent(reverseKeys: false),
        answer: ContentAnswer(content: _text('answer')),
        explanation: RichContent(nodes: const <ContentNode>[]),
      );
      final equal = QuestionDraftV2(
        questionId: 'question_001',
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: _futureContent(reverseKeys: true),
        answer: ContentAnswer(content: _text('answer')),
        explanation: RichContent(nodes: const <ContentNode>[]),
      );
      final nullExplanation = QuestionDraftV2(
        questionId: 'question_001',
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: _futureContent(reverseKeys: true),
        answer: ContentAnswer(content: _text('answer')),
      );
      final reorderedStem = QuestionDraftV2(
        questionId: 'question_001',
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: RichContent(nodes: [
          _futureNode(reverseKeys: true),
          const TextNode('prefix'),
        ]),
        answer: ContentAnswer(content: _text('answer')),
        explanation: RichContent(nodes: const <ContentNode>[]),
      );

      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect(<QuestionDraftV2>{first}, contains(equal));
      expect(nullExplanation, isNot(first));
      expect(reorderedStem, isNot(first));
    });
  });
}

RichContent _text(String value) {
  return RichContent(nodes: <ContentNode>[TextNode(value)]);
}

RichContent _futureContent({required bool reverseKeys}) {
  return RichContent(nodes: <ContentNode>[
    const TextNode('prefix'),
    _futureNode(reverseKeys: reverseKeys),
  ]);
}

RawFallbackNode _futureNode({required bool reverseKeys}) {
  final payload = reverseKeys
      ? <Object?, Object?>{
          'enabled': true,
          'items': <Object?>[1, null, 'x'],
        }
      : <Object?, Object?>{
          'items': <Object?>[1, null, 'x'],
          'enabled': true,
        };
  return RawFallbackNode(<Object?, Object?>{
    'type': 'future_diagram',
    'payload': payload,
  });
}
