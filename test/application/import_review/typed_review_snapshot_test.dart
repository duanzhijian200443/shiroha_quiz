import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

const _uuidA = '0d8b7a3e-7f1c-4b2a-9d3e-5a6b7c8d9e0f';
const _uuidB = '1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d';
const _uuidC = '2b3c4d5e-6f7a-4b9c-a1b2-c3d4e5f6a7b8';
const _secretMarker = 'SYNTHETIC_R7A_SECRET_MARKER_9f3a';

Map<Object?, Object?> _safeRawJson() => <Object?, Object?>{
      'type': 'future_diagram',
      'payload': <Object?, Object?>{
        'kind': 'synthetic',
        'count': 1,
      },
    };

Map<Object?, Object?> _unsafePathRawJson() => <Object?, Object?>{
      'type': 'future_diagram',
      'payload': <Object?, Object?>{
        'marker': _secretMarker,
        'path': r'C:\synthetic\private\file.pdf',
      },
    };

Map<Object?, Object?> _unsafeUrlRawJson() => <Object?, Object?>{
      'type': 'future_diagram',
      'providerResponse': <Object?, Object?>{
        'marker': _secretMarker,
        'url': 'https://example.invalid/synthetic',
      },
    };

Map<Object?, Object?> _unsafeCredentialRawJson() => <Object?, Object?>{
      'type': 'future_diagram',
      'payload': <Object?, Object?>{
        'marker': _secretMarker,
        'base64': 'c3ludGhldGlj',
        'credential': 'synthetic-secret',
      },
    };

Map<Object?, Object?> _unsafeProviderBodyRawJson() => <Object?, Object?>{
      'type': 'future_diagram',
      'providerBody': <Object?, Object?>{
        'marker': _secretMarker,
        'status': 'synthetic',
      },
    };

QuestionDraftV2 _fullDraft({
  String questionId = _uuidB,
  RichContent? stem,
  QuestionAnswer? answer,
  RichContent? explanation,
}) {
  return QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.singleChoice,
    questionNumber: 7,
    stem: stem ??
        RichContent(nodes: <ContentNode>[
          const TextNode('Synthetic stem text'),
          const InlineMathNode(r'\frac{a}{b}'),
          const BlockMathNode(r'\int_0^1 x\,dx'),
          RawFallbackNode(_safeRawJson()),
        ]),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'option_a',
        label: 'A',
        content: RichContent(nodes: const <ContentNode>[
          TextNode('Synthetic option A'),
        ]),
      ),
      QuestionOption(
        optionId: 'option_b',
        label: 'B',
        content: RichContent(nodes: <ContentNode>[
          const TextNode('Synthetic option B'),
          RawFallbackNode(_safeRawJson()),
        ]),
      ),
    ],
    answer: answer ?? ChoiceAnswer(optionIds: <String>['option_b']),
    explanation: explanation ??
        RichContent(nodes: const <ContentNode>[
          TextNode('Synthetic explanation'),
        ]),
    sourceRefs: <SourceRef>[
      SourceRef.document(sourceId: 'source_001'),
      SourceRef.at(
        sourceId: 'source_001',
        point: SourcePoint.page(pageNumber: 3),
      ),
      SourceRef.range(
        sourceId: 'source_001',
        start: SourcePoint.block(
          pageNumber: 3,
          blockId: 'block_7',
          readingOrder: 2,
        ),
        end: SourcePoint.block(
          pageNumber: 3,
          blockId: 'block_8',
          readingOrder: 3,
        ),
      ),
    ],
    assetRefs: <SourcedAssetRef>[
      SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(assetId: 'asset_0001', kind: AssetKind.image),
      ),
    ],
    issues: <ImportIssue>[
      ImportIssue(
        code: 'synthetic_issue',
        severity: ImportIssueSeverity.warning,
      ),
    ],
  );
}

LegacyReviewBaseline _fullBaseline() {
  return LegacyReviewBaseline(
    type: 0,
    questionNumber: 3,
    content: 'Synthetic baseline content',
    options: <String>['A', 'B', 'C'],
    standardAnswer: 'B',
    explanation: 'Synthetic baseline explanation',
  );
}

TypedReviewSnapshot _fullSnapshot({QuestionDraftV2? draft}) {
  return TypedReviewSnapshot(
    reviewItemId: _uuidA,
    questionId: _uuidB,
    draft: draft ?? _fullDraft(),
    baselineLegacy: _fullBaseline(),
  );
}

TypedReviewSnapshotException _expectFailure(
  void Function() action,
  TypedReviewSnapshotFailure expected,
) {
  TypedReviewSnapshotException? caught;
  try {
    action();
  } on TypedReviewSnapshotException catch (error) {
    caught = error;
  }
  expect(caught, isNotNull, reason: 'expected $expected');
  expect(caught!.failure, expected);
  return caught;
}

void main() {
  const codec = TypedReviewSnapshotCodec();

  group('ImportStorageRoute codec', () {
    test('missing route decodes as legacyV1 for historical tasks', () {
      expect(decodeImportStorageRoute(null), ImportStorageRoute.legacyV1);
    });

    test('decodes stable serialization values and rejects unknown routes', () {
      expect(
        decodeImportStorageRoute('legacyV1'),
        ImportStorageRoute.legacyV1,
      );
      expect(decodeImportStorageRoute('typedV2'), ImportStorageRoute.typedV2);
      expect(
        importStorageRouteSerialization(ImportStorageRoute.legacyV1),
        'legacyV1',
      );
      expect(
        importStorageRouteSerialization(ImportStorageRoute.typedV2),
        'typedV2',
      );
      _expectFailure(
        () => decodeImportStorageRoute('legacyV9'),
        TypedReviewSnapshotFailure.invalidEnvelope,
      );
    });

    test('validates bounded lower_snake_case reasons', () {
      expect(isValidImportStorageReason('typed_candidate_ready'), isTrue);
      expect(isValidImportStorageReason(''), isFalse);
      expect(isValidImportStorageReason('MixedCase'), isFalse);
      expect(isValidImportStorageReason('with space'), isFalse);
      expect(isValidImportStorageReason('a' * 65), isFalse);
      expect(normalizeImportStorageReason(null), isNull);
      expect(
        normalizeImportStorageReason('typed_candidate_ready'),
        'typed_candidate_ready',
      );
      _expectFailure(
        () => normalizeImportStorageReason('Not-Snake'),
        TypedReviewSnapshotFailure.invalidEnvelope,
      );
    });
  });

  group('canonical UUIDv4 identity', () {
    test('accepts lowercase canonical UUIDv4 values', () {
      expect(isCanonicalUuidV4(_uuidA), isTrue);
      expect(isCanonicalUuidV4(_uuidB), isTrue);
      expect(isCanonicalUuidV4(_uuidC), isTrue);
    });

    test('rejects non-canonical or non-v4 values', () {
      expect(isCanonicalUuidV4(_uuidA.toUpperCase()), isFalse);
      expect(
        isCanonicalUuidV4('0d8b7a3e-7f1c-3b2a-9d3e-5a6b7c8d9e0f'),
        isFalse,
      );
      expect(
        isCanonicalUuidV4('0d8b7a3e-7f1c-4b2a-6d3e-5a6b7c8d9e0f'),
        isFalse,
      );
      expect(isCanonicalUuidV4('not-a-uuid'), isFalse);
      expect(isCanonicalUuidV4('0d8b7a3e7f1c4b2a9d3e5a6b7c8d9e0f'), isFalse);
    });
  });

  group('TypedReviewSnapshotCodec round-trip', () {
    test('round-trips the complete snapshot with exact root keys', () {
      final snapshot = _fullSnapshot();

      final encoded = codec.encode(snapshot);
      expect(encoded.keys.toSet(), <String>{
        'schemaVersion',
        'route',
        'reviewItemId',
        'questionId',
        'draft',
        'baselineLegacy',
      });
      expect(encoded['schemaVersion'], 1);
      expect(encoded['route'], 'typedV2');
      expect(encoded['reviewItemId'], _uuidA);
      expect(encoded['questionId'], _uuidB);

      final decoded = codec.decodeRequired(encoded);
      expect(decoded, snapshot);
      expect(codec.encode(decoded), encoded);
    });

    test('preserves text, inline math, block math and raw fallback order', () {
      final decoded = codec.decodeRequired(codec.encode(_fullSnapshot()));

      expect(
        decoded.draft.stem.nodes.map((node) => node.runtimeType),
        <Type>[
          TextNode,
          InlineMathNode,
          BlockMathNode,
          RawFallbackNode,
        ],
      );
    });

    test('round-trips a safe RawFallbackNode', () {
      final decoded = codec.decodeRequired(codec.encode(_fullSnapshot()));
      final raw = (decoded.draft.stem.nodes.last as RawFallbackNode).rawJson;
      expect(raw['type'], 'future_diagram');
      expect(raw['payload'], <Object?, Object?>{
        'kind': 'synthetic',
        'count': 1,
      });
    });

    test('round-trips ChoiceAnswer and ContentAnswer', () {
      final choice = codec.decodeRequired(codec.encode(_fullSnapshot()));
      expect(
        choice.draft.answer,
        ChoiceAnswer(optionIds: <String>['option_b']),
      );

      final contentSnapshot = _fullSnapshot(
        draft: _fullDraft(
          answer: ContentAnswer(
            content: RichContent(nodes: const <ContentNode>[
              TextNode('Synthetic content answer'),
            ]),
          ),
        ),
      );
      final content = codec.decodeRequired(codec.encode(contentSnapshot));
      expect(
        content.draft.answer,
        ContentAnswer(
          content: RichContent(
            nodes: <ContentNode>[TextNode('Synthetic content answer')],
          ),
        ),
      );
    });

    test('preserves sourceRefs, assetRefs and issues', () {
      final decoded = codec.decodeRequired(codec.encode(_fullSnapshot()));

      expect(decoded.draft.sourceRefs, _fullDraft().sourceRefs);
      expect(decoded.draft.assetRefs, _fullDraft().assetRefs);
      expect(decoded.draft.issues, _fullDraft().issues);
    });

    test('round-trips every baseline field', () {
      final decoded = codec.decodeRequired(codec.encode(_fullSnapshot()));

      expect(decoded.baselineLegacy.type, 0);
      expect(decoded.baselineLegacy.questionNumber, 3);
      expect(decoded.baselineLegacy.content, 'Synthetic baseline content');
      expect(decoded.baselineLegacy.options, <String>['A', 'B', 'C']);
      expect(decoded.baselineLegacy.standardAnswer, 'B');
      expect(
        decoded.baselineLegacy.explanation,
        'Synthetic baseline explanation',
      );
    });

    test('baseline options are a defensive unmodifiable copy', () {
      final mutableOptions = <String>['A', 'B'];
      final baseline = LegacyReviewBaseline(
        type: 0,
        questionNumber: null,
        content: 'synthetic',
        options: mutableOptions,
        standardAnswer: 'A',
        explanation: 'synthetic',
      );
      mutableOptions.add('C');

      expect(baseline.options, <String>['A', 'B']);
      expect(() => baseline.options.add('C'), throwsUnsupportedError);
    });

    test('decode does not retain caller mutable map references', () {
      final encoded = codec.encode(_fullSnapshot());
      final decoded = codec.decodeRequired(encoded);

      final draftMap = encoded['draft']! as Map<String, Object?>;
      draftMap['questionId'] = 'changed-after-decode';
      final baselineMap = encoded['baselineLegacy']! as Map<String, Object?>;
      (baselineMap['options']! as List).add('changed');

      expect(decoded.questionId, _uuidB);
      expect(decoded.draft.questionId, _uuidB);
      expect(decoded.baselineLegacy.options, <String>['A', 'B', 'C']);
      expect(
        () => decoded.baselineLegacy.options.add('changed'),
        throwsUnsupportedError,
      );
    });
  });

  group('strict envelope validation', () {
    test('decodeRequired(null) is missingPayload', () {
      _expectFailure(
        () => codec.decodeRequired(null),
        TypedReviewSnapshotFailure.missingPayload,
      );
    });

    test('containsEnvelope only distinguishes key presence', () {
      expect(codec.containsEnvelope(<String, Object?>{}), isFalse);
      expect(
        codec.containsEnvelope(<String, Object?>{
          TypedReviewSnapshotCodec.mapKey: <String, Object?>{},
        }),
        isTrue,
      );
      expect(codec.containsEnvelope(null), isFalse);
    });

    test('rejects envelope questionId mismatching the draft', () {
      final snapshot = _fullSnapshot(
        draft: _fullDraft(questionId: _uuidC),
      );
      _expectFailure(
        () => codec.encode(snapshot),
        TypedReviewSnapshotFailure.invalidIdentity,
      );

      final encoded = codec.encode(_fullSnapshot());
      (encoded['draft']! as Map<String, Object?>)['questionId'] = _uuidC;
      _expectFailure(
        () => codec.decodeRequired(encoded),
        TypedReviewSnapshotFailure.invalidIdentity,
      );
    });

    test('rejects non-canonical UUIDv4 identifiers', () {
      _expectFailure(
        () => codec.encode(TypedReviewSnapshot(
          reviewItemId: _uuidA.toUpperCase(),
          questionId: _uuidB,
          draft: _fullDraft(),
          baselineLegacy: _fullBaseline(),
        )),
        TypedReviewSnapshotFailure.invalidIdentity,
      );
      _expectFailure(
        () => codec.encode(TypedReviewSnapshot(
          reviewItemId: _uuidA,
          questionId: '0d8b7a3e-7f1c-3b2a-9d3e-5a6b7c8d9e0f',
          draft: _fullDraft(
            questionId: '0d8b7a3e-7f1c-3b2a-9d3e-5a6b7c8d9e0f',
          ),
          baselineLegacy: _fullBaseline(),
        )),
        TypedReviewSnapshotFailure.invalidIdentity,
      );
    });

    test('rejects unknown and wrong-typed schema versions', () {
      final encoded = codec.encode(_fullSnapshot());
      encoded['schemaVersion'] = 2;
      _expectFailure(
        () => codec.decodeRequired(encoded),
        TypedReviewSnapshotFailure.unsupportedSchema,
      );

      final typedWrong = codec.encode(_fullSnapshot());
      typedWrong['schemaVersion'] = '1';
      _expectFailure(
        () => codec.decodeRequired(typedWrong),
        TypedReviewSnapshotFailure.unsupportedSchema,
      );
    });

    test('rejects extra or missing root keys', () {
      final extra = codec.encode(_fullSnapshot());
      extra['unexpectedKey'] = 'value';
      _expectFailure(
        () => codec.decodeRequired(extra),
        TypedReviewSnapshotFailure.invalidEnvelope,
      );

      final missing = codec.encode(_fullSnapshot())..remove('draft');
      _expectFailure(
        () => codec.decodeRequired(missing),
        TypedReviewSnapshotFailure.invalidEnvelope,
      );
    });

    test('rejects baseline extra keys and invalid baseline fields', () {
      final extraBaseline = codec.encode(_fullSnapshot());
      (extraBaseline['baselineLegacy']! as Map<String, Object?>)['extra'] = 1;
      _expectFailure(
        () => codec.decodeRequired(extraBaseline),
        TypedReviewSnapshotFailure.invalidEnvelope,
      );

      final badType = codec.encode(_fullSnapshot());
      (badType['baselineLegacy']! as Map<String, Object?>)['type'] = 1;
      _expectFailure(
        () => codec.decodeRequired(badType),
        TypedReviewSnapshotFailure.invalidEnvelope,
      );

      final badQuestionNumber = codec.encode(_fullSnapshot());
      (badQuestionNumber['baselineLegacy']!
          as Map<String, Object?>)['questionNumber'] = 0;
      _expectFailure(
        () => codec.decodeRequired(badQuestionNumber),
        TypedReviewSnapshotFailure.invalidEnvelope,
      );

      final nonStringOption = codec.encode(_fullSnapshot());
      (nonStringOption['baselineLegacy']! as Map<String, Object?>)['options'] =
          <Object?>['A', 42, 'C'];
      _expectFailure(
        () => codec.decodeRequired(nonStringOption),
        TypedReviewSnapshotFailure.invalidEnvelope,
      );
    });

    test('rejects unknown routes and non-typed routes', () {
      final unknownRoute = codec.encode(_fullSnapshot());
      unknownRoute['route'] = 'legacyV9';
      _expectFailure(
        () => codec.decodeRequired(unknownRoute),
        TypedReviewSnapshotFailure.invalidEnvelope,
      );

      final legacyRoute = codec.encode(_fullSnapshot());
      legacyRoute['route'] = 'legacyV1';
      _expectFailure(
        () => codec.decodeRequired(legacyRoute),
        TypedReviewSnapshotFailure.routeMismatch,
      );
    });

    test('requireTypedEnvelope blocks typed routes without an envelope', () {
      codec.requireTypedEnvelope(
        ImportStorageRoute.typedV2,
        <String, Object?>{
          TypedReviewSnapshotCodec.mapKey: <String, Object?>{
            'schemaVersion': 1,
          }
        },
      );
      codec.requireTypedEnvelope(
          ImportStorageRoute.legacyV1, <String, Object?>{});
      _expectFailure(
        () => codec.requireTypedEnvelope(
            ImportStorageRoute.typedV2, <String, Object?>{}),
        TypedReviewSnapshotFailure.routeMismatch,
      );
    });
  });

  group('privacy admission', () {
    test('encode fails when the stem carries a path raw fallback', () {
      final snapshot = _fullSnapshot(
        draft: _fullDraft(
          stem: RichContent(nodes: <ContentNode>[
            RawFallbackNode(_unsafePathRawJson()),
          ]),
        ),
      );
      _expectFailure(
        () => codec.encode(snapshot),
        TypedReviewSnapshotFailure.unsafePayload,
      );
    });

    test('encode fails when an option carries URL or raw response content', () {
      final snapshot = _fullSnapshot(
        draft: _fullDraft(
          stem: RichContent(nodes: const <ContentNode>[
            TextNode('Synthetic stem'),
          ]),
          answer: ChoiceAnswer(optionIds: <String>['option_a']),
        ),
      );
      final withUrl = TypedReviewSnapshot(
        reviewItemId: snapshot.reviewItemId,
        questionId: snapshot.questionId,
        draft: QuestionDraftV2(
          questionId: snapshot.draft.questionId,
          kind: QuestionKind.singleChoice,
          stem: snapshot.draft.stem,
          options: <QuestionOption>[
            QuestionOption(
              optionId: 'option_a',
              label: 'A',
              content: RichContent(nodes: <ContentNode>[
                RawFallbackNode(_unsafeUrlRawJson()),
              ]),
            ),
          ],
          answer: ChoiceAnswer(optionIds: <String>['option_a']),
        ),
        baselineLegacy: _fullBaseline(),
      );
      _expectFailure(
        () => codec.encode(withUrl),
        TypedReviewSnapshotFailure.unsafePayload,
      );
    });

    test('encode fails when ContentAnswer carries base64 or credentials', () {
      final snapshot = _fullSnapshot(
        draft: _fullDraft(
          stem: RichContent(nodes: const <ContentNode>[
            TextNode('Synthetic stem'),
          ]),
          answer: ContentAnswer(
            content: RichContent(nodes: <ContentNode>[
              RawFallbackNode(_unsafeCredentialRawJson()),
            ]),
          ),
        ),
      );
      _expectFailure(
        () => codec.encode(snapshot),
        TypedReviewSnapshotFailure.unsafePayload,
      );
    });

    test('encode fails when the explanation carries a Provider body', () {
      final snapshot = _fullSnapshot(
        draft: _fullDraft(
          explanation: RichContent(nodes: <ContentNode>[
            RawFallbackNode(_unsafeProviderBodyRawJson()),
          ]),
        ),
      );
      _expectFailure(
        () => codec.encode(snapshot),
        TypedReviewSnapshotFailure.unsafePayload,
      );
    });

    test('decode fails on a hand-built unsafe encoded map', () {
      final encoded = codec.encode(_fullSnapshot());
      (encoded['draft']! as Map<String, Object?>)['stem'] = <String, Object?>{
        'schemaVersion': 1,
        'nodes': <Object?>[
          <String, Object?>{
            'type': 'future_diagram',
            'providerResponse': <String, Object?>{
              'marker': _secretMarker,
              'status': 'synthetic',
            },
          },
        ],
      };
      _expectFailure(
        () => codec.decodeRequired(encoded),
        TypedReviewSnapshotFailure.unsafePayload,
      );
    });

    test('all exception text is fixed and never leaks payloads', () {
      const fixedTexts = <String>[
        'Typed review snapshot payload is missing.',
        'Typed review snapshot schema version is unsupported.',
        'Typed review snapshot envelope is invalid.',
        'Typed review snapshot identity is invalid.',
        'Typed review snapshot route does not match.',
        'Typed review snapshot payload is unsafe.',
      ];

      final unsafeSnapshot = _fullSnapshot(
        draft: _fullDraft(
          stem: RichContent(nodes: <ContentNode>[
            RawFallbackNode(_unsafePathRawJson()),
          ]),
        ),
      );
      final encodeError = _expectFailure(
        () => codec.encode(unsafeSnapshot),
        TypedReviewSnapshotFailure.unsafePayload,
      );
      expect(encodeError.toString(), isNot(contains(_secretMarker)));
      expect(encodeError.toString(), isNot(contains(r'C:\')));
      expect(encodeError.toString(), isNot(contains('https://')));
      expect(fixedTexts, contains(encodeError.toString()));

      final encoded = codec.encode(_fullSnapshot());
      (encoded['draft']! as Map<String, Object?>)['stem'] = <String, Object?>{
        'schemaVersion': 1,
        'nodes': <Object?>[
          <String, Object?>{
            'type': 'future_diagram',
            'payload': <String, Object?>{
              'marker': _secretMarker,
              'path': r'C:\synthetic\private\file.pdf',
            },
          },
        ],
      };
      final decodeError = _expectFailure(
        () => codec.decodeRequired(encoded),
        TypedReviewSnapshotFailure.unsafePayload,
      );
      expect(decodeError.toString(), isNot(contains(_secretMarker)));
      expect(decodeError.toString(), isNot(contains(r'C:\')));
      expect(decodeError.toString(), isNot(contains('https://')));
      expect(decodeError.toString(), isNot(contains('SYNTHETIC')));
      expect(fixedTexts, contains(decodeError.toString()));
    });
  });
}
