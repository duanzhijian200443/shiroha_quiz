// R7D presentation adapter acceptance (pure Dart, no widgets, no database).
// All fixtures are synthetic; no Provider, OCR, Replay, or private content.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/ui/models/persisted_question_view.dart';

const _storageId = '11111111-2222-4333-8444-555555555555';
const _bankName = 'synthetic_bank';

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

QuestionDraftV2 _typedDraft({
  String questionId = 'typed_q_001',
  QuestionKind kind = QuestionKind.singleChoice,
  RichContent? stem,
  List<QuestionOption> options = const <QuestionOption>[],
  QuestionAnswer? answer,
  RichContent? explanation,
  Iterable<SourceRef> sourceRefs = const <SourceRef>[],
  Iterable<SourcedAssetRef> assetRefs = const <SourcedAssetRef>[],
  Iterable<ImportIssue> issues = const <ImportIssue>[],
}) {
  return QuestionDraftV2(
    questionId: questionId,
    kind: kind,
    stem: stem ?? _text('Typed stem.'),
    options: options,
    answer: answer,
    explanation: explanation,
    sourceRefs: sourceRefs,
    assetRefs: assetRefs,
    issues: issues,
  );
}

TypedPersistedQuestion _typedPersisted(QuestionDraftV2 draft) {
  return TypedPersistedQuestion(
    storageId: _storageId,
    bankName: _bankName,
    createdAt: 1700000001,
    draft: draft,
  );
}

List<QuestionOption> _twoOptions() {
  return <QuestionOption>[
    QuestionOption(
      optionId: 'opt_a',
      label: '甲',
      content: _text('first option'),
    ),
    QuestionOption(
      optionId: 'opt_b',
      label: '乙',
      content: _text('second option'),
    ),
  ];
}

Question _legacyQuestion({
  int type = 0,
  String content = 'Legacy content marker',
  String options = '["A. legacy one","B. legacy two"]',
  String answer = 'A',
  String? explanation = 'Legacy explanation marker',
  String? rawExplanation = 'Legacy raw marker',
}) {
  return Question(
    id: 'legacy_storage_id',
    type: type,
    content: content,
    options: options,
    answer: answer,
    createdAt: 1700000000,
    bankName: _bankName,
    explanation: explanation,
    rawExplanation: rawExplanation,
  );
}

PersistedQuestionView _typedView(QuestionDraftV2 draft) {
  return PersistedQuestionViewAdapter.fromPersisted(_typedPersisted(draft));
}

PersistedQuestionView _legacyView(Question question) {
  return PersistedQuestionViewAdapter.fromPersisted(
    LegacyPersistedQuestion(question: question),
  );
}

void main() {
  group('identity mapping', () {
    test('1: typed row maps storageId, bank, and createdAt', () {
      final view = _typedView(_typedDraft());
      expect(view.storageId, _storageId);
      expect(view.bankName, _bankName);
      expect(view.createdAt, 1700000001);
      expect(view.isTyped, isTrue);
    });

    test('2: legacy row maps storageId, bank, and createdAt', () {
      final view = _legacyView(_legacyQuestion());
      expect(view.storageId, 'legacy_storage_id');
      expect(view.bankName, _bankName);
      expect(view.createdAt, 1700000000);
      expect(view.isTyped, isFalse);
    });

    test('typed rows expose the sidecar draft for the typed editor', () {
      final draft = _typedDraft();
      final view = _typedView(draft);
      expect(view.typedDraft, same(draft));
    });

    test('legacy rows never expose a typed draft', () {
      final view = _legacyView(_legacyQuestion());
      expect(view.typedDraft, isNull);
    });
  });

  group('kind mapping', () {
    test('3: typed kinds map to singleChoice, fillBlank, shortAnswer', () {
      expect(
        _typedView(_typedDraft(kind: QuestionKind.singleChoice)).kind,
        PersistedQuestionViewKind.singleChoice,
      );
      expect(
        _typedView(_typedDraft(kind: QuestionKind.fillBlank)).kind,
        PersistedQuestionViewKind.fillBlank,
      );
      expect(
        _typedView(_typedDraft(kind: QuestionKind.shortAnswer)).kind,
        PersistedQuestionViewKind.shortAnswer,
      );
    });

    test('4: legacy type 0/1/2/3 map correctly', () {
      expect(
        _legacyView(_legacyQuestion(type: 0)).kind,
        PersistedQuestionViewKind.singleChoice,
      );
      expect(
        _legacyView(_legacyQuestion(type: 1)).kind,
        PersistedQuestionViewKind.multipleChoice,
      );
      expect(
        _legacyView(_legacyQuestion(type: 2)).kind,
        PersistedQuestionViewKind.fillBlank,
      );
      expect(
        _legacyView(_legacyQuestion(type: 3)).kind,
        PersistedQuestionViewKind.shortAnswer,
      );
    });

    test('5: unknown legacy type maps to unknown', () {
      expect(
        _legacyView(_legacyQuestion(type: 9)).kind,
        PersistedQuestionViewKind.unknown,
      );
    });
  });

  group('typed stem', () {
    test('6: typed stem preserves the original RichContent', () {
      final stem = RichContent(nodes: const <ContentNode>[
        TextNode('Stem text '),
        InlineMathNode(r'x^2'),
      ]);
      final view = _typedView(_typedDraft(stem: stem));
      expect(view.typedStem, same(stem));
      expect(view.legacyStem, isEmpty);
    });

    test('7: typed explicit empty stem is preserved without legacy fallback',
        () {
      final view = _typedView(
        _typedDraft(stem: RichContent(nodes: const <ContentNode>[])),
      );
      expect(view.typedStem, isNotNull);
      expect(view.typedStem!.nodes, isEmpty);
      expect(view.legacyStem, isEmpty);
      expect(view.searchText, isNot(contains('无题干')));
    });
  });

  group('typed options', () {
    test(
        '8/9/10/11: option order, label, and content are preserved and '
        'optionId stays out of the view', () {
      final view = _typedView(_typedDraft(options: _twoOptions()));
      expect(view.options, hasLength(2));
      expect(view.options[0].label, '甲');
      expect(view.options[1].label, '乙');
      expect(view.options[0].typedContent!.nodes.single, isA<TextNode>());
      expect(
        (view.options[0].typedContent!.nodes.single as TextNode).text,
        'first option',
      );
      expect(view.options[0].legacyText, isEmpty);
      expect(
        () => (view.options.first as dynamic).optionId,
        throwsA(isA<NoSuchMethodError>()),
      );
    });

    test(
        '12: fillBlank and shortAnswer typed drafts keep all non-empty '
        'options regardless of kind', () {
      final fillBlank = _typedView(
        _typedDraft(kind: QuestionKind.fillBlank, options: _twoOptions()),
      );
      final shortAnswer = _typedView(
        _typedDraft(kind: QuestionKind.shortAnswer, options: _twoOptions()),
      );
      expect(fillBlank.options, hasLength(2));
      expect(fillBlank.options[1].label, '乙');
      expect(shortAnswer.options, hasLength(2));
    });
  });

  group('typed answer', () {
    test('13: ChoiceAnswer maps to the option labels', () {
      final view = _typedView(
        _typedDraft(
          options: _twoOptions(),
          answer: ChoiceAnswer(optionIds: <String>['opt_a', 'opt_b']),
        ),
      );
      final node = view.typedAnswer!.nodes.single as TextNode;
      expect(node.text, '甲, 乙');
    });

    test('14: unknown ChoiceAnswer optionId is preserved, never dropped', () {
      final view = _typedView(
        _typedDraft(
          options: _twoOptions(),
          answer: ChoiceAnswer(optionIds: <String>['opt_a', 'ghost_opt']),
        ),
      );
      final node = view.typedAnswer!.nodes.single as TextNode;
      expect(node.text, '甲, ghost_opt');
    });

    test('15: ContentAnswer keeps the RichContent', () {
      final content = RichContent(nodes: const <ContentNode>[
        InlineMathNode(r'\frac{1}{3}'),
      ]);
      final view = _typedView(
        _typedDraft(answer: ContentAnswer(content: content)),
      );
      expect(view.typedAnswer, same(content));
    });

    test('16: null typed answer stays null', () {
      final view = _typedView(_typedDraft(answer: null));
      expect(view.typedAnswer, isNull);
      expect(view.legacyAnswer, isEmpty);
    });
  });

  group('typed explanation', () {
    test('17: typed explanation preserves the RichContent', () {
      final explanation = _text('Typed explanation.');
      final view = _typedView(_typedDraft(explanation: explanation));
      expect(view.typedExplanation, same(explanation));
      expect(view.legacyExplanation, isEmpty);
    });

    test('18: null typed explanation stays null', () {
      final view = _typedView(_typedDraft(explanation: null));
      expect(view.typedExplanation, isNull);
    });
  });

  group('typed search text privacy', () {
    test('19: sourceRefs never enter the view', () {
      final view = _typedView(
        _typedDraft(
          sourceRefs: <SourceRef>[
            SourceRef.document(sourceId: 'src_secret_001'),
          ],
        ),
      );
      expect(() => (view as dynamic).sourceRefs,
          throwsA(isA<NoSuchMethodError>()));
      expect(view.searchText, isNot(contains('src_secret_001')));
    });

    test('20: assetRefs never enter the search text', () {
      final view = _typedView(
        _typedDraft(
          sourceRefs: <SourceRef>[
            SourceRef.document(sourceId: 'src_001'),
          ],
          assetRefs: <SourcedAssetRef>[
            SourcedAssetRef(
              sourceId: 'src_001',
              asset: AssetRef(
                assetId: 'asset_secret_000001',
                kind: AssetKind.image,
              ),
            ),
          ],
        ),
      );
      expect(view.searchText, isNot(contains('asset_secret_000001')));
    });

    test('21: issues never enter the search text', () {
      final view = _typedView(
        _typedDraft(
          issues: <ImportIssue>[
            ImportIssue(
              code: 'missing_answer_secret',
              severity: ImportIssueSeverity.warning,
              field: ImportIssueField.answer,
            ),
          ],
        ),
      );
      expect(view.searchText, isNot(contains('missing_answer_secret')));
    });

    test('22: RawFallback rawJson never enters the search text', () {
      final view = _typedView(
        _typedDraft(
          stem: RichContent(nodes: <ContentNode>[
            TextNode('Visible stem'),
            RawFallbackNode(<String, Object?>{
              'type': 'future_table',
              'payload': <String, Object?>{'secret': 'DO_NOT_RENDER'},
            }),
          ]),
        ),
      );
      expect(view.searchText, contains('Visible stem'));
      expect(view.searchText, isNot(contains('DO_NOT_RENDER')));
      expect(view.searchText, isNot(contains('future_table')));
      expect(view.searchText, isNot(contains('secret')));
      expect(view.searchText, isNot(contains('raw_fallback')));
    });

    test('23: typed math latex can enter the search text', () {
      final view = _typedView(
        _typedDraft(
          stem: RichContent(nodes: const <ContentNode>[
            InlineMathNode(r'x^2'),
            BlockMathNode(r'\int_0^1 x\,dx'),
          ]),
          explanation: _text('Explanation with \\(y\\) marker.'),
        ),
      );
      expect(view.searchText, contains(r'x^2'));
      expect(view.searchText, contains(r'\int_0^1 x\,dx'));
      expect(view.searchText, contains('Explanation with'));
    });
  });

  group('legacy options', () {
    test('24: legacy options JSON list parses with A/B labels', () {
      final view = _legacyView(_legacyQuestion());
      expect(view.options, hasLength(2));
      expect(view.options[0].label, 'A');
      expect(view.options[0].typedContent, isNull);
      expect(view.options[0].legacyText, 'legacy one');
      expect(view.options[1].label, 'B');
      expect(view.options[1].legacyText, 'legacy two');
    });

    test('25: malformed or non-list legacy options return an empty list', () {
      expect(
        _legacyView(_legacyQuestion(options: '{corrupt')).options,
        isEmpty,
      );
      expect(
        _legacyView(_legacyQuestion(options: '{"a":1}')).options,
        isEmpty,
      );
      expect(
        _legacyView(_legacyQuestion(options: '[]')).options,
        isEmpty,
      );
    });

    test('26: legacy Map options are skipped, never stringified', () {
      final view = _legacyView(
        _legacyQuestion(options: '[{"secret":"MAP_SECRET"}, "B. plain"]'),
      );
      expect(view.options, hasLength(1));
      expect(view.options.single.legacyText, 'plain');
      expect(view.searchText, isNot(contains('MAP_SECRET')));
      expect(view.searchText, isNot(contains('secret')));
    });
  });

  group('legacy payload and search', () {
    test('27: legacy edit payload is a defensive copy', () {
      final view = _legacyView(_legacyQuestion());
      final payload = view.legacyEditPayload;
      expect(payload, isNotNull);
      expect(payload!['id'], 'legacy_storage_id');
      expect(payload['content'], 'Legacy content marker');
      expect(payload['standard_answer'], 'A');
      expect(payload['explanation'], 'Legacy explanation marker');
      expect(
        () => payload['content'] = 'mutated',
        throwsUnsupportedError,
      );
    });

    test('typed rows never carry a legacy edit payload', () {
      final view = _typedView(_typedDraft());
      expect(view.legacyEditPayload, isNull);
    });

    test(
        'legacy search text covers content, options, answer, and '
        'explanation only', () {
      final view = _legacyView(
        _legacyQuestion(rawExplanation: 'RAW_SECRET_789'),
      );
      expect(view.searchText, contains('Legacy content marker'));
      expect(view.searchText, contains('legacy one'));
      expect(view.searchText, contains('legacy two'));
      expect(view.searchText, contains('A'));
      expect(view.searchText, contains('Legacy explanation marker'));
      expect(view.searchText, isNot(contains('RAW_SECRET_789')));
      expect(view.searchText, isNot(contains('legacy_storage_id')));
      expect(view.searchText, isNot(contains(_bankName)));
    });
  });

  group('immutability', () {
    test('28: view option collections cannot be modified', () {
      final view = _typedView(_typedDraft(options: _twoOptions()));
      expect(
        () => view.options.add(
          const PersistedQuestionOptionView(
            label: 'C',
            typedContent: null,
            legacyText: '',
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => view.options.clear(),
        throwsUnsupportedError,
      );
    });

    test('legacy rows never carry typed fields', () {
      final view = _legacyView(_legacyQuestion());
      expect(view.typedStem, isNull);
      expect(view.typedAnswer, isNull);
      expect(view.typedExplanation, isNull);
      expect(view.typedDraft, isNull);
      expect(view.legacyStem, 'Legacy content marker');
      expect(view.legacyAnswer, 'A');
      expect(view.legacyExplanation, 'Legacy explanation marker');
    });
  });
}
