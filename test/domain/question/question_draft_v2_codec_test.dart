import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  const codec = QuestionDraftV2Codec();

  group('QuestionDraftV2Codec schema v1', () {
    test('round-trips the complete aggregate with exact wire shapes', () {
      final draft = _fullChoiceDraft();

      final encoded = codec.encode(draft);
      final decoded = codec.decode(encoded);
      final reencoded = codec.encode(decoded);

      expect(encoded.keys.toSet(), _rootKeys);
      expect(encoded['schemaVersion'], 1);
      expect(encoded['kind'], 'single_choice');
      expect((encoded['answer']! as Map)['type'], 'choice');
      expect(
        ((encoded['answer']! as Map)['optionIds']! as List),
        ['option_b', 'future_option'],
      );

      final options = encoded['options']! as List;
      expect((options.single as Map).keys.toSet(), _optionKeys);

      final sourceRefs = encoded['sourceRefs']! as List;
      expect(
        sourceRefs.map((source) => (source as Map)['type']),
        ['document', 'point', 'point', 'range'],
      );
      expect((sourceRefs[0] as Map).keys.toSet(), _documentSourceKeys);
      expect((sourceRefs[1] as Map).keys.toSet(), _pointSourceKeys);
      expect((sourceRefs[3] as Map).keys.toSet(), _rangeSourceKeys);
      expect(
        (((sourceRefs[1] as Map)['point']! as Map).keys.toSet()),
        _pagePointKeys,
      );
      expect(
        (((sourceRefs[2] as Map)['point']! as Map).keys.toSet()),
        _blockPointKeys,
      );

      expect(decoded, draft);
      expect(decoded.hashCode, draft.hashCode);
      expect(reencoded, encoded);
    });

    test('preserves missing values, empty content, and unknown content nodes',
        () {
      final draft = QuestionDraftV2(
        questionId: 'question_future_001',
        kind: QuestionKind.fillBlank,
        stem: _futureContent(),
        answer: ContentAnswer(content: _futureContent()),
        explanation: RichContent(nodes: const <ContentNode>[]),
        issues: [
          ImportIssue(
            code: 'future_valid_signal',
            severity: ImportIssueSeverity.info,
          ),
        ],
      );

      final encoded = codec.encode(draft);
      final decoded = codec.decode(encoded);

      expect(encoded['questionNumber'], isNull);
      expect(encoded['options'], isEmpty);
      expect(encoded['explanation'], isNotNull);
      expect(((encoded['explanation']! as Map)['nodes']! as List), isEmpty);
      expect((encoded['answer']! as Map)['type'], 'content');
      expect(decoded, draft);
      expect(decoded.stem.nodes[1], isA<RawFallbackNode>());
      expect(
        ((decoded.answer! as ContentAnswer).content.nodes[1] as RawFallbackNode)
            .rawJson,
        _futureNode().rawJson,
      );

      final missing = QuestionDraftV2(
        questionId: 'question_missing_001',
        kind: QuestionKind.shortAnswer,
        stem: RichContent(nodes: const <ContentNode>[]),
      );
      final missingJson = codec.encode(missing);
      expect(missingJson['answer'], isNull);
      expect(missingJson['explanation'], isNull);
      expect(codec.decode(missingJson), missing);
    });

    test('encode returns a fresh mutable graph detached from the model', () {
      final draft = _fullChoiceDraft();
      final expected = codec.encode(draft);
      final encoded = codec.encode(draft);

      encoded['questionId'] = 'changed';
      final options = encoded['options']! as List;
      (options.single as Map)['label'] = 'changed';
      final stem = encoded['stem']! as Map;
      final stemNodes = stem['nodes']! as List;
      (stemNodes[1] as Map)['type'] = 'changed_type';
      (encoded['sourceRefs']! as List)[0] = <String, Object?>{};

      expect(codec.encode(draft), expected);
      expect(draft.questionId, 'question_full_001');
      expect(draft.options.single.label, '甲');
      expect((draft.stem.nodes[1] as RawFallbackNode).rawJson['type'],
          'future_diagram');
    });

    test('decode copies nested input before constructing the model', () {
      final input = codec.encode(_fullChoiceDraft());
      final decoded = codec.decode(input);
      final expected = codec.encode(decoded);

      input['questionId'] = 'changed';
      final stem = input['stem']! as Map;
      final nodes = stem['nodes']! as List;
      final futureNode = nodes[1] as Map;
      final payload = futureNode['payload']! as Map;
      (payload['items']! as List)[0] = 'changed';
      (input['options']! as List).clear();
      (input['sourceRefs']! as List).clear();
      (input['assetRefs']! as List).clear();
      (input['issues']! as List).clear();

      expect(codec.encode(decoded), expected);
    });
  });

  group('QuestionDraftV2Codec strict decoding', () {
    test('requires a string-keyed root with every exact schema field', () {
      for (final invalidRoot in <Object?>[null, true, 1, 'json', <Object?>[]]) {
        expect(() => codec.decode(invalidRoot), throwsFormatException);
      }

      final nonStringKey = <Object?, Object?>{
        ..._validJson(),
        1: 'not-a-string-key',
      };
      expect(() => codec.decode(nonStringKey), throwsFormatException);

      for (final key in _rootKeys) {
        final missing = _validJson()..remove(key);
        expect(
          () => codec.decode(missing),
          throwsFormatException,
          reason: 'missing root key $key must fail',
        );
      }

      final extra = _validJson()..['futureRootField'] = true;
      expect(() => codec.decode(extra), throwsFormatException);
    });

    test('distinguishes malformed and unsupported schema versions', () {
      for (final version in <Object?>[null, true, 1.0, '1']) {
        final malformed = _validJson()..['schemaVersion'] = version;
        expect(() => codec.decode(malformed), throwsFormatException);
      }

      final unsupported = _validJson()..['schemaVersion'] = 2;
      expect(() => codec.decode(unsupported), throwsUnsupportedError);
    });

    test('rejects malformed root scalar and collection fields', () {
      _expectFormat(codec, (json) => json['questionId'] = 'question id');
      _expectFormat(codec, (json) => json['questionNumber'] = 1.0);
      _expectFormat(codec, (json) => json['questionNumber'] = 0);
      _expectFormat(codec, (json) => json['kind'] = 0);
      _expectFormat(codec, (json) => json['kind'] = 'future_kind');
      _expectFormat(codec, (json) => json['stem'] = <Object?>[]);
      _expectFormat(codec, (json) => json['options'] = <String, Object?>{});
      _expectFormat(codec, (json) => json['sourceRefs'] = null);
      _expectFormat(codec, (json) => json['assetRefs'] = 'assets');
      _expectFormat(codec, (json) => json['issues'] = 1);

      _expectFormat(codec, (json) {
        final stem = json['stem']! as Map;
        stem['nodes'] = <Object?>[
          <String, Object?>{'type': 0},
        ];
      });
    });

    test('rejects malformed options and answer variants atomically', () {
      _expectFormat(codec, (json) {
        json['options'] = <Object?>[
          ...(json['options']! as List),
          'not-an-option',
        ];
      });
      _expectFormat(codec, (json) {
        final option = (json['options']! as List).single as Map;
        option['futureField'] = true;
      });
      _expectFormat(codec, (json) {
        final option = (json['options']! as List).single as Map;
        option.remove('sourceRef');
      });
      _expectFormat(codec, (json) {
        final option = (json['options']! as List).single as Map;
        option['content'] = null;
      });

      _expectFormat(codec, (json) => json['answer'] = <Object?>[]);
      _expectFormat(codec, (json) {
        json['answer'] = <String, Object?>{'type': 0, 'optionIds': <String>[]};
      });
      _expectFormat(codec, (json) {
        json['answer'] = <String, Object?>{
          'type': 'future_answer',
          'optionIds': <String>['option_a'],
        };
      });
      _expectFormat(codec, (json) {
        json['answer'] = <String, Object?>{
          'type': 'choice',
          'optionIds': <String>[],
        };
      });
      _expectFormat(codec, (json) {
        json['answer'] = <String, Object?>{
          'type': 'choice',
          'optionIds': <Object?>['option_a', 1],
        };
      });
      _expectFormat(codec, (json) {
        json['answer'] = <String, Object?>{
          'type': 'content',
          'content': null,
        };
      });
      _expectFormat(codec, (json) {
        final answer = json['answer']! as Map;
        answer['futureField'] = true;
      });
      _expectFormat(codec, (json) => json['explanation'] = 'content');
    });

    test('rejects malformed source projections and point variants', () {
      _expectFormat(codec, (json) {
        (json['sourceRefs']! as List).add(<String, Object?>{
          'type': 0,
          'sourceId': 'source_001',
          'displayLabel': null,
        });
      });
      _expectFormat(codec, (json) {
        (json['sourceRefs']! as List).add(<String, Object?>{
          'type': 'document',
          'sourceId': 'source_001',
          'displayLabel': null,
          'futureField': true,
        });
      });
      _expectFormat(codec, (json) {
        (json['sourceRefs']! as List).add(<String, Object?>{
          'type': 'point',
          'sourceId': 'source_001',
          'displayLabel': null,
          'point': <String, Object?>{
            'type': 0,
            'pageNumber': 1,
          },
        });
      });
      _expectFormat(codec, (json) {
        (json['sourceRefs']! as List).add(<String, Object?>{
          'type': 'point',
          'sourceId': 'source_001',
          'displayLabel': null,
          'point': <String, Object?>{
            'type': 'block',
            'pageNumber': 1,
            'blockId': 'block_001',
          },
        });
      });
      _expectFormat(codec, (json) {
        (json['sourceRefs']! as List).add(<String, Object?>{
          'type': 'range',
          'sourceId': 'source_001',
          'displayLabel': null,
          'start': <String, Object?>{
            'type': 'block',
            'pageNumber': 1,
            'blockId': 'block_001',
            'readingOrder': 0,
          },
        });
      });
      _expectFormat(codec, (json) {
        final option = (json['options']! as List).single as Map;
        option['sourceRef'] = <String, Object?>{
          'type': 'future_source',
          'sourceId': 'source_001',
          'displayLabel': null,
        };
      });
    });

    test('rejects malformed assets and issues, including enum indexes', () {
      _expectFormat(codec, (json) {
        (json['assetRefs']! as List).add(<String, Object?>{
          'assetId': 'asset_001',
          'kind': 0,
          'mimeType': null,
          'pixelWidth': null,
          'pixelHeight': null,
        });
      });
      _expectFormat(codec, (json) {
        (json['assetRefs']! as List).add(<String, Object?>{
          'assetId': 'asset_001',
          'kind': 'image',
          'mimeType': 'image/png',
          'pixelWidth': 0,
          'pixelHeight': 10,
        });
      });
      _expectFormat(codec, (json) {
        (json['assetRefs']! as List).add(<String, Object?>{
          'assetId': 'asset_001',
          'kind': 'image',
          'mimeType': null,
          'pixelWidth': null,
          'pixelHeight': null,
          'futureField': true,
        });
      });

      _expectFormat(codec, (json) {
        (json['issues']! as List).add(<String, Object?>{
          'code': 'future_valid_signal',
          'severity': 1,
          'field': null,
          'sourceRef': null,
        });
      });
      _expectFormat(codec, (json) {
        (json['issues']! as List).add(<String, Object?>{
          'code': 'future_valid_signal',
          'severity': 'warning',
          'field': 0,
          'sourceRef': null,
        });
      });
      _expectFormat(codec, (json) {
        (json['issues']! as List).add(<String, Object?>{
          'code': 'INVALID CODE',
          'severity': 'warning',
          'field': null,
          'sourceRef': null,
        });
      });
      _expectFormat(codec, (json) {
        (json['issues']! as List).add(<String, Object?>{
          'code': 'future_valid_signal',
          'severity': 'warning',
          'field': 'future_field',
          'sourceRef': null,
        });
      });
    });

    test('fails the whole decode when any nested list element is malformed',
        () {
      for (final field in <String>[
        'options',
        'sourceRefs',
        'assetRefs',
        'issues',
      ]) {
        final json = _validJson();
        json[field] = <Object?>[
          ...(json[field]! as List),
          null,
        ];
        expect(
          () => codec.decode(json),
          throwsFormatException,
          reason: '$field must reject a malformed nested element',
        );
      }
    });
  });

  test('encoded aggregate uses only the approved redacted structural keys', () {
    final keys = <String>{};
    _collectKeys(codec.encode(_fullChoiceDraft()), keys);

    expect(keys.intersection(_forbiddenKeys), isEmpty);
  });
}

const _rootKeys = <String>{
  'schemaVersion',
  'questionId',
  'questionNumber',
  'kind',
  'stem',
  'options',
  'answer',
  'explanation',
  'sourceRefs',
  'assetRefs',
  'issues',
};
const _optionKeys = <String>{'optionId', 'label', 'content', 'sourceRef'};
const _documentSourceKeys = <String>{'type', 'sourceId', 'displayLabel'};
const _pointSourceKeys = <String>{
  'type',
  'sourceId',
  'displayLabel',
  'point',
};
const _rangeSourceKeys = <String>{
  'type',
  'sourceId',
  'displayLabel',
  'start',
  'end',
};
const _pagePointKeys = <String>{'type', 'pageNumber'};
const _blockPointKeys = <String>{
  'type',
  'pageNumber',
  'blockId',
  'readingOrder',
};
const _forbiddenKeys = <String>{
  'path',
  'absolutePath',
  'uri',
  'url',
  'base64',
  'bytes',
  'rawText',
  'message',
  'questionIndex',
  'exception',
  'stackTrace',
  'diagnostics',
  'providerResponse',
};

QuestionDraftV2 _fullChoiceDraft() {
  final page = SourceRef.at(
    sourceId: 'source_001',
    displayLabel: 'synthetic.pdf',
    point: SourcePoint.page(pageNumber: 2),
  );
  final block = SourceRef.at(
    sourceId: 'source_001',
    displayLabel: 'synthetic.pdf',
    point: SourcePoint.block(
      pageNumber: 2,
      blockId: 'block_001',
      readingOrder: 1,
    ),
  );
  final range = SourceRef.range(
    sourceId: 'source_001',
    displayLabel: 'synthetic.pdf',
    start: SourcePoint.block(
      pageNumber: 2,
      blockId: 'block_001',
      readingOrder: 1,
    ),
    end: SourcePoint.block(
      pageNumber: 2,
      blockId: 'block_002',
      readingOrder: 2,
    ),
  );

  return QuestionDraftV2(
    questionId: 'question_full_001',
    questionNumber: 7,
    kind: QuestionKind.singleChoice,
    stem: _futureContent(),
    options: [
      QuestionOption(
        optionId: 'option_a',
        label: '甲',
        content: RichContent(nodes: const <ContentNode>[
          TextNode('synthetic option'),
          InlineMathNode(r'x+1'),
        ]),
        sourceRef: block,
      ),
    ],
    answer: ChoiceAnswer(optionIds: const ['option_b', 'future_option']),
    explanation: RichContent(nodes: const <ContentNode>[
      BlockMathNode(r'x=1'),
    ]),
    sourceRefs: [
      SourceRef.document(
        sourceId: 'source_001',
        displayLabel: 'synthetic.pdf',
      ),
      page,
      block,
      range,
    ],
    assetRefs: [
      AssetRef(
        assetId: 'asset_001',
        kind: AssetKind.image,
        mimeType: 'image/png',
        pixelWidth: 16,
        pixelHeight: 9,
      ),
    ],
    issues: [
      ImportIssue(
        code: 'future_valid_signal',
        severity: ImportIssueSeverity.warning,
        field: ImportIssueField.answer,
        sourceRef: range,
      ),
    ],
  );
}

QuestionDraftV2 _minimalDraft() {
  return QuestionDraftV2(
    questionId: 'question_minimal_001',
    kind: QuestionKind.shortAnswer,
    stem: RichContent(nodes: const <ContentNode>[TextNode('synthetic')]),
    options: [
      QuestionOption(
        optionId: 'option_a',
        label: 'A',
        content: RichContent(nodes: const <ContentNode>[]),
      ),
    ],
    answer: ContentAnswer(
      content: RichContent(nodes: const <ContentNode>[TextNode('answer')]),
    ),
  );
}

Map<String, Object?> _validJson() {
  return const QuestionDraftV2Codec().encode(_minimalDraft());
}

RichContent _futureContent() {
  return RichContent(nodes: <ContentNode>[
    const TextNode('synthetic stem'),
    _futureNode(),
  ]);
}

RawFallbackNode _futureNode() {
  return RawFallbackNode(<Object?, Object?>{
    'type': 'future_diagram',
    'payload': <Object?, Object?>{
      'enabled': true,
      'items': <Object?>[1, null, 'x'],
    },
  });
}

void _expectFormat(
  QuestionDraftV2Codec codec,
  void Function(Map<String, Object?> json) mutate,
) {
  final json = _validJson();
  mutate(json);
  expect(() => codec.decode(json), throwsFormatException);
}

void _collectKeys(Object? value, Set<String> keys) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String) keys.add(key);
      _collectKeys(entry.value, keys);
    }
  } else if (value is List) {
    for (final item in value) {
      _collectKeys(item, keys);
    }
  }
}
