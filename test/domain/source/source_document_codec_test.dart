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

      expect(encoded['schemaVersion'], SourceDocumentCodec.schemaVersion);
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
        ..['schemaVersion'] = 3;

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

  group('SourceDocumentCodec table versioning', () {
    test('upgrades a representable v1 table to unit-span structure', () {
      final decoded = codec.decode(
        _documentJson(
          schemaVersion: SourceDocumentCodec.legacySchemaVersion,
          parts: <Object?>[_legacyTablePartJson(_legacyRowsJson())],
        ),
      );
      final table = decoded.parts.single as SourceTablePart;

      expect(table.isNormalized, isTrue);
      expect(table.structure!.rows, hasLength(2));
      expect(
        table.structure!.rows.expand((row) => row.cells),
        everyElement(
          predicate<TableCell>(
            (cell) => cell.rowSpan == 1 && cell.columnSpan == 1,
          ),
        ),
      );
      expect(table.rows, hasLength(2));
    });

    test('preserves ragged, empty, and raw-fallback v1 tables as legacy', () {
      final cases = <List<List<Object?>>>[
        <List<Object?>>[
          <Object?>[
            _richTextJson('a'),
            _richTextJson('b'),
          ],
          <Object?>[_richTextJson('c')],
        ],
        <List<Object?>>[],
        <List<Object?>>[<Object?>[]],
        <List<Object?>>[
          <Object?>[
            <String, Object?>{
              'schemaVersion': 1,
              'nodes': <Object?>[
                <String, Object?>{
                  'type': 'raw_fallback',
                  'payload': <String, Object?>{
                    'kind': 'legacy_table',
                  },
                },
              ],
            },
          ],
        ],
      ];

      for (final rows in cases) {
        final decoded = codec.decode(
          _documentJson(
            schemaVersion: SourceDocumentCodec.legacySchemaVersion,
            parts: <Object?>[
              _legacyTablePartJson(rows),
            ],
          ),
        );
        final table = decoded.parts.single as SourceTablePart;

        expect(table.structure, isNull);
        expect(table.rows, hasLength(rows.length));
      }
    });

    test('round-trips row, column, and combined spans in v2', () {
      final document = _spannedTableDocument();
      final encoded = codec.encode(document);
      final tableJson =
          (encoded['parts']! as List<Object?>).single! as Map<String, Object?>;

      expect(encoded['schemaVersion'], SourceDocumentCodec.schemaVersion);
      expect(tableJson.keys, contains('structure'));
      expect(tableJson.keys, isNot(contains('rows')));

      final decoded = codec.decode(encoded);
      expect(decoded, equals(document));
      final table = decoded.parts.single as SourceTablePart;
      expect(table.structure!.rows.first.cells.first.rowSpan, 2);
      expect(table.structure!.rows.first.cells.first.columnSpan, 2);
    });

    test('keeps an explicit v2 legacy carrier lossless', () {
      final document = SourceDocument(
        sourceId: 'artifact_0001',
        parts: <SourcePart>[
          SourceTablePart.legacy(
            sourceRef: SourceRef.document(sourceId: 'artifact_0001'),
            rows: <List<RichContent>>[
              <RichContent>[_richText('a'), _richText('b')],
            ],
          ),
        ],
      );

      final encoded = codec.encode(document);
      final tableJson =
          (encoded['parts']! as List<Object?>).single! as Map<String, Object?>;
      expect(tableJson.keys, contains('legacyRows'));
      expect(codec.decode(encoded), equals(document));
      expect(
        (codec.decode(encoded).parts.single as SourceTablePart).structure,
        isNull,
      );
    });

    test('rejects invalid v2 table geometry', () {
      final encoded = codec.encode(_spannedTableDocument());
      final parts = encoded['parts']! as List<Object?>;
      final table = parts.single! as Map<String, Object?>;
      final structure = table['structure']! as Map<String, Object?>;
      final rows = structure['rows']! as List<Object?>;
      final firstRow = rows.first! as Map<String, Object?>;
      final cells = firstRow['cells']! as List<Object?>;
      final firstCell = cells.first! as Map<String, Object?>;
      firstCell['rowSpan'] = 99;

      expect(() => codec.decode(encoded), throwsFormatException);
    });

    test('re-encodes unit-span tables as legacy v1 and rejects spanned tables',
        () {
      final unit = codec.encodeLegacyV1(_fullDocument());
      expect(unit['schemaVersion'], SourceDocumentCodec.legacySchemaVersion);
      final table =
          (unit['parts']! as List<Object?>)[1]! as Map<String, Object?>;
      expect(table.keys, contains('rows'));
      expect(table.keys, isNot(contains('structure')));
      expect(codec.decode(unit), equals(_fullDocument()));

      expect(
        () => codec.encodeLegacyV1(_spannedTableDocument()),
        throwsFormatException,
      );
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
  int schemaVersion = 1,
  List<Object?> parts = const <Object?>[],
  List<Object?> issues = const <Object?>[],
}) {
  return <String, Object?>{
    'schemaVersion': schemaVersion,
    'sourceId': 'artifact_0001',
    'displayLabel': null,
    'parts': parts,
    'issues': issues,
  };
}

SourceDocument _spannedTableDocument() {
  return SourceDocument(
    sourceId: 'artifact_0001',
    parts: <SourcePart>[
      SourceTablePart.normalized(
        sourceRef: SourceRef.document(sourceId: 'artifact_0001'),
        structure: TableStructure(
          rows: <TableRow>[
            TableRow(
              cells: <TableCell>[
                TableCell(
                  content: _richText('merged'),
                  rowSpan: 2,
                  columnSpan: 2,
                ),
                TableCell(content: _richText('right')),
              ],
            ),
            TableRow(cells: <TableCell>[TableCell(content: _richText('tail'))]),
          ],
        ),
      ),
    ],
  );
}

List<List<Object?>> _legacyRowsJson() {
  return <List<Object?>>[
    <Object?>[_richTextJson('a'), _richTextJson('b')],
    <Object?>[_richTextJson('c'), _richTextJson('d')],
  ];
}

Map<String, Object?> _legacyTablePartJson(List<List<Object?>> rows) {
  return <String, Object?>{
    'type': 'table',
    'sourceRef': <String, Object?>{
      'type': 'document',
      'sourceId': 'artifact_0001',
      'displayLabel': null,
    },
    'rows': rows,
  };
}

RichContent _richText(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

Map<String, Object?> _richTextJson(String text) {
  return <String, Object?>{
    'schemaVersion': 1,
    'nodes': <Object?>[
      <String, Object?>{'type': 'text', 'text': text},
    ],
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
