import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  group('SourceDocument construction', () {
    test('represents safe identity, mixed parts, issues, and empty documents',
        () {
      final documentRef = SourceRef.document(
        sourceId: 'source_001',
        displayLabel: 'synthetic.pdf',
      );
      final parts = <SourcePart>[
        SourceContentPart(
          sourceRef: documentRef,
          content: _text('synthetic paragraph'),
        ),
        SourceTablePart(
          sourceRef: documentRef,
          rows: <List<RichContent>>[
            <RichContent>[_text('cell')],
          ],
        ),
        SourceAssetPart(
          sourceRef: documentRef,
          asset: AssetRef(assetId: 'asset_001', kind: AssetKind.image),
        ),
        UnsupportedSourcePart(
          sourceRef: documentRef,
          kindCode: 'future_layout',
          fallbackContent: _text('safe fallback'),
        ),
      ];
      final issues = <ImportIssue>[
        ImportIssue(
          code: 'field_requires_review',
          severity: ImportIssueSeverity.warning,
          field: ImportIssueField.source,
          sourceRef: documentRef,
        ),
      ];
      final document = SourceDocument(
        sourceId: 'source_001',
        displayLabel: 'synthetic.pdf',
        parts: parts,
        issues: issues,
      );
      final empty = SourceDocument(sourceId: 'source_empty');

      expect(document.documentRef, documentRef);
      expect(document.parts, parts);
      expect(document.issues, issues);
      expect(empty.parts, isEmpty);
      expect(empty.issues, isEmpty);
      expect(empty.documentRef.start, isNull);
      expect(empty.documentRef.end, isNull);
    });

    test('allows incomplete but structurally valid source facts', () {
      final documentRef = SourceRef.document(sourceId: 'source_001');
      final document = SourceDocument(
        sourceId: 'source_001',
        parts: <SourcePart>[
          SourceContentPart(
            sourceRef: documentRef,
            content: RichContent(nodes: const <ContentNode>[]),
          ),
          SourceTablePart(
            sourceRef: documentRef,
            rows: const <List<RichContent>>[<RichContent>[]],
          ),
          SourceAssetPart(
            sourceRef: documentRef,
            asset: AssetRef(assetId: 'asset_001', kind: AssetKind.image),
          ),
        ],
      );

      expect(document.parts, hasLength(3));
      expect(
        (document.parts[0] as SourceContentPart).content.nodes,
        isEmpty,
      );
      expect((document.parts[1] as SourceTablePart).rows.single, isEmpty);
      expect(
        (document.parts[2] as SourceAssetPart).alternativeText,
        isNull,
      );
    });
  });

  group('SourceDocument order and immutability', () {
    test('keeps caller order, duplicate parts, and ordered issues', () {
      final lateRef = SourceRef.at(
        sourceId: 'source_001',
        point: SourcePoint.block(
          pageNumber: 2,
          blockId: 'block_009',
          readingOrder: 9,
        ),
      );
      final earlyRef = SourceRef.at(
        sourceId: 'source_001',
        point: SourcePoint.block(
          pageNumber: 1,
          blockId: 'block_001',
          readingOrder: 0,
        ),
      );
      final repeated = SourceContentPart(
        sourceRef: lateRef,
        content: _text('repeated'),
      );
      final earlier = SourceContentPart(
        sourceRef: earlyRef,
        content: _text('earlier provenance'),
      );
      final parts = <SourcePart>[repeated, earlier, repeated];
      final firstIssue = ImportIssue(
        code: 'first_signal',
        severity: ImportIssueSeverity.info,
      );
      final secondIssue = ImportIssue(
        code: 'second_signal',
        severity: ImportIssueSeverity.warning,
      );
      final issues = <ImportIssue>[firstIssue, secondIssue];
      final document = SourceDocument(
        sourceId: 'source_001',
        parts: parts,
        issues: issues,
      );
      final originalHash = document.hashCode;

      parts.clear();
      issues.clear();

      expect(document.parts, <SourcePart>[repeated, earlier, repeated]);
      expect(document.parts[0], same(repeated));
      expect(document.parts[2], same(repeated));
      expect(document.issues, <ImportIssue>[firstIssue, secondIssue]);
      expect(document.hashCode, originalHash);
      expect(() => document.parts.clear(), throwsUnsupportedError);
      expect(() => document.issues.clear(), throwsUnsupportedError);
    });
  });

  group('SourceDocument aggregate invariants', () {
    test('delegates unsafe identity rejection to SourceRef', () {
      for (final sourceId in <String>[
        '',
        'source id',
        'folder/source.pdf',
        'file://synthetic.pdf',
        'https://example.invalid/synthetic.pdf',
      ]) {
        expect(
          () => SourceDocument(sourceId: sourceId),
          throwsFormatException,
        );
      }
      for (final displayLabel in <String>[
        '',
        'folder/synthetic.pdf',
        'file://synthetic.pdf',
        'https://example.invalid/synthetic.pdf',
      ]) {
        expect(
          () => SourceDocument(
            sourceId: 'source_001',
            displayLabel: displayLabel,
          ),
          throwsFormatException,
        );
      }
    });

    test('rejects cross-document and conflicting-label members', () {
      final otherPart = SourceContentPart(
        sourceRef: SourceRef.document(sourceId: 'source_002'),
        content: _text('synthetic'),
      );
      final conflictingLabelPart = SourceContentPart(
        sourceRef: SourceRef.document(
          sourceId: 'source_001',
          displayLabel: 'other.pdf',
        ),
        content: _text('synthetic'),
      );
      final otherIssue = ImportIssue(
        code: 'source_conflict',
        severity: ImportIssueSeverity.error,
        sourceRef: SourceRef.document(sourceId: 'source_002'),
      );

      expect(
        () => SourceDocument(sourceId: 'source_001', parts: [otherPart]),
        throwsFormatException,
      );
      expect(
        () => SourceDocument(
          sourceId: 'source_001',
          displayLabel: 'synthetic.pdf',
          parts: [conflictingLabelPart],
        ),
        throwsFormatException,
      );
      expect(
        () => SourceDocument(sourceId: 'source_001', issues: [otherIssue]),
        throwsFormatException,
      );
    });

    test('allows repeated consistent assets and rejects identity conflicts',
        () {
      final documentRef = SourceRef.document(sourceId: 'source_001');
      final first = SourceAssetPart(
        sourceRef: documentRef,
        asset: AssetRef(
          assetId: 'asset_001',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      );
      final equal = SourceAssetPart(
        sourceRef: documentRef,
        asset: AssetRef(
          assetId: 'asset_001',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      );
      final conflicting = SourceAssetPart(
        sourceRef: documentRef,
        asset: AssetRef(
          assetId: 'asset_001',
          kind: AssetKind.image,
          mimeType: 'image/jpeg',
        ),
      );

      final document = SourceDocument(
        sourceId: 'source_001',
        parts: <SourcePart>[first, equal],
      );
      expect(document.parts, hasLength(2));
      expect(
        () => SourceDocument(
          sourceId: 'source_001',
          parts: <SourcePart>[first, conflicting],
        ),
        throwsFormatException,
      );
    });

    test('scopes the same local asset ID independently per source document',
        () {
      SourceDocument build(String sourceId) {
        final documentRef = SourceRef.document(sourceId: sourceId);
        return SourceDocument(
          sourceId: sourceId,
          parts: <SourcePart>[
            SourceAssetPart(
              sourceRef: documentRef,
              asset: AssetRef(
                assetId: 'asset_000001',
                kind: AssetKind.image,
              ),
            ),
          ],
        );
      }

      final first = build('source_001');
      final second = build('source_002');

      expect(
        (first.parts.single as SourceAssetPart).asset.assetId,
        'asset_000001',
      );
      expect(
        (second.parts.single as SourceAssetPart).asset.assetId,
        'asset_000001',
      );
      expect(first.documentRef, isNot(second.documentRef));
    });
  });

  group('SourceDocument value semantics and privacy shape', () {
    test('compares the complete ordered aggregate by value', () {
      SourceDocument build({bool reverse = false}) {
        final documentRef = SourceRef.document(
          sourceId: 'source_001',
          displayLabel: 'synthetic.pdf',
        );
        final parts = <SourcePart>[
          SourceContentPart(
            sourceRef: documentRef,
            content: _futureContent(reverseKeys: reverse),
          ),
          SourceTablePart(
            sourceRef: documentRef,
            rows: <List<RichContent>>[
              <RichContent>[_text('cell')],
            ],
          ),
        ];
        return SourceDocument(
          sourceId: 'source_001',
          displayLabel: 'synthetic.pdf',
          parts: parts,
          issues: <ImportIssue>[
            ImportIssue(
              code: 'field_requires_review',
              severity: ImportIssueSeverity.warning,
              sourceRef: documentRef,
            ),
          ],
        );
      }

      final first = build();
      final equal = build(reverse: true);
      final reordered = SourceDocument(
        sourceId: 'source_001',
        displayLabel: 'synthetic.pdf',
        parts: first.parts.reversed,
        issues: first.issues,
      );

      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect(<SourceDocument>{first}, contains(equal));
      expect(reordered, isNot(first));
    });

    test('constructed public graph contains only approved structural fields',
        () {
      final documentRef = SourceRef.document(
        sourceId: 'source_001',
        displayLabel: 'synthetic.pdf',
      );
      final document = SourceDocument(
        sourceId: 'source_001',
        displayLabel: 'synthetic.pdf',
        parts: <SourcePart>[
          SourceContentPart(
            sourceRef: documentRef,
            content: _futureContent(reverseKeys: false),
          ),
          SourceTablePart(
            sourceRef: documentRef,
            rows: <List<RichContent>>[
              <RichContent>[_text('cell')],
            ],
          ),
          SourceAssetPart(
            sourceRef: documentRef,
            asset: AssetRef(assetId: 'asset_001', kind: AssetKind.image),
            alternativeText: _text('synthetic alt'),
          ),
          UnsupportedSourcePart(
            sourceRef: documentRef,
            kindCode: 'future_layout',
            fallbackContent: _text('safe fallback'),
          ),
        ],
        issues: <ImportIssue>[
          ImportIssue(
            code: 'field_requires_review',
            severity: ImportIssueSeverity.info,
            sourceRef: documentRef,
          ),
        ],
      );
      final publicGraph = _publicDocumentGraph(document);
      final keys = <String>{};
      _collectKeys(publicGraph, keys);

      expect(keys.intersection(_forbiddenStructuralKeys), isEmpty);
      expect(
        _walkValues(publicGraph).whereType<Uri>(),
        isEmpty,
      );
    });
  });
}

const _forbiddenStructuralKeys = <String>{
  'path',
  'resolvedPath',
  'uri',
  'url',
  'base64',
  'bytes',
  'rawResponse',
  'providerResponse',
  'diagnostics',
  'preview',
  'exception',
  'stackTrace',
  'credential',
  'apiKey',
};

Map<String, Object?> _publicDocumentGraph(SourceDocument document) {
  return <String, Object?>{
    'documentRef': _sourceRefGraph(document.documentRef),
    'parts': document.parts.map(_publicPartGraph).toList(),
    'issues': document.issues
        .map(
          (issue) => <String, Object?>{
            'code': issue.code,
            'severity': issue.severity.name,
            'field': issue.field?.name,
            'sourceRef': issue.sourceRef == null
                ? null
                : _sourceRefGraph(issue.sourceRef!),
          },
        )
        .toList(),
  };
}

Map<String, Object?> _publicPartGraph(SourcePart part) {
  final common = <String, Object?>{
    'sourceRef': _sourceRefGraph(part.sourceRef),
  };
  return switch (part) {
    SourceContentPart(:final content, :final role) => <String, Object?>{
        ...common,
        'role': role.name,
        'content': _contentGraph(content),
      },
    SourceTablePart(:final rows) => <String, Object?>{
        ...common,
        'rows': rows
            .map((row) => row.map(_contentGraph).toList(growable: false))
            .toList(growable: false),
      },
    SourceAssetPart(:final asset, :final alternativeText) => <String, Object?>{
        ...common,
        'asset': <String, Object?>{
          'assetId': asset.assetId,
          'kind': asset.kind.name,
          'mimeType': asset.mimeType,
          'pixelWidth': asset.pixelWidth,
          'pixelHeight': asset.pixelHeight,
        },
        'alternativeText':
            alternativeText == null ? null : _contentGraph(alternativeText),
      },
    UnsupportedSourcePart(:final kindCode, :final fallbackContent) =>
      <String, Object?>{
        ...common,
        'kindCode': kindCode,
        'fallbackContent': _contentGraph(fallbackContent),
      },
  };
}

Map<String, Object?> _sourceRefGraph(SourceRef sourceRef) {
  return <String, Object?>{
    'sourceId': sourceRef.sourceId,
    'displayLabel': sourceRef.displayLabel,
    'start':
        sourceRef.start == null ? null : _sourcePointGraph(sourceRef.start!),
    'end': sourceRef.end == null ? null : _sourcePointGraph(sourceRef.end!),
  };
}

Map<String, Object?> _sourcePointGraph(SourcePoint point) {
  return <String, Object?>{
    'pageNumber': point.pageNumber,
    'blockId': point.blockId,
    'readingOrder': point.readingOrder,
  };
}

Map<String, Object?> _contentGraph(RichContent content) {
  return <String, Object?>{
    'nodes': content.nodes.map((node) {
      return switch (node) {
        TextNode(:final text) => <String, Object?>{
            'type': 'text',
            'text': text,
          },
        InlineMathNode(:final latex) => <String, Object?>{
            'type': 'inline_math',
            'latex': latex,
          },
        BlockMathNode(:final latex) => <String, Object?>{
            'type': 'block_math',
            'latex': latex,
          },
        ImageNode(:final assetRef, :final altText) => <String, Object?>{
            'type': 'image',
            'assetRef': assetRef,
            if (altText != null) 'altText': altText,
          },
        RawFallbackNode(:final rawJson) => <String, Object?>{
            'type': 'raw_fallback',
            'formalContent': rawJson,
          },
      };
    }).toList(growable: false),
  };
}

void _collectKeys(Object? value, Set<String> keys) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is String) keys.add(entry.key as String);
      _collectKeys(entry.value, keys);
    }
  } else if (value is Iterable) {
    for (final item in value) {
      _collectKeys(item, keys);
    }
  }
}

Iterable<Object?> _walkValues(Object? value) sync* {
  yield value;
  if (value is Map) {
    for (final nested in value.values) {
      yield* _walkValues(nested);
    }
  } else if (value is Iterable) {
    for (final nested in value) {
      yield* _walkValues(nested);
    }
  }
}

RichContent _text(String value) {
  return RichContent(nodes: <ContentNode>[TextNode(value)]);
}

RichContent _futureContent({required bool reverseKeys}) {
  final payload = reverseKeys
      ? <Object?, Object?>{
          'enabled': true,
          'items': <Object?>['x', null]
        }
      : <Object?, Object?>{
          'items': <Object?>['x', null],
          'enabled': true
        };
  return RichContent(nodes: <ContentNode>[
    const TextNode('synthetic'),
    RawFallbackNode(<Object?, Object?>{
      'type': 'future_diagram',
      'payload': payload,
    }),
  ]);
}
