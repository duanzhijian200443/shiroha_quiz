import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_document_codec.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  const codec = SourceDocumentCodec();

  group('SourceDocumentCodec round-trip', () {
    test('preserves parts, refs, issues, assets, and rich content', () {
      final document = _fullDocument();

      final encoded = codec.encode(document);
      final decoded = codec.decode(encoded);

      expect(decoded, equals(document));
      expect(decoded.documentRef.sourceId, 'artifact_0001');
      expect(decoded.parts, hasLength(4));
      expect(decoded.parts[0], isA<SourceContentPart>());
      expect(decoded.parts[1], isA<SourceTablePart>());
      expect(decoded.parts[2], isA<SourceAssetPart>());
      expect(decoded.parts[3], isA<UnsupportedSourcePart>());
      expect(decoded.issues, hasLength(2));
      final content = (decoded.parts[0] as SourceContentPart).content;
      expect(content.nodes, hasLength(4));
      expect(content.nodes[0], isA<TextNode>());
      expect(content.nodes[1], isA<InlineMathNode>());
      expect(content.nodes[2], isA<BlockMathNode>());
      expect(content.nodes[3], isA<RawFallbackNode>());
      final asset = (decoded.parts[2] as SourceAssetPart).asset;
      expect(asset.mimeType, 'image/png');
      expect(asset.pixelWidth, 640);
      expect(asset.pixelHeight, 480);
    });

    test('encoding is deterministic and preserves ordering', () {
      final document = _fullDocument();

      expect(codec.encode(document), equals(codec.encode(document)));
      final decoded = codec.decode(codec.encode(document));
      expect(codec.encode(decoded), equals(codec.encode(document)));
    });
  });

  group('SourceDocumentCodec strictness', () {
    test('rejects missing root fields', () {
      final base = codec.encode(_fullDocument());
      for (final key in const <String>[
        'schemaVersion',
        'sourceId',
        'displayLabel',
        'parts',
        'issues',
      ]) {
        final copy = Map<String, Object?>.from(base)..remove(key);
        expect(
          () => codec.decode(copy),
          throwsFormatException,
          reason: key,
        );
      }
    });

    test('rejects unknown root fields', () {
      final copy = Map<String, Object?>.from(codec.encode(_fullDocument()))
        ..['extra'] = true;

      expect(() => codec.decode(copy), throwsFormatException);
    });

    test('distinguishes an unsupported root schema version', () {
      final copy = Map<String, Object?>.from(codec.encode(_fullDocument()))
        ..['schemaVersion'] = 2;

      expect(() => codec.decode(copy), throwsA(isA<UnsupportedError>()));
    });

    test('rejects unknown source part discriminators', () {
      final copy = Map<String, Object?>.from(codec.encode(_fullDocument()));
      final parts = copy['parts']! as List<Object?>;
      final first = parts.first! as Map<String, Object?>;
      first['type'] = 'hologram';

      expect(() => codec.decode(copy), throwsFormatException);
    });

    test('rejects extra fields on known part types', () {
      final copy = Map<String, Object?>.from(codec.encode(_fullDocument()));
      final parts = copy['parts']! as List<Object?>;
      final first = parts.first! as Map<String, Object?>;
      first['extra'] = true;

      expect(() => codec.decode(copy), throwsFormatException);
    });

    test('rejects malformed source refs', () {
      final invalidPoints = <Map<String, Object?>>[
        <String, Object?>{
          'type': 'page',
          'pageNumber': 0,
        },
        <String, Object?>{
          'type': 'block',
          'pageNumber': 1,
          'readingOrder': 0,
        },
        <String, Object?>{
          'type': 'block',
          'pageNumber': 1,
          'blockId': 'b1',
          'readingOrder': -1,
        },
      ];
      for (final point in invalidPoints) {
        final input = _documentJson(
          parts: <Object?>[
            _contentPartJson(
              sourceRef: <String, Object?>{
                'type': 'point',
                'sourceId': 'artifact_0001',
                'displayLabel': null,
                'point': point,
              },
            ),
          ],
        );
        expect(() => codec.decode(input), throwsFormatException);
      }

      final pageEndpoints = _contentPartJson(
        sourceRef: <String, Object?>{
          'type': 'range',
          'sourceId': 'artifact_0001',
          'displayLabel': null,
          'start': <String, Object?>{'type': 'page', 'pageNumber': 1},
          'end': <String, Object?>{'type': 'page', 'pageNumber': 2},
        },
      );
      expect(
        () => codec.decode(_documentJson(parts: <Object?>[pageEndpoints])),
        throwsFormatException,
      );

      final reversedRange = _contentPartJson(
        sourceRef: <String, Object?>{
          'type': 'range',
          'sourceId': 'artifact_0001',
          'displayLabel': null,
          'start': <String, Object?>{
            'type': 'block',
            'pageNumber': 1,
            'blockId': 'b2',
            'readingOrder': 2,
          },
          'end': <String, Object?>{
            'type': 'block',
            'pageNumber': 1,
            'blockId': 'b1',
            'readingOrder': 1,
          },
        },
      );
      expect(
        () => codec.decode(_documentJson(parts: <Object?>[reversedRange])),
        throwsFormatException,
      );
    });

    test('rejects member source identity mismatch', () {
      final input = _documentJson(
        parts: <Object?>[
          _contentPartJson(
            sourceRef: <String, Object?>{
              'type': 'document',
              'sourceId': 'artifact_0002',
              'displayLabel': null,
            },
          ),
        ],
      );

      expect(() => codec.decode(input), throwsFormatException);
    });

    test('rejects conflicting asset metadata for one asset identity', () {
      final input = _documentJson(
        parts: <Object?>[
          _assetPartJson(
            assetId: 'asset_000001',
            mimeType: 'image/png',
            readingOrder: 1,
          ),
          _assetPartJson(
            assetId: 'asset_000001',
            mimeType: 'image/jpeg',
            readingOrder: 2,
          ),
        ],
      );

      expect(() => codec.decode(input), throwsFormatException);
    });

    test('rejects privacy-invalid raw fallback metadata', () {
      final forbiddenKeys = <Map<String, Object?>>[
        <String, Object?>{
          'type': 'raw_fallback',
          'payload': <String, Object?>{'path': r'C:\private\page.pdf'},
        },
        <String, Object?>{
          'type': 'raw_fallback',
          'payload': <String, Object?>{
            'providerResponse': <String, Object?>{'text': 'raw body'},
          },
        },
        <String, Object?>{
          'type': 'raw_fallback',
          'payload': <String, Object?>{'diagnostic': 'stack trace'},
        },
      ];

      for (final node in forbiddenKeys) {
        final input = _documentJson(
          parts: <Object?>[
            _contentPartJsonWithNodes(<Object?>[node]),
          ],
        );
        expect(() => codec.decode(input), throwsFormatException);
      }
    });
  });
}

SourceDocument _fullDocument() {
  return SourceDocument(
    sourceId: 'artifact_0001',
    displayLabel: 'exam.pdf',
    parts: <SourcePart>[
      SourceContentPart(
        sourceRef: SourceRef.at(
          sourceId: 'artifact_0001',
          displayLabel: 'exam.pdf',
          point: SourcePoint.block(
            pageNumber: 1,
            blockId: 'b1',
            readingOrder: 0,
          ),
        ),
        content: RichContent(nodes: <ContentNode>[
          const TextNode('  stem with spaces  '),
          const InlineMathNode(r'\frac{1}{2}'),
          const BlockMathNode(r'\sum_{i=1}^{n}x_i'),
          RawFallbackNode(<Object?, Object?>{
            'type': 'raw_fallback',
            'payload': <Object?, Object?>{
              'kind': 'synthetic_table',
              'rows': <Object?>[
                <Object?>[1, true, null, 'x']
              ],
            },
          }),
        ]),
        role: SourceContentRole.heading,
      ),
      SourceTablePart(
        sourceRef: SourceRef.range(
          sourceId: 'artifact_0001',
          start: SourcePoint.block(
            pageNumber: 1,
            blockId: 'b2',
            readingOrder: 1,
          ),
          end: SourcePoint.block(
            pageNumber: 1,
            blockId: 'b3',
            readingOrder: 2,
          ),
        ),
        rows: <List<RichContent>>[
          <RichContent>[
            RichContent(nodes: const <ContentNode>[TextNode('cell-a')]),
            RichContent(nodes: const <ContentNode>[TextNode('cell-b')]),
          ],
          <RichContent>[
            RichContent(nodes: const <ContentNode>[InlineMathNode(r'\alpha')]),
            RichContent(nodes: const <ContentNode>[]),
          ],
        ],
      ),
      SourceAssetPart(
        sourceRef: SourceRef.at(
          sourceId: 'artifact_0001',
          point: SourcePoint.page(pageNumber: 2),
        ),
        asset: AssetRef(
          assetId: 'asset_000001',
          kind: AssetKind.image,
          mimeType: 'image/png',
          pixelWidth: 640,
          pixelHeight: 480,
        ),
        alternativeText: RichContent(
          nodes: const <ContentNode>[TextNode('diagram of process')],
        ),
      ),
      UnsupportedSourcePart(
        sourceRef: SourceRef.at(
          sourceId: 'artifact_0001',
          point: SourcePoint.block(
            pageNumber: 3,
            blockId: 'b4',
            readingOrder: 3,
          ),
        ),
        kindCode: 'complex_diagram',
        fallbackContent: RichContent(nodes: <ContentNode>[
          RawFallbackNode(<Object?, Object?>{
            'type': 'future_diagram',
            'payload': <Object?, Object?>{'id': 7},
          }),
        ]),
      ),
    ],
    issues: <ImportIssue>[
      ImportIssue(
        code: 'unsupported_part',
        severity: ImportIssueSeverity.warning,
        field: ImportIssueField.source,
        sourceRef: SourceRef.document(sourceId: 'artifact_0001'),
      ),
      ImportIssue(
        code: 'asset_unavailable',
        severity: ImportIssueSeverity.error,
        field: ImportIssueField.asset,
        sourceRef: SourceRef.at(
          sourceId: 'artifact_0001',
          point: SourcePoint.page(pageNumber: 2),
        ),
      ),
    ],
  );
}

Map<String, Object?> _documentJson({
  List<Object?> parts = const <Object?>[],
  List<Object?> issues = const <Object?>[],
}) {
  return <String, Object?>{
    'schemaVersion': 1,
    'sourceId': 'artifact_0001',
    'displayLabel': null,
    'parts': parts,
    'issues': issues,
  };
}

Map<String, Object?> _contentPartJson({
  required Map<String, Object?> sourceRef,
}) {
  return _contentPartJsonWithNodes(<Object?>[
    <String, Object?>{'type': 'text', 'text': 'parsed text'},
  ], sourceRef: sourceRef);
}

Map<String, Object?> _contentPartJsonWithNodes(
  List<Object?> nodes, {
  Map<String, Object?>? sourceRef,
}) {
  return <String, Object?>{
    'type': 'content',
    'sourceRef': sourceRef ??
        <String, Object?>{
          'type': 'document',
          'sourceId': 'artifact_0001',
          'displayLabel': null,
        },
    'content': <String, Object?>{
      'schemaVersion': 1,
      'nodes': nodes,
    },
    'role': 'paragraph',
  };
}

Map<String, Object?> _assetPartJson({
  required String assetId,
  required String mimeType,
  required int readingOrder,
}) {
  return <String, Object?>{
    'type': 'asset',
    'sourceRef': <String, Object?>{
      'type': 'point',
      'sourceId': 'artifact_0001',
      'displayLabel': null,
      'point': <String, Object?>{
        'type': 'block',
        'pageNumber': 1,
        'blockId': 'b$readingOrder',
        'readingOrder': readingOrder,
      },
    },
    'asset': <String, Object?>{
      'assetId': assetId,
      'kind': 'image',
      'mimeType': mimeType,
      'pixelWidth': null,
      'pixelHeight': null,
    },
    'alternativeText': null,
  };
}
