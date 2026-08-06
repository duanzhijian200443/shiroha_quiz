// R7C builder contract: TypedReviewResultBuilder pure logic over strict
// envelope recovery and ReviewSession transitions. Synthetic fixtures only;
// no Provider, Replay, network, database, UI, filesystem or application
// call site, so Provider calls are 0 by construction.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/review_session.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';

const _sourceId = '11111111-1111-4111-8111-111111111111';
const _questionId = '22222222-2222-4222-8222-222222222222';
const _reviewItemId = '44444444-4444-4444-8444-444444444444';
const _questionIdB = '33333333-3333-4333-8333-333333333333';
const _reviewItemIdB = '55555555-5555-4555-8555-555555555555';
const _taskId = 'r7c-test-task';
const _attemptToken = 'r7c-test-attempt';
const _sessionId = 'review_test_session_0001';
const _secretMarker = 'super-secret-marker';
const _missingEnvelopeSentinel = Object();

const _codec = TypedReviewSnapshotCodec();

List<SourceRef> _sourceRefs() {
  return <SourceRef>[
    SourceRef.document(sourceId: _sourceId, displayLabel: null),
    SourceRef.at(
      sourceId: _sourceId,
      point: SourcePoint.page(pageNumber: 1),
    ),
  ];
}

List<QuestionOption> _options() {
  return <QuestionOption>[
    QuestionOption(
      optionId: 'A',
      label: 'A',
      content: RichContent(
        nodes: <ContentNode>[TextNode('First option '), InlineMathNode('a+b')],
      ),
      sourceRef: SourceRef.at(
        sourceId: _sourceId,
        point: SourcePoint.block(
          pageNumber: 1,
          blockId: 'opt_a',
          readingOrder: 1,
        ),
      ),
    ),
    QuestionOption(
      optionId: 'B',
      label: 'B',
      content: RichContent(nodes: <ContentNode>[TextNode('Second option')]),
      sourceRef: SourceRef.at(
        sourceId: _sourceId,
        point: SourcePoint.block(
          pageNumber: 1,
          blockId: 'opt_b',
          readingOrder: 2,
        ),
      ),
    ),
    QuestionOption(
      optionId: 'C',
      label: 'C',
      content: RichContent(nodes: <ContentNode>[TextNode('Third option')]),
      sourceRef: SourceRef.at(
        sourceId: _sourceId,
        point: SourcePoint.block(
          pageNumber: 1,
          blockId: 'opt_c',
          readingOrder: 3,
        ),
      ),
    ),
    QuestionOption(
      optionId: 'D',
      label: 'D',
      content: RichContent(nodes: <ContentNode>[TextNode('Fourth option')]),
      sourceRef: SourceRef.at(
        sourceId: _sourceId,
        point: SourcePoint.block(
          pageNumber: 1,
          blockId: 'opt_d',
          readingOrder: 4,
        ),
      ),
    ),
  ];
}

List<String> _baselineOptions() {
  return const <String>[
    'A. First option a+b',
    'B. Second option',
    'C. Third option',
    'D. Fourth option',
  ];
}

List<ImportIssue> _issues() {
  return <ImportIssue>[
    ImportIssue(
      code: 'low_confidence',
      severity: ImportIssueSeverity.warning,
      field: ImportIssueField.answer,
    ),
  ];
}

QuestionDraftV2 _choiceDraft() {
  return QuestionDraftV2(
    questionId: _questionId,
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: RichContent(
      nodes: <ContentNode>[
        TextNode('Stem text '),
        InlineMathNode('x+1'),
      ],
    ),
    options: _options(),
    answer: ChoiceAnswer(optionIds: const <String>['A']),
    explanation: null,
    sourceRefs: _sourceRefs(),
    assetRefs: <SourcedAssetRef>[
      SourcedAssetRef(
        sourceId: _sourceId,
        asset: AssetRef(
          assetId: 'asset_001',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      ),
    ],
    issues: _issues(),
  );
}

TypedReviewSnapshot _choiceSnapshot() {
  return TypedReviewSnapshot(
    reviewItemId: _reviewItemId,
    questionId: _questionId,
    draft: _choiceDraft(),
    baselineLegacy: LegacyReviewBaseline(
      type: 0,
      questionNumber: 1,
      content: 'Stem text x+1',
      options: _baselineOptions(),
      standardAnswer: 'A',
      explanation: '',
    ),
  );
}

Map<String, Object?> _choiceEnvelope() => _codec.encode(_choiceSnapshot());

QuestionDraft _choiceCurrent({
  String content = 'Stem text x+1',
  List<String>? options,
  String standardAnswer = 'A',
  String explanation = '',
  QuestionType type = QuestionType.singleChoice,
}) {
  return QuestionDraft(
    type: type,
    content: content,
    options: options ?? _baselineOptions(),
    standardAnswer: standardAnswer,
    explanation: explanation,
  );
}

QuestionDraftV2 _subjectiveDraft() {
  return QuestionDraftV2(
    questionId: _questionId,
    kind: QuestionKind.shortAnswer,
    questionNumber: 2,
    stem: RichContent(nodes: <ContentNode>[TextNode('Subjective stem')]),
    answer: ContentAnswer(
      content:
          RichContent(nodes: <ContentNode>[TextNode('synthetic-result-1')]),
    ),
    explanation: RichContent(
      nodes: <ContentNode>[TextNode('Explanation '), BlockMathNode('z=1')],
    ),
    sourceRefs: _sourceRefs(),
    issues: _issues(),
  );
}

TypedReviewSnapshot _subjectiveSnapshot() {
  return TypedReviewSnapshot(
    reviewItemId: _reviewItemId,
    questionId: _questionId,
    draft: _subjectiveDraft(),
    baselineLegacy: LegacyReviewBaseline(
      type: 3,
      questionNumber: 2,
      content: 'Subjective stem',
      options: const <String>[],
      standardAnswer: 'synthetic-result-1',
      explanation: 'Explanation z=1',
    ),
  );
}

Map<String, Object?> _subjectiveEnvelope() =>
    _codec.encode(_subjectiveSnapshot());

QuestionDraft _subjectiveCurrent({
  String content = 'Subjective stem',
  String standardAnswer = 'synthetic-result-1',
  String explanation = 'Explanation z=1',
  QuestionType type = QuestionType.shortAnswer,
}) {
  return QuestionDraft(
    type: type,
    content: content,
    options: const <String>[],
    standardAnswer: standardAnswer,
    explanation: explanation,
  );
}

TypedReviewCommitInput _input({
  Object? envelope = _missingEnvelopeSentinel,
  String? reviewItemId,
  QuestionDraft? currentDraft,
}) {
  return TypedReviewCommitInput(
    reviewItemId: reviewItemId ?? _reviewItemId,
    envelope: identical(envelope, _missingEnvelopeSentinel)
        ? _choiceEnvelope()
        : envelope,
    currentDraft: currentDraft ?? _choiceCurrent(),
  );
}

QuestionDraftV2 _expectedChoice({
  required RichContent stem,
  required QuestionAnswer answer,
  List<QuestionOption>? options,
}) {
  return QuestionDraftV2(
    questionId: _questionId,
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: stem,
    options: options ?? _options(),
    answer: answer,
    explanation: null,
    sourceRefs: _sourceRefs(),
    assetRefs: _choiceDraft().assetRefs,
    issues: _issues(),
  );
}

QuestionDraftV2 _expectedSubjective({
  required RichContent stem,
  Object? answer = _missingEnvelopeSentinel,
  RichContent? explanation,
}) {
  return QuestionDraftV2(
    questionId: _questionId,
    kind: QuestionKind.shortAnswer,
    questionNumber: 2,
    stem: stem,
    answer: identical(answer, _missingEnvelopeSentinel)
        ? ContentAnswer(
            content: RichContent(
              nodes: <ContentNode>[TextNode('synthetic-result-1')],
            ),
          )
        : answer as QuestionAnswer?,
    explanation: explanation,
    sourceRefs: _sourceRefs(),
    issues: _issues(),
  );
}

TypedReviewBuildResult _build(
  List<TypedReviewCommitInput> inputs, {
  String taskId = _taskId,
  String attemptToken = _attemptToken,
  int attemptNumber = 1,
  String Function()? sessionIdFactory,
  TypedReviewResultBuilder? builder,
}) {
  final active =
      builder ?? TypedReviewResultBuilder(sessionIdFactory: sessionIdFactory);
  return active.build(
    inputs: inputs,
    taskId: taskId,
    attemptToken: attemptToken,
    attemptNumber: attemptNumber,
  );
}

Matcher _commitFailure(TypedReviewCommitFailure failure) {
  return throwsA(
    isA<TypedReviewCommitException>().having(
      (error) => error.failure,
      'failure',
      failure,
    ),
  );
}

void main() {
  group('builder: unchanged commit set', () {
    test('complete snapshot decode yields one accepted item', () {
      final result = _build(<TypedReviewCommitInput>[_input()]);
      expect(result.reviewResult.items, hasLength(1));
      expect(
        result.reviewResult.items.single.decision,
        ReviewDecision.accepted,
      );
      expect(result.acceptedDrafts, hasLength(1));
    });

    test('unchanged stem preserves the original RichContent nodes', () {
      final result = _build(<TypedReviewCommitInput>[_input()]);
      expect(result.acceptedDrafts.single, _choiceDraft());
      expect(
        result.acceptedDrafts.single.stem.nodes[1],
        isA<InlineMathNode>(),
      );
    });

    test('unchanged options preserve option ids', () {
      final result = _build(<TypedReviewCommitInput>[_input()]);
      expect(
        result.acceptedDrafts.single.options
            .map((option) => option.optionId)
            .toList(),
        <String>['A', 'B', 'C', 'D'],
      );
    });

    test('unchanged options preserve source refs', () {
      final result = _build(<TypedReviewCommitInput>[_input()]);
      expect(result.acceptedDrafts.single.options, _choiceDraft().options);
    });

    test('unchanged answer preserves ChoiceAnswer', () {
      final result = _build(<TypedReviewCommitInput>[_input()]);
      expect(
        result.acceptedDrafts.single.answer,
        ChoiceAnswer(optionIds: const <String>['A']),
      );
    });

    test('unchanged explanation preserves typed nodes', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(
          envelope: _subjectiveEnvelope(),
          currentDraft: _subjectiveCurrent(),
        ),
      ]);
      expect(result.acceptedDrafts.single, _subjectiveDraft());
      expect(
        result.acceptedDrafts.single.explanation!.nodes[1],
        isA<BlockMathNode>(),
      );
    });

    test('source refs are preserved', () {
      final result = _build(<TypedReviewCommitInput>[_input()]);
      expect(result.acceptedDrafts.single.sourceRefs, _sourceRefs());
    });

    test('asset refs are preserved', () {
      final result = _build(<TypedReviewCommitInput>[_input()]);
      expect(
        result.acceptedDrafts.single.assetRefs.single.asset.assetId,
        'asset_001',
      );
      expect(
        result.acceptedDrafts.single.assetRefs.single.sourceId,
        _sourceId,
      );
    });

    test('issues are preserved', () {
      final result = _build(<TypedReviewCommitInput>[_input()]);
      expect(result.acceptedDrafts.single.issues, _issues());
    });
  });

  group('builder: ordinary edits', () {
    test('stem edit replaces only the stem', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(
          currentDraft: _choiceCurrent(content: 'Edited stem text'),
        ),
      ]);
      expect(
        result.acceptedDrafts.single,
        _expectedChoice(
          stem: RichContent(nodes: <ContentNode>[TextNode('Edited stem text')]),
          answer: ChoiceAnswer(optionIds: const <String>['A']),
        ),
      );
    });

    test('explanation edit replaces only the explanation', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(
          envelope: _subjectiveEnvelope(),
          currentDraft: _subjectiveCurrent(explanation: 'Edited explanation'),
        ),
      ]);
      expect(
        result.acceptedDrafts.single,
        _expectedSubjective(
          stem: _subjectiveDraft().stem,
          explanation: RichContent(
            nodes: <ContentNode>[TextNode('Edited explanation')],
          ),
        ),
      );
    });

    test('empty explanation maps to clear', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(
          envelope: _subjectiveEnvelope(),
          currentDraft: _subjectiveCurrent(explanation: ''),
        ),
      ]);
      expect(result.acceptedDrafts.single.explanation, isNull);
    });

    test('answer edit maps to ContentAnswer', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(
          envelope: _subjectiveEnvelope(),
          currentDraft: _subjectiveCurrent(standardAnswer: 'Edited answer'),
        ),
      ]);
      expect(
        result.acceptedDrafts.single,
        _expectedSubjective(
          stem: _subjectiveDraft().stem,
          answer: ContentAnswer(
            content: RichContent(
              nodes: <ContentNode>[TextNode('Edited answer')],
            ),
          ),
          explanation: _subjectiveDraft().explanation,
        ),
      );
    });

    test('empty answer maps to clear', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(
          envelope: _subjectiveEnvelope(),
          currentDraft: _subjectiveCurrent(standardAnswer: ''),
        ),
      ]);
      expect(
        result.acceptedDrafts.single,
        _expectedSubjective(
          stem: _subjectiveDraft().stem,
          answer: null,
          explanation: _subjectiveDraft().explanation,
        ),
      );
    });

    test('type edit maps to QuestionKind replace', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(
          currentDraft: _choiceCurrent(
            type: QuestionType.fillBlank,
            standardAnswer: '42',
          ),
        ),
      ]);
      expect(
        result.acceptedDrafts.single,
        QuestionDraftV2(
          questionId: _questionId,
          kind: QuestionKind.fillBlank,
          questionNumber: 1,
          stem: _choiceDraft().stem,
          options: _options(),
          answer: ContentAnswer(
            content: RichContent(nodes: <ContentNode>[TextNode('42')]),
          ),
          explanation: null,
          sourceRefs: _sourceRefs(),
          assetRefs: _choiceDraft().assetRefs,
          issues: _issues(),
        ),
      );
    });

    test('edited fields use exact TextNode text without LaTeX reparsing', () {
      const literal = r'Literal \(x+1\) \[y=2\] ![image](not-an-asset)';
      final result = _build(<TypedReviewCommitInput>[
        _input(currentDraft: _choiceCurrent(content: literal)),
      ]);
      expect(
        result.acceptedDrafts.single,
        _expectedChoice(
          stem: RichContent(nodes: <ContentNode>[TextNode(literal)]),
          answer: ChoiceAnswer(optionIds: const <String>['A']),
        ),
      );
    });

    test('unchanged fields stay untouched after an answer edit', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(currentDraft: _choiceCurrent(standardAnswer: 'B')),
      ]);
      expect(
        result.acceptedDrafts.single,
        _expectedChoice(
          stem: _choiceDraft().stem,
          answer: ChoiceAnswer(optionIds: const <String>['B']),
        ),
      );
    });
  });

  group('builder: option content edits', () {
    test('same count, order and labels with edited content passes', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(
          currentDraft: _choiceCurrent(
            options: const <String>[
              'A. Edited first option',
              'B. Second option',
              'C. Third option',
              'D. Fourth option',
            ],
          ),
        ),
      ]);
      final editedOption = _options().first;
      final replacedFirst = QuestionOption(
        optionId: editedOption.optionId,
        label: editedOption.label,
        content: RichContent(
          nodes: <ContentNode>[TextNode('Edited first option')],
        ),
        sourceRef: editedOption.sourceRef,
      );
      final expectedOptions = <QuestionOption>[
        replacedFirst,
        ..._options().skip(1),
      ];
      expect(
        result.acceptedDrafts.single,
        _expectedChoice(
          stem: _choiceDraft().stem,
          answer: ChoiceAnswer(optionIds: const <String>['A']),
          options: expectedOptions,
        ),
      );
    });

    test('edited option reuses the original option id', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(
          currentDraft: _choiceCurrent(
            options: const <String>[
              'A. Edited first option',
              'B. Second option',
              'C. Third option',
              'D. Fourth option',
            ],
          ),
        ),
      ]);
      expect(result.acceptedDrafts.single.options.first.optionId, 'A');
    });

    test('edited option reuses the original source ref', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(
          currentDraft: _choiceCurrent(
            options: const <String>[
              'A. Edited first option',
              'B. Second option',
              'C. Third option',
              'D. Fourth option',
            ],
          ),
        ),
      ]);
      expect(
        result.acceptedDrafts.single.options.first.sourceRef,
        _choiceDraft().options.first.sourceRef,
      );
    });

    test('added option count blocks the commit', () {
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(
            currentDraft: _choiceCurrent(
              options: const <String>[
                'A. First option a+b',
                'B. Second option',
                'C. Third option',
                'D. Fourth option',
                'E. Fifth option',
              ],
            ),
          ),
        ]),
        _commitFailure(TypedReviewCommitFailure.unsupportedOptionEdit),
      );
    });

    test('removed option count blocks the commit', () {
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(
            currentDraft: _choiceCurrent(
              options: const <String>[
                'A. First option a+b',
                'B. Second option',
                'C. Third option',
              ],
            ),
          ),
        ]),
        _commitFailure(TypedReviewCommitFailure.unsupportedOptionEdit),
      );
    });

    test('option reorder blocks the commit', () {
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(
            currentDraft: _choiceCurrent(
              options: const <String>[
                'A. First option a+b',
                'C. Third option',
                'B. Second option',
                'D. Fourth option',
              ],
            ),
          ),
        ]),
        _commitFailure(TypedReviewCommitFailure.unsupportedOptionEdit),
      );
    });

    test('label change blocks the commit', () {
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(
            currentDraft: _choiceCurrent(
              options: const <String>[
                'X. First option a+b',
                'B. Second option',
                'C. Third option',
                'D. Fourth option',
              ],
            ),
          ),
        ]),
        _commitFailure(TypedReviewCommitFailure.unsupportedOptionEdit),
      );
    });

    test('duplicate labels block the commit', () {
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(
            currentDraft: _choiceCurrent(
              options: const <String>[
                'A. First option a+b',
                'A. Duplicate label',
                'C. Third option',
                'D. Fourth option',
              ],
            ),
          ),
        ]),
        _commitFailure(TypedReviewCommitFailure.unsupportedOptionEdit),
      );
    });

    test('unparseable label blocks the commit', () {
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(
            currentDraft: _choiceCurrent(
              options: const <String>[
                'Option text without a label',
                'B. Second option',
                'C. Third option',
                'D. Fourth option',
              ],
            ),
          ),
        ]),
        _commitFailure(TypedReviewCommitFailure.unsupportedOptionEdit),
      );
    });
  });

  group('builder: identity and corruption', () {
    test('missing envelope blocks the commit', () {
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(envelope: null),
        ]),
        _commitFailure(TypedReviewCommitFailure.missingSnapshot),
      );
    });

    test('corrupt envelope blocks the commit', () {
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(
            envelope: <String, Object?>{
              'schemaVersion': 1,
              'route': 'typedV2',
              'reviewItemId': _reviewItemId,
              'questionId': _questionId,
              'draft': <String, Object?>{'broken': true},
              'baselineLegacy': <String, Object?>{'broken': true},
              'unexpected': 'extra',
            },
          ),
        ]),
        _commitFailure(TypedReviewCommitFailure.corruptSnapshot),
      );
    });

    test('reviewItemId mismatch blocks the commit', () {
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(reviewItemId: _reviewItemIdB),
        ]),
        _commitFailure(TypedReviewCommitFailure.identityMismatch),
      );
    });

    test('duplicate reviewItemIds block the commit', () {
      final secondEnvelope = _codec.encode(
        TypedReviewSnapshot(
          reviewItemId: _reviewItemId,
          questionId: _questionIdB,
          draft: QuestionDraftV2(
            questionId: _questionIdB,
            kind: QuestionKind.shortAnswer,
            questionNumber: 2,
            stem: RichContent(
              nodes: <ContentNode>[TextNode('Second synthetic stem')],
            ),
          ),
          baselineLegacy: LegacyReviewBaseline(
            type: 3,
            questionNumber: 2,
            content: 'Second synthetic stem',
            options: const <String>[],
            standardAnswer: '',
            explanation: '',
          ),
        ),
      );
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(),
          _input(
            reviewItemId: _reviewItemId,
            envelope: secondEnvelope,
            currentDraft: QuestionDraft(
              type: QuestionType.shortAnswer,
              content: 'Second synthetic stem',
              options: const <String>[],
              standardAnswer: '',
              explanation: '',
            ),
          ),
        ]),
        _commitFailure(TypedReviewCommitFailure.identityMismatch),
      );
    });

    test('duplicate questionIds block the commit', () {
      final secondEnvelope = _codec.encode(
        TypedReviewSnapshot(
          reviewItemId: _reviewItemIdB,
          questionId: _questionId,
          draft: QuestionDraftV2(
            questionId: _questionId,
            kind: QuestionKind.shortAnswer,
            questionNumber: 2,
            stem: RichContent(
              nodes: <ContentNode>[TextNode('Second synthetic stem')],
            ),
          ),
          baselineLegacy: LegacyReviewBaseline(
            type: 3,
            questionNumber: 2,
            content: 'Second synthetic stem',
            options: const <String>[],
            standardAnswer: '',
            explanation: '',
          ),
        ),
      );
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(),
          _input(
            reviewItemId: _reviewItemIdB,
            envelope: secondEnvelope,
            currentDraft: QuestionDraft(
              type: QuestionType.shortAnswer,
              content: 'Second synthetic stem',
              options: const <String>[],
              standardAnswer: '',
              explanation: '',
            ),
          ),
        ]),
        _commitFailure(TypedReviewCommitFailure.identityMismatch),
      );
    });

    test('invalid task origin blocks the commit', () {
      expect(
        () => _build(<TypedReviewCommitInput>[_input()], attemptToken: ''),
        _commitFailure(TypedReviewCommitFailure.invalidOrigin),
      );
      expect(
        () => _build(<TypedReviewCommitInput>[_input()], attemptNumber: 0),
        _commitFailure(TypedReviewCommitFailure.invalidOrigin),
      );
      expect(
        () => _build(<TypedReviewCommitInput>[_input()], taskId: '  '),
        _commitFailure(TypedReviewCommitFailure.invalidOrigin),
      );
    });

    test('unsafe payload blocks the commit', () {
      final unsafe = <String, Object?>{
        'schemaVersion': 1,
        'route': 'typedV2',
        'reviewItemId': _reviewItemId,
        'questionId': _questionId,
        'draft': <String, Object?>{
          'schemaVersion': 2,
          'questionId': _questionId,
          'questionNumber': 1,
          'kind': 'short_answer',
          'stem': <String, Object?>{
            'schemaVersion': 1,
            'nodes': <Object?>[
              <String, Object?>{
                'type': 'raw_fallback',
                'payload': <String, Object?>{
                  'type': 'future_diagram',
                  'path': r'C:\leak',
                },
              },
            ],
          },
          'options': <Object?>[],
          'answer': null,
          'explanation': null,
          'sourceRefs': <Object?>[],
          'assetRefs': <Object?>[],
          'issues': <Object?>[],
        },
        'baselineLegacy': <String, Object?>{
          'type': 3,
          'questionNumber': 1,
          'content': 'Unsafe stem',
          'options': <Object?>[],
          'standardAnswer': '',
          'explanation': '',
        },
      };
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(envelope: unsafe),
        ]),
        _commitFailure(TypedReviewCommitFailure.unsafePayload),
      );
    });

    test('fixed exception never contains the secret marker', () {
      try {
        _build(<TypedReviewCommitInput>[
          _input(
            envelope: <String, Object?>{
              'schemaVersion': 1,
              'route': 'typedV2',
              'reviewItemId': _reviewItemId,
              'questionId': _questionId,
              'draft': <String, Object?>{'secret': _secretMarker},
              'baselineLegacy': <String, Object?>{'secret': _secretMarker},
              'unexpected': _secretMarker,
            },
          ),
        ]);
        fail('expected a corruption failure');
      } on TypedReviewCommitException catch (error) {
        expect(error.toString(), isNot(contains(_secretMarker)));
      }
    });

    test('fixed exception never contains the original payload', () {
      try {
        _build(<TypedReviewCommitInput>[
          _input(
            envelope: <String, Object?>{
              'schemaVersion': 1,
              'route': 'typedV2',
              'reviewItemId': _reviewItemId,
              'questionId': _questionId,
              'draft': <String, Object?>{
                'schemaVersion': 2,
                'questionId': _questionId,
                'questionNumber': 1,
                'kind': 'short_answer',
                'stem': <String, Object?>{
                  'schemaVersion': 1,
                  'nodes': <Object?>[
                    <String, Object?>{
                      'type': 'text',
                      'text': 'Stem text secret-value',
                    },
                  ],
                },
                'options': <Object?>[],
                'answer': null,
                'explanation': null,
                'sourceRefs': <Object?>[],
                'assetRefs': <Object?>[],
                'issues': <Object?>[],
              },
              'baselineLegacy': <String, Object?>{
                'type': 3,
                'questionNumber': 1,
                'content': 'Stem text',
                'options': <Object?>[],
                'standardAnswer': '',
                'explanation': '',
              },
            },
          ),
        ]);
        fail('expected a corruption failure');
      } on TypedReviewCommitException catch (error) {
        expect(error.toString(), isNot(contains(_questionId)));
        expect(error.toString(), isNot(contains(_sourceId)));
        expect(error.toString(), isNot(contains('Stem text')));
      }
    });

    test('non-canonical source ids are rejected without leaking the id', () {
      final draft = QuestionDraftV2(
        questionId: _questionId,
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: RichContent(
          nodes: <ContentNode>[TextNode('Synthetic stem')],
        ),
        sourceRefs: <SourceRef>[
          SourceRef.document(
            sourceId: 'legacy_non_canonical_source',
            displayLabel: null,
          ),
        ],
      );
      final envelope = _codec.encode(
        TypedReviewSnapshot(
          reviewItemId: _reviewItemId,
          questionId: _questionId,
          draft: draft,
          baselineLegacy: LegacyReviewBaseline(
            type: 3,
            questionNumber: 1,
            content: 'Synthetic stem',
            options: const <String>[],
            standardAnswer: '',
            explanation: '',
          ),
        ),
      );
      try {
        _build(<TypedReviewCommitInput>[
          _input(
            envelope: envelope,
            currentDraft: QuestionDraft(
              type: QuestionType.shortAnswer,
              content: 'Synthetic stem',
              options: const <String>[],
              standardAnswer: '',
              explanation: '',
            ),
          ),
        ]);
        fail('expected an identity failure');
      } on TypedReviewCommitException catch (error) {
        expect(error.failure, TypedReviewCommitFailure.identityMismatch);
        expect(
            error.toString(), isNot(contains('legacy_non_canonical_source')));
      }
    });

    test('baseline question number mismatch blocks the commit', () {
      final envelope = _codec.encode(
        TypedReviewSnapshot(
          reviewItemId: _reviewItemId,
          questionId: _questionId,
          draft: _choiceDraft(),
          baselineLegacy: LegacyReviewBaseline(
            type: 0,
            questionNumber: 9,
            content: 'Stem text x+1',
            options: _baselineOptions(),
            standardAnswer: 'A',
            explanation: '',
          ),
        ),
      );
      expect(
        () => _build(<TypedReviewCommitInput>[
          _input(envelope: envelope),
        ]),
        _commitFailure(TypedReviewCommitFailure.baselineMismatch),
      );
    });
  });

  group('builder: ReviewSession usage', () {
    test('the session id factory drives the real openSession call', () {
      var factoryCalls = 0;
      final builder = TypedReviewResultBuilder(
        sessionIdFactory: () {
          factoryCalls++;
          return _sessionId;
        },
      );
      final result =
          _build(<TypedReviewCommitInput>[_input()], builder: builder);

      expect(factoryCalls, 1,
          reason: 'the adapter openSession must receive the factory id');
      expect(result.reviewResult.sessionId, _sessionId,
          reason: 'the completed result must carry the opened session id');
      expect(
        result.reviewResult.sessionId,
        isNot(contains(r'C:\')),
        reason: 'session ids stay opaque and never encode paths',
      );
    });

    test('edit, decide and complete drive revision and final draft', () {
      final result = _build(<TypedReviewCommitInput>[
        _input(
          currentDraft: _choiceCurrent(content: 'Edited stem text'),
        ),
      ]);
      expect(result.reviewResult.completedRevision, 3,
          reason: 'one edit + one decide + one completion transition');
      expect(
        result.reviewResult.items.single.finalDraft,
        _expectedChoice(
          stem: RichContent(
            nodes: <ContentNode>[TextNode('Edited stem text')],
          ),
          answer: ChoiceAnswer(optionIds: const <String>['A']),
        ),
        reason: 'the completed final draft must carry the applied edit',
      );
      expect(
        result.reviewResult.items.single.decision,
        ReviewDecision.accepted,
      );
    });

    test('an unchanged item skips edit and still completes accepted', () {
      final result = _build(<TypedReviewCommitInput>[_input()]);
      expect(result.reviewResult.completedRevision, 2,
          reason: 'one decide + one completion transition only');
      expect(
        result.reviewResult.items.single.decision,
        ReviewDecision.accepted,
      );
    });

    test('the result comes from the completed session, not a manual result',
        () {
      final result = _build(
        <TypedReviewCommitInput>[_input()],
        sessionIdFactory: () => _sessionId,
      );
      expect(result.reviewResult.sessionId, _sessionId);
      expect(result.reviewResult.completedRevision, 2);
      expect(result.acceptedDrafts.single,
          result.reviewResult.items.single.finalDraft);
    });

    test('deleted staging questions never enter the commit set', () {
      final second = _codec.encode(
        TypedReviewSnapshot(
          reviewItemId: _reviewItemIdB,
          questionId: _questionIdB,
          draft: QuestionDraftV2(
            questionId: _questionIdB,
            kind: QuestionKind.shortAnswer,
            questionNumber: 2,
            stem: RichContent(
              nodes: <ContentNode>[TextNode('Second synthetic stem')],
            ),
          ),
          baselineLegacy: LegacyReviewBaseline(
            type: 3,
            questionNumber: 2,
            content: 'Second synthetic stem',
            options: const <String>[],
            standardAnswer: '',
            explanation: '',
          ),
        ),
      );
      final result = _build(<TypedReviewCommitInput>[
        _input(),
        _input(
          reviewItemId: _reviewItemIdB,
          envelope: second,
          currentDraft: QuestionDraft(
            type: QuestionType.shortAnswer,
            content: 'Second synthetic stem',
            options: const <String>[],
            standardAnswer: '',
            explanation: '',
          ),
        ),
      ]);
      // Simulate deletion: commit only the remaining first item.
      final remaining = _build(<TypedReviewCommitInput>[_input()]);
      expect(remaining.reviewResult.items, hasLength(1));
      expect(remaining.reviewResult.items.single.itemId, _reviewItemId);
      expect(result.reviewResult.items, hasLength(2));
    });

    test('remaining item order stays stable', () {
      final second = _codec.encode(
        TypedReviewSnapshot(
          reviewItemId: _reviewItemIdB,
          questionId: _questionIdB,
          draft: QuestionDraftV2(
            questionId: _questionIdB,
            kind: QuestionKind.shortAnswer,
            questionNumber: 2,
            stem: RichContent(
              nodes: <ContentNode>[TextNode('Second synthetic stem')],
            ),
          ),
          baselineLegacy: LegacyReviewBaseline(
            type: 3,
            questionNumber: 2,
            content: 'Second synthetic stem',
            options: const <String>[],
            standardAnswer: '',
            explanation: '',
          ),
        ),
      );
      final result = _build(<TypedReviewCommitInput>[
        _input(),
        _input(
          reviewItemId: _reviewItemIdB,
          envelope: second,
          currentDraft: QuestionDraft(
            type: QuestionType.shortAnswer,
            content: 'Second synthetic stem',
            options: const <String>[],
            standardAnswer: '',
            explanation: '',
          ),
        ),
      ]);
      expect(
        result.reviewResult.items.map((item) => item.itemId).toList(),
        <String>[_reviewItemId, _reviewItemIdB],
      );
      expect(
        result.acceptedDrafts.map((draft) => draft.questionId).toList(),
        <String>[_questionId, _questionIdB],
      );
    });
  });
}
