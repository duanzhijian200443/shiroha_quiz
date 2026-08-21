import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

const mapper = QuestionV2PersistenceMapper();
const codec = QuestionDraftV2Codec();

const storageIdA = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
const storageIdB = 'b4f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
const bankName = 'synthetic_bank';

RichContent _textContent(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

QuestionDraftV2 _fullChoiceDraft() {
  return QuestionDraftV2(
    questionId: 'question_001',
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _textContent('Synthetic stem text.'),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'A',
        label: '甲',
        content: _textContent('first'),
      ),
      QuestionOption(
        optionId: 'B',
        label: '乙',
        content: _textContent('second'),
      ),
      QuestionOption(
        optionId: 'C',
        label: '丙',
        content: _textContent('third'),
      ),
    ],
    answer: ChoiceAnswer(optionIds: <String>['B', 'C']),
    explanation: _textContent('Synthetic explanation.'),
    sourceRefs: <SourceRef>[
      SourceRef.document(
        sourceId: 'source_001',
        displayLabel: 'synthetic.pdf',
      ),
      SourceRef.at(
        sourceId: 'source_001',
        point: SourcePoint.page(pageNumber: 1),
      ),
    ],
    assetRefs: <SourcedAssetRef>[
      SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(assetId: 'asset_000001', kind: AssetKind.image),
      ),
    ],
    issues: <ImportIssue>[
      ImportIssue(
        code: 'missing_option_a',
        severity: ImportIssueSeverity.warning,
        field: ImportIssueField.options,
      ),
    ],
  );
}

Map<String, Object?> _joinedRow(FrozenQuestionV2Write frozen) {
  return <String, Object?>{
    ...frozen.questionRow,
    QuestionV2PersistenceMapper.payloadSchemaVersionAlias:
        frozen.payloadRow['payload_schema_version'],
    QuestionV2PersistenceMapper.payloadJsonAlias:
        frozen.payloadRow['payload_json'],
  };
}

Map<String, Object?> _typedRow(QuestionDraftV2 draft) {
  final frozen = mapper.freezeForWrite(
    storageId: storageIdA,
    bankName: bankName,
    createdAt: 1700000000,
    draft: draft,
  );
  return _joinedRow(frozen);
}

Map<String, Object?> _unsafeNodeJson() {
  return <String, Object?>{
    'type': 'future_diagram',
    'providerResponse': <String, Object?>{'status': 'synthetic'},
  };
}

RichContent _unsafeContent() {
  return RichContent(nodes: <ContentNode>[
    RawFallbackNode(<Object?, Object?>{
      'type': 'future_diagram',
      'providerResponse': <Object?, Object?>{'status': 'synthetic'},
    }),
  ]);
}

RichContent _imageContent() {
  return RichContent(nodes: <ContentNode>[
    ImageNode(sourceId: 'source_001', localAssetId: 'asset_000001'),
  ]);
}

QuestionDraftV2 _imageDraft({
  RichContent? stem,
  Iterable<QuestionOption> options = const <QuestionOption>[],
  QuestionAnswer? answer,
  RichContent? explanation,
}) {
  return QuestionDraftV2(
    questionId: 'image_question',
    kind:
        options.isEmpty ? QuestionKind.shortAnswer : QuestionKind.singleChoice,
    stem: stem ?? _textContent('Stem.'),
    options: options,
    answer: answer,
    explanation: explanation,
    sourceRefs: <SourceRef>[
      SourceRef.document(
        sourceId: 'source_001',
        displayLabel: 'synthetic.pdf',
      ),
    ],
    assetRefs: <SourcedAssetRef>[
      SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(assetId: 'asset_000001', kind: AssetKind.image),
      ),
    ],
  );
}

RichContent _textTableContent() {
  return RichContent(nodes: <ContentNode>[
    TableNode(
      structure: TableStructure(rows: <TableRow>[
        TableRow(cells: <TableCell>[
          TableCell(content: _textContent('cell')),
        ]),
      ]),
    ),
  ]);
}

RichContent _imageTableContent() {
  return RichContent(nodes: <ContentNode>[
    TableNode(
      structure: TableStructure(rows: <TableRow>[
        TableRow(cells: <TableCell>[
          TableCell(content: _imageContent()),
        ]),
      ]),
    ),
  ]);
}

void main() {
  group('freezeForWrite V1 compatibility row', () {
    test('projects the typed draft with structural equality round trip', () {
      final draft = _fullChoiceDraft();
      final frozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: '  $bankName  ',
        createdAt: 1700000000,
        draft: draft,
      );

      expect(frozen.questionRow['id'], storageIdA);
      expect(frozen.questionRow['bank_name'], bankName);
      expect(frozen.questionRow['created_at'], 1700000000);
      expect(frozen.questionRow['type'], 0);
      expect(frozen.questionRow['content'], 'Synthetic stem text.');
      expect(frozen.questionRow['raw_explanation'], isNull);
      expect(
        jsonDecode(frozen.questionRow['options']! as String),
        <String>['甲. first', '乙. second', '丙. third'],
      );
      expect(
        frozen.questionRow['standard_answer'],
        '乙,丙|||Synthetic explanation.',
      );
      expect(frozen.questionRow['explanation'], 'Synthetic explanation.');
      expect(
        frozen.payloadRow['payload_schema_version'],
        QuestionDraftV2Codec.schemaVersion,
      );
      expect(
        frozen.payloadRow['payload_json'] as String,
        jsonEncode(codec.encode(draft)),
      );

      final decoded = mapper.decodeJoinedRow(_joinedRow(frozen));
      expect(decoded, isA<TypedPersistedQuestion>());
      final typed = decoded as TypedPersistedQuestion;
      expect(typed.storageId, storageIdA);
      expect(typed.bankName, bankName);
      expect(typed.createdAt, 1700000000);
      expect(typed.draft, draft);
      expect(typed.draft.hashCode, draft.hashCode);
    });

    test('preserves source refs, assets, and issues in V2 only', () {
      final draft = _fullChoiceDraft();
      final frozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1700000000,
        draft: draft,
      );

      expect(frozen.questionRow.keys.toSet(), <String>{
        'id',
        'type',
        'content',
        'options',
        'standard_answer',
        'created_at',
        'bank_name',
        'explanation',
        'raw_explanation',
      });

      final decoded = mapper.decodeJoinedRow(_joinedRow(frozen));
      final typed = decoded as TypedPersistedQuestion;
      expect(typed.draft.sourceRefs, draft.sourceRefs);
      expect(typed.draft.assetRefs, draft.assetRefs);
      expect(typed.draft.issues, draft.issues);
    });

    test('writes exact physical payloadRow columns and values', () {
      final draft = _fullChoiceDraft();
      final frozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1700000000,
        draft: draft,
      );

      expect(frozen.payloadRow.keys.toSet(), <String>{
        'question_id',
        'payload_schema_version',
        'payload_json',
      });
      expect(frozen.payloadRow['question_id'], storageIdA);
      expect(
        frozen.payloadRow['payload_schema_version'],
        QuestionDraftV2Codec.schemaVersion,
      );
      expect(
        frozen.payloadRow['payload_json'] as String,
        jsonEncode(codec.encode(draft)),
      );
    });

    test('allows duplicate draft questionIds under distinct storage ids', () {
      final draft = _fullChoiceDraft();
      final first = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1,
        draft: draft,
      );
      final second = mapper.freezeForWrite(
        storageId: storageIdB,
        bankName: bankName,
        createdAt: 2,
        draft: draft,
      );

      expect(first.questionRow['id'], storageIdA);
      expect(second.questionRow['id'], storageIdB);
      final decodedA = mapper.decodeJoinedRow(_joinedRow(first));
      final decodedB = mapper.decodeJoinedRow(_joinedRow(second));
      expect(decodedA.storageId, storageIdA);
      expect(decodedB.storageId, storageIdB);
      expect((decodedA as TypedPersistedQuestion).draft.questionId,
          'question_001');
      expect((decodedB as TypedPersistedQuestion).draft.questionId,
          'question_001');
      expect(decodedA.draft, decodedB.draft);
    });

    test('projects every QuestionKind to its legacy type code', () {
      final cases = <(QuestionKind, int)>[
        (QuestionKind.singleChoice, 0),
        (QuestionKind.fillBlank, 2),
        (QuestionKind.shortAnswer, 3),
      ];
      for (final (kind, type) in cases) {
        final draft = QuestionDraftV2(
          questionId: 'question_kind',
          kind: kind,
          stem: _textContent('Synthetic stem.'),
        );
        final frozen = mapper.freezeForWrite(
          storageId: storageIdA,
          bankName: bankName,
          createdAt: 1,
          draft: draft,
        );
        expect(frozen.questionRow['type'], type, reason: '$kind');
      }
    });

    test('projects choice answers by label, identity fallback, and order', () {
      final draft = QuestionDraftV2(
        questionId: 'question_choice',
        kind: QuestionKind.singleChoice,
        stem: _textContent('Stem.'),
        options: <QuestionOption>[
          QuestionOption(optionId: 'A', label: '甲', content: _textContent('1')),
          QuestionOption(optionId: 'B', label: '乙', content: _textContent('2')),
          QuestionOption(optionId: 'C', label: '丙', content: _textContent('3')),
          QuestionOption(optionId: 'D', label: '丁', content: _textContent('4')),
        ],
        answer: ChoiceAnswer(optionIds: <String>['D', 'B']),
      );
      final frozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1,
        draft: draft,
      );
      expect(frozen.questionRow['standard_answer'], '丁,乙|||');

      final unknown = QuestionDraftV2(
        questionId: 'question_choice_unknown',
        kind: QuestionKind.singleChoice,
        stem: _textContent('Stem.'),
        options: <QuestionOption>[
          QuestionOption(optionId: 'A', label: '甲', content: _textContent('1')),
          QuestionOption(optionId: 'B', label: '乙', content: _textContent('2')),
        ],
        answer: ChoiceAnswer(optionIds: <String>['B', 'X', 'A']),
      );
      final frozenUnknown = mapper.freezeForWrite(
        storageId: storageIdB,
        bankName: bankName,
        createdAt: 1,
        draft: unknown,
      );
      expect(frozenUnknown.questionRow['standard_answer'], '乙,X,甲|||');
    });

    test('projects ContentAnswer and null answer to V1 text', () {
      final contentDraft = QuestionDraftV2(
        questionId: 'question_content_answer',
        kind: QuestionKind.shortAnswer,
        stem: _textContent('Stem.'),
        answer: ContentAnswer(content: _textContent('answer text')),
      );
      final contentFrozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1,
        draft: contentDraft,
      );
      expect(contentFrozen.questionRow['standard_answer'], 'answer text|||');

      final nullDraft = QuestionDraftV2(
        questionId: 'question_null_answer',
        kind: QuestionKind.fillBlank,
        stem: _textContent('Stem.'),
      );
      final nullFrozen = mapper.freezeForWrite(
        storageId: storageIdB,
        bankName: bankName,
        createdAt: 1,
        draft: nullDraft,
      );
      expect(nullFrozen.questionRow['standard_answer'], '|||');
    });

    test('replaces literal ||| in answers and keeps V2 lossless', () {
      final draft = QuestionDraftV2(
        questionId: 'question_pipe',
        kind: QuestionKind.shortAnswer,
        stem: _textContent('Stem.'),
        answer: ContentAnswer(content: _textContent('A ||| B')),
        explanation: _textContent('why'),
      );
      final frozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1,
        draft: draft,
      );

      expect(frozen.questionRow['standard_answer'], 'A ｜｜｜ B|||why');
      final decoded = mapper.decodeJoinedRow(_joinedRow(frozen));
      final answer =
          (decoded as TypedPersistedQuestion).draft.answer as ContentAnswer;
      expect((answer.content.nodes.single as TextNode).text, 'A ||| B');
    });

    test('distinguishes null and empty explanations in V1 and V2', () {
      final nullDraft = QuestionDraftV2(
        questionId: 'question_null_explanation',
        kind: QuestionKind.shortAnswer,
        stem: _textContent('Stem.'),
        answer: ContentAnswer(content: _textContent('x')),
      );
      final nullFrozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1,
        draft: nullDraft,
      );
      expect(nullFrozen.questionRow['explanation'], '');
      expect(nullFrozen.questionRow['standard_answer'], 'x|||');
      expect(
        nullFrozen.payloadRow['payload_json'] as String,
        contains('"explanation":null'),
      );
      final nullDecoded = mapper.decodeJoinedRow(_joinedRow(nullFrozen));
      expect((nullDecoded as TypedPersistedQuestion).draft.explanation, isNull);

      final emptyDraft = QuestionDraftV2(
        questionId: 'question_empty_explanation',
        kind: QuestionKind.shortAnswer,
        stem: _textContent('Stem.'),
        answer: ContentAnswer(content: _textContent('x')),
        explanation: RichContent(nodes: const <ContentNode>[]),
      );
      final emptyFrozen = mapper.freezeForWrite(
        storageId: storageIdB,
        bankName: bankName,
        createdAt: 1,
        draft: emptyDraft,
      );
      expect(emptyFrozen.questionRow['explanation'], '');
      expect(
        emptyFrozen.payloadRow['payload_json'] as String,
        contains('"explanation":{"schemaVersion":1,"nodes":[]}'),
      );
      final emptyDecoded = mapper.decodeJoinedRow(_joinedRow(emptyFrozen));
      final emptyExplanation =
          (emptyDecoded as TypedPersistedQuestion).draft.explanation;
      expect(emptyExplanation, isNotNull);
      expect(emptyExplanation!.nodes, isEmpty);
    });

    test('uses the empty-stem placeholder for trim-empty stems', () {
      for (final stem in <RichContent>[
        _textContent('   '),
        RichContent(nodes: const <ContentNode>[]),
      ]) {
        final draft = QuestionDraftV2(
          questionId: 'question_empty_stem',
          kind: QuestionKind.fillBlank,
          stem: stem,
        );
        final frozen = mapper.freezeForWrite(
          storageId: storageIdA,
          bankName: bankName,
          createdAt: 1,
          draft: draft,
        );
        expect(frozen.questionRow['content'], '无题干');
      }
    });

    test('preserves non-empty stems with leading and trailing whitespace', () {
      final draft = QuestionDraftV2(
        questionId: 'question_padded_stem',
        kind: QuestionKind.fillBlank,
        stem: _textContent('  Padded stem text.  '),
      );
      final frozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1,
        draft: draft,
      );

      expect(frozen.questionRow['content'], '  Padded stem text.  ');
      final legacy = Question.fromMap(
        Map<String, dynamic>.from(frozen.questionRow),
      );
      expect(legacy.content, '  Padded stem text.  ');

      final decoded = mapper.decodeJoinedRow(_joinedRow(frozen));
      final typed = decoded as TypedPersistedQuestion;
      expect(
        (typed.draft.stem.nodes.single as TextNode).text,
        '  Padded stem text.  ',
      );
    });

    test('normalizes every stored V1 projection exactly once', () {
      final draft = QuestionDraftV2(
        questionId: 'question_normalize',
        kind: QuestionKind.shortAnswer,
        stem: _textContent(r'line1\n line2'),
        answer: ContentAnswer(content: _textContent(r'\\sqrt{2}')),
        explanation: _textContent(r'<think>hidden</think>shown'),
      );
      final frozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1,
        draft: draft,
      );

      expect(frozen.questionRow['content'], 'line1\n line2');
      expect(frozen.questionRow['standard_answer'], r'\sqrt{2}|||shown');
      expect(frozen.questionRow['explanation'], 'shown');

      final decoded = mapper.decodeJoinedRow(_joinedRow(frozen));
      final typed = decoded as TypedPersistedQuestion;
      expect(
        (typed.draft.stem.nodes.single as TextNode).text,
        r'line1\n line2',
      );
      expect(
        ((typed.draft.answer! as ContentAnswer).content.nodes.single
                as TextNode)
            .text,
        r'\\sqrt{2}',
      );
    });

    test('characterizes TextNode legacy reinterpretation through Question', () {
      final draft = QuestionDraftV2(
        questionId: 'question_legacy_text',
        kind: QuestionKind.shortAnswer,
        stem: RichContent(nodes: const <ContentNode>[
          TextNode('x'),
          InlineMathNode('y'),
          BlockMathNode('z'),
          TextNode('!'),
        ]),
        answer: ContentAnswer(
          content: RichContent(nodes: const <ContentNode>[TextNode('a')]),
        ),
      );
      final frozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1,
        draft: draft,
      );

      expect(frozen.questionRow['content'], r'x\(y\)\[z\]!');
      final legacy = Question.fromMap(
        Map<String, dynamic>.from(frozen.questionRow),
      );
      expect(legacy.id, storageIdA);
      expect(legacy.type, 3);
      expect(legacy.content, r'x\(y\)\[z\]!');
      expect(legacy.answer, 'a');
    });
  });

  group('freezeForWrite RawFallback projection', () {
    test('preserves V2 raw fallback exactly with a fixed V1 placeholder', () {
      final rawJson = <Object?, Object?>{
        'type': 'future_diagram',
        'payload': <Object?, Object?>{
          'shape': 'synthetic',
          'items': <Object?>[1, 2],
        },
      };
      final draft = QuestionDraftV2(
        questionId: 'question_fallback',
        kind: QuestionKind.shortAnswer,
        stem: RichContent(nodes: <ContentNode>[
          const TextNode('before '),
          RawFallbackNode(rawJson),
          const TextNode(' after'),
        ]),
        answer: ContentAnswer(
          content: RichContent(nodes: <ContentNode>[RawFallbackNode(rawJson)]),
        ),
        explanation: RichContent(
          nodes: <ContentNode>[RawFallbackNode(rawJson)],
        ),
      );
      final frozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1,
        draft: draft,
      );

      expect(
          frozen.questionRow['content'], 'before [Unsupported content] after');
      expect(frozen.questionRow['standard_answer'],
          '[Unsupported content]|||[Unsupported content]');
      expect(frozen.questionRow['explanation'], '[Unsupported content]');
      final v1Text = <String>[
        frozen.questionRow['content']! as String,
        frozen.questionRow['standard_answer']! as String,
        frozen.questionRow['explanation']! as String,
        frozen.questionRow['options']! as String,
      ].join('\n');
      expect(v1Text, isNot(contains('future_diagram')));
      expect(v1Text, isNot(contains('shape')));
      expect(v1Text, isNot(contains('synthetic')));
      expect(v1Text, isNot(contains('payload')));

      final payloadJson = frozen.payloadRow['payload_json'] as String;
      expect(payloadJson, contains('future_diagram'));
      expect(payloadJson, contains('"shape":"synthetic"'));

      final decoded = mapper.decodeJoinedRow(_joinedRow(frozen));
      final typed = decoded as TypedPersistedQuestion;
      expect(typed.draft, draft);
      final stemFallback = typed.draft.stem.nodes[1] as RawFallbackNode;
      expect(stemFallback.rawJson, rawJson);
      final answerFallback = ((typed.draft.answer! as ContentAnswer)
              .content
              .nodes
              .single as RawFallbackNode)
          .rawJson;
      expect(answerFallback, rawJson);
    });
  });

  group('freezeForWrite write guards', () {
    test('blocks non-canonical storage ids with redacted diagnostics', () {
      final draft = _fullChoiceDraft();
      for (final invalid in <String>[
        'NOT-A-CANONICAL-UUID',
        storageIdA.toUpperCase(),
        'a3f9c2e4-5b6d-3e7f-8a9b-0c1d2e3f4a5b',
        'a3f9c2e45b6d4e7f8a9b0c1d2e3f4a5b',
      ]) {
        try {
          mapper.freezeForWrite(
            storageId: invalid,
            bankName: bankName,
            createdAt: 1,
            draft: draft,
          );
          fail('expected a blocked write for $invalid');
        } on QuestionV2LegacyMutationBlockedException catch (error) {
          expect(error.toString(), contains('redacted_storage_id'));
          expect(error.toString(), isNot(contains(invalid)));
        }
      }
    });

    test('blocks trim-empty bank names', () {
      final draft = _fullChoiceDraft();
      for (final invalid in <String>['', '   ']) {
        expect(
          () => mapper.freezeForWrite(
            storageId: storageIdA,
            bankName: invalid,
            createdAt: 1,
            draft: draft,
          ),
          throwsA(isA<QuestionV2LegacyMutationBlockedException>()),
        );
      }
    });

    test('rejects unsafe content in every public RichContent slot', () {
      final unsafe = _unsafeContent();
      final drafts = <QuestionDraftV2>[
        QuestionDraftV2(
          questionId: 'question_unsafe_stem',
          kind: QuestionKind.shortAnswer,
          stem: unsafe,
        ),
        QuestionDraftV2(
          questionId: 'question_unsafe_option',
          kind: QuestionKind.singleChoice,
          stem: _textContent('Stem.'),
          options: <QuestionOption>[
            QuestionOption(optionId: 'A', label: '甲', content: unsafe),
          ],
        ),
        QuestionDraftV2(
          questionId: 'question_unsafe_answer',
          kind: QuestionKind.shortAnswer,
          stem: _textContent('Stem.'),
          answer: ContentAnswer(content: unsafe),
        ),
        QuestionDraftV2(
          questionId: 'question_unsafe_explanation',
          kind: QuestionKind.shortAnswer,
          stem: _textContent('Stem.'),
          explanation: unsafe,
        ),
      ];
      for (final draft in drafts) {
        try {
          mapper.freezeForWrite(
            storageId: storageIdA,
            bankName: bankName,
            createdAt: 1,
            draft: draft,
          );
          fail('expected unsafe write rejection for ${draft.questionId}');
        } on QuestionV2PayloadException catch (error) {
          expect(
            error.failure,
            QuestionV2PayloadFailure.unsafePayload,
            reason: draft.questionId,
          );
          expect(error.toString(), isNot(contains('providerResponse')));
          expect(error.toString(), isNot(contains('synthetic')));
        }
      }
    });

    test('blocks reachable ImageNode writes at both shared write entry points',
        () {
      final image = _imageContent();
      final imageDrafts = <String, QuestionDraftV2>{
        'stem': _imageDraft(stem: image),
        'option': _imageDraft(
          options: <QuestionOption>[
            QuestionOption(optionId: 'A', label: '甲', content: image),
          ],
          answer: ChoiceAnswer(optionIds: const <String>['A']),
        ),
        'answer': _imageDraft(answer: ContentAnswer(content: image)),
        'explanation': _imageDraft(explanation: image),
        'table cell': _imageDraft(stem: _imageTableContent()),
      };

      for (final entry in imageDrafts.entries) {
        final operations = <void Function()>[
          () => mapper.freezeForWrite(
                storageId: storageIdA,
                bankName: bankName,
                createdAt: 1,
                draft: entry.value,
              ),
          () => mapper.freezeAnswerUpdate(
                storageId: storageIdA,
                replacementDraft: entry.value,
              ),
        ];
        for (final operation in operations) {
          try {
            operation();
            fail('expected ImageNode write rejection for ${entry.key}');
          } on QuestionV2PayloadException catch (error) {
            expect(error.failure, QuestionV2PayloadFailure.unsafePayload);
            expect(error.toString(), isNot(contains('source_001')));
            expect(error.toString(), isNot(contains('asset_000001')));
          }
        }
      }
    });

    test('allows text and math-only TableNode writes', () {
      final draft = _imageDraft(stem: _textTableContent());

      expect(
        () => mapper.freezeForWrite(
          storageId: storageIdA,
          bankName: bankName,
          createdAt: 1,
          draft: draft,
        ),
        returnsNormally,
      );
      expect(
        () => mapper.freezeAnswerUpdate(
          storageId: storageIdA,
          replacementDraft: draft,
        ),
        returnsNormally,
      );
    });
  });

  group('decodeJoinedRow typed decode order', () {
    test('decodes legacy rows when both aliases are absent', () {
      final row = <String, Object?>{
        'id': '123',
        'type': 0,
        'content': 'legacy stem',
        'options': jsonEncode(<String>['A. one', 'B. two']),
        'standard_answer': 'fallback|||old explanation',
        'created_at': 42,
        'bank_name': 'legacy_bank',
        'explanation': 'independent explanation',
        'raw_explanation': 'raw',
      };

      final decoded = mapper.decodeJoinedRow(row);
      expect(decoded, isA<LegacyPersistedQuestion>());
      final legacy = decoded as LegacyPersistedQuestion;
      expect(legacy.storageId, '123');
      expect(legacy.bankName, 'legacy_bank');
      expect(legacy.createdAt, 42);
      expect(legacy.question.id, '123');
      expect(legacy.question.answer, 'fallback');
      expect(legacy.question.explanation, 'independent explanation');
      expect(legacy.question.rawExplanation, 'raw');
    });

    test('keeps legal ImageNode sidecars readable without the write gate', () {
      final imageDraft = _imageDraft(stem: _imageContent());
      final base = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1,
        draft: _fullChoiceDraft(),
      );
      final row = <String, Object?>{
        ...base.questionRow,
        QuestionV2PersistenceMapper.payloadSchemaVersionAlias:
            QuestionDraftV2Codec.schemaVersion,
        QuestionV2PersistenceMapper.payloadJsonAlias:
            jsonEncode(codec.encode(imageDraft)),
      };

      final decoded = mapper.decodeJoinedRow(row);
      expect(decoded, isA<TypedPersistedQuestion>());
      expect((decoded as TypedPersistedQuestion).draft, imageDraft);
    });

    test('fails with invalidPayload for partial aliases', () {
      final base = _typedRow(_fullChoiceDraft());
      final missingJson = <String, Object?>{
        ...base,
        QuestionV2PersistenceMapper.payloadJsonAlias: null,
      };
      final missingVersion = <String, Object?>{
        ...base,
        QuestionV2PersistenceMapper.payloadSchemaVersionAlias: null,
      };

      for (final row in <Map<String, Object?>>[missingJson, missingVersion]) {
        try {
          mapper.decodeJoinedRow(row);
          fail('expected invalidPayload');
        } on QuestionV2PayloadException catch (error) {
          expect(error.failure, QuestionV2PayloadFailure.invalidPayload);
        }
      }
    });

    test('redacts non-canonical typed storage ids on read', () {
      final row = _typedRow(_fullChoiceDraft());
      final invalidValues = <String>[
        'NOT-A-CANONICAL-UUID',
        storageIdA.toUpperCase(),
      ];
      for (final invalid in invalidValues) {
        final invalidRow = <String, Object?>{...row, 'id': invalid};
        try {
          mapper.decodeJoinedRow(invalidRow);
          fail('expected invalidPayload for $invalid');
        } on QuestionV2PayloadException catch (error) {
          expect(error.failure, QuestionV2PayloadFailure.invalidPayload);
          expect(error.toString(), contains('redacted_storage_id'));
          expect(error.toString(), isNot(contains(invalid)));
        }
      }
    });

    test('fails on invalid parent metadata and sidecar version columns', () {
      final base = _typedRow(_fullChoiceDraft());
      final invalidRows = <String, Map<String, Object?>>{
        'empty bank': <String, Object?>{...base, 'bank_name': ''},
        'missing bank': <String, Object?>{...base}..remove('bank_name'),
        'wrong created_at': <String, Object?>{...base, 'created_at': '1'},
        'missing created_at': <String, Object?>{...base}..remove('created_at'),
        'zero version': <String, Object?>{
          ...base,
          QuestionV2PersistenceMapper.payloadSchemaVersionAlias: 0,
        },
        'negative version': <String, Object?>{
          ...base,
          QuestionV2PersistenceMapper.payloadSchemaVersionAlias: -1,
        },
        'string version': <String, Object?>{
          ...base,
          QuestionV2PersistenceMapper.payloadSchemaVersionAlias: '2',
        },
      };
      for (final entry in invalidRows.entries) {
        try {
          mapper.decodeJoinedRow(entry.value);
          fail('expected invalidPayload for ${entry.key}');
        } on QuestionV2PayloadException catch (error) {
          expect(
            error.failure,
            QuestionV2PayloadFailure.invalidPayload,
            reason: entry.key,
          );
        }
      }
    });

    test('maps malformed JSON and invalid roots to the right failures', () {
      final base = _typedRow(_fullChoiceDraft());

      final malformed = <String, Object?>{
        ...base,
        QuestionV2PersistenceMapper.payloadJsonAlias: '{oops',
      };
      try {
        mapper.decodeJoinedRow(malformed);
        fail('expected malformedJson');
      } on QuestionV2PayloadException catch (error) {
        expect(error.failure, QuestionV2PayloadFailure.malformedJson);
        expect(error.toString(), isNot(contains('{oops')));
      }

      final nonStringPayload = <String, Object?>{
        ...base,
        QuestionV2PersistenceMapper.payloadJsonAlias: 42,
      };
      expect(
        () => mapper.decodeJoinedRow(nonStringPayload),
        throwsA(
          isA<QuestionV2PayloadException>().having(
            (error) => error.failure,
            'failure',
            QuestionV2PayloadFailure.invalidPayload,
          ),
        ),
      );

      for (final rootJson in <String>['[]', 'null', '{"schemaVersion":"2"}']) {
        final invalidRoot = <String, Object?>{
          ...base,
          QuestionV2PersistenceMapper.payloadJsonAlias: rootJson,
        };
        try {
          mapper.decodeJoinedRow(invalidRoot);
          fail('expected invalidPayload for $rootJson');
        } on QuestionV2PayloadException catch (error) {
          expect(error.failure, QuestionV2PayloadFailure.invalidPayload);
        }
      }
    });

    test('reports schema mismatch and unsupported root versions', () {
      final base = _typedRow(_fullChoiceDraft());
      final payloadJson =
          base[QuestionV2PersistenceMapper.payloadJsonAlias]! as String;
      final mismatched =
          payloadJson.replaceAll('"schemaVersion":2', '"schemaVersion":3');
      final mismatchRow = <String, Object?>{
        ...base,
        QuestionV2PersistenceMapper.payloadJsonAlias: mismatched,
      };
      try {
        mapper.decodeJoinedRow(mismatchRow);
        fail('expected schemaMismatch');
      } on QuestionV2PayloadException catch (error) {
        expect(error.failure, QuestionV2PayloadFailure.schemaMismatch);
      }

      final unsupportedRow = <String, Object?>{
        ...base,
        QuestionV2PersistenceMapper.payloadSchemaVersionAlias: 3,
        QuestionV2PersistenceMapper.payloadJsonAlias: mismatched,
      };
      try {
        mapper.decodeJoinedRow(unsupportedRow);
        fail('expected unsupportedSchema');
      } on QuestionV2PayloadException catch (error) {
        expect(error.failure, QuestionV2PayloadFailure.unsupportedSchema);
        expect(error.toString(), isNot(contains('"schemaVersion":3')));
      }
    });

    test('fails with invalidPayload on nested unsupported RichContent', () {
      final base = _typedRow(_fullChoiceDraft());
      final payloadJson =
          base[QuestionV2PersistenceMapper.payloadJsonAlias]! as String;
      final root = jsonDecode(payloadJson) as Map<String, dynamic>;
      root['stem'] = <String, Object?>{
        'schemaVersion': 3,
        'nodes': <Object?>[],
      };
      final nestedRow = <String, Object?>{
        ...base,
        QuestionV2PersistenceMapper.payloadJsonAlias: jsonEncode(root),
      };
      try {
        mapper.decodeJoinedRow(nestedRow);
        fail('expected invalidPayload');
      } on QuestionV2PayloadException catch (error) {
        expect(error.failure, QuestionV2PayloadFailure.invalidPayload);
      }
    });

    test('rejects unsafe content in every public RichContent slot on read', () {
      final base = _typedRow(_fullChoiceDraft());
      final unsafeNode = _unsafeNodeJson();
      final unsafeStem = <String, Object?>{
        'schemaVersion': 1,
        'nodes': <Object?>[unsafeNode],
      };
      final slots = <String, Object?>{
        'stem': unsafeStem,
        'option': <String, Object?>{
          'optionId': 'A',
          'label': '甲',
          'content': unsafeStem,
          'sourceRef': null,
        },
        'answer': <String, Object?>{
          'type': 'content',
          'content': unsafeStem,
        },
        'explanation': unsafeStem,
      };
      for (final entry in slots.entries) {
        final root = jsonDecode(
                base[QuestionV2PersistenceMapper.payloadJsonAlias]! as String)
            as Map<String, dynamic>;
        switch (entry.key) {
          case 'stem':
            root['stem'] = entry.value;
          case 'option':
            root['options'] = <Object?>[entry.value];
          case 'answer':
            root['answer'] = entry.value;
          case 'explanation':
            root['explanation'] = entry.value;
        }
        final unsafeRow = <String, Object?>{
          ...base,
          QuestionV2PersistenceMapper.payloadJsonAlias: jsonEncode(root),
        };
        try {
          mapper.decodeJoinedRow(unsafeRow);
          fail('expected unsafePayload for slot ${entry.key}');
        } on QuestionV2PayloadException catch (error) {
          expect(
            error.failure,
            QuestionV2PayloadFailure.unsafePayload,
            reason: entry.key,
          );
        }
      }
    });

    test('never falls back to legacy for a corrupt sidecar', () {
      final base = _typedRow(_fullChoiceDraft());
      final corrupt = <String, Object?>{
        ...base,
        QuestionV2PersistenceMapper.payloadJsonAlias: '{corrupt',
      };
      try {
        mapper.decodeJoinedRow(corrupt);
        fail('expected malformedJson');
      } on QuestionV2PayloadException catch (error) {
        expect(error.failure, QuestionV2PayloadFailure.malformedJson);
      }
    });
  });

  group('FrozenQuestionV2Write immutability', () {
    test('exposes unmodifiable question and payload rows', () {
      final frozen = mapper.freezeForWrite(
        storageId: storageIdA,
        bankName: bankName,
        createdAt: 1,
        draft: _fullChoiceDraft(),
      );

      expect(
        () => frozen.questionRow['id'] = 'changed',
        throwsUnsupportedError,
      );
      expect(
        () => frozen.payloadRow['id'] = 'changed',
        throwsUnsupportedError,
      );
    });
  });

  group('exception contract', () {
    test('payload exception renders fixed safe text for every failure', () {
      const expected = <QuestionV2PayloadFailure, String>{
        QuestionV2PayloadFailure.malformedJson:
            'QuestionV2PayloadException(malformedJson): '
                'The V2 sidecar payload is not valid JSON.',
        QuestionV2PayloadFailure.unsupportedSchema:
            'QuestionV2PayloadException(unsupportedSchema): '
                'The V2 payload schema is not supported.',
        QuestionV2PayloadFailure.schemaMismatch:
            'QuestionV2PayloadException(schemaMismatch): '
                'The V2 sidecar schema version and payload root disagree.',
        QuestionV2PayloadFailure.invalidPayload:
            'QuestionV2PayloadException(invalidPayload): '
                'The V2 payload cannot be read safely.',
        QuestionV2PayloadFailure.unsafePayload:
            'QuestionV2PayloadException(unsafePayload): '
                'The V2 payload contains unsafe content.',
      };
      for (final entry in expected.entries) {
        expect(
          QuestionV2PayloadException(entry.key).toString(),
          entry.value,
          reason: entry.key.name,
        );
      }
    });

    test('payload exception exposes no arbitrary message', () {
      const error = QuestionV2PayloadException(
        QuestionV2PayloadFailure.invalidPayload,
      );
      expect(error.failure, QuestionV2PayloadFailure.invalidPayload);
      expect(
        () => (error as dynamic).message,
        throwsA(isA<NoSuchMethodError>()),
      );
    });

    test('legacy mutation exception default is fixed for R6C', () {
      const error = QuestionV2LegacyMutationBlockedException();
      expect(
        error.toString(),
        'QuestionV2LegacyMutationBlockedException: '
        'V2 persistence requires a canonical storage identity.',
      );
      expect(
        () => (error as dynamic).message,
        throwsA(isA<NoSuchMethodError>()),
      );
    });
  });
}
