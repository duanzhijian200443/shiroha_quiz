import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/parsed_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_image_asset.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_signals.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/parsed_document.dart';

void main() {
  const adapter = ParsedSourceDocumentAdapter();

  group('ParsedSourceDocumentAdapter text and identity', () {
    test('preserves formal text and maps roles conservatively', () {
      const formalText =
          '  Unicode 甲\n**Markdown** \\(x+1\\) https://example.invalid '
          r'C:\lesson\example data:image/png;base64,SYNTHETIC api_key  ';
      final converted = adapter.convert(
        _parsed(
          parts: const <DocumentPart>[
            TextPart(
              order: 5,
              text: formalText,
              role: TextRole.paragraph,
            ),
            TextPart(
              order: 6,
              text: 'heading',
              role: TextRole.heading,
            ),
            TextPart(
              order: 7,
              text: 'answer',
              role: TextRole.answerBlock,
            ),
            TextPart(
              order: 8,
              text: 'print("code, not formula")',
              role: TextRole.formulaLike,
            ),
            TextPart(
              order: 9,
              text: 'legacy table cell',
              role: TextRole.tableCell,
            ),
            TextPart(order: 10, text: '', role: TextRole.paragraph),
            TextPart(order: 11, text: ' \n ', role: TextRole.paragraph),
          ],
        ),
        sourceId: 'caller_source_001',
        displayLabel: 'synthetic.md',
      );

      expect(converted.documentRef.sourceId, 'caller_source_001');
      expect(converted.documentRef.displayLabel, 'synthetic.md');
      expect(
        converted.parts.map((part) => (part as SourceContentPart).role),
        <SourceContentRole>[
          SourceContentRole.paragraph,
          SourceContentRole.heading,
          SourceContentRole.answerLike,
          SourceContentRole.unknown,
          SourceContentRole.unknown,
          SourceContentRole.paragraph,
          SourceContentRole.paragraph,
        ],
      );
      expect(
        converted.parts.map(_singlePartText),
        <String?>[
          formalText,
          'heading',
          'answer',
          'print("code, not formula")',
          'legacy table cell',
          '',
          ' \n ',
        ],
      );
      expect(
        converted.parts.every(
          (part) =>
              part.sourceRef == converted.documentRef &&
              part.sourceRef.start == null &&
              part.sourceRef.end == null,
        ),
        isTrue,
      );
      expect(converted.issues, isEmpty);
      expect(_allNodes(converted).whereType<RawFallbackNode>(), isEmpty);
    });

    test('keeps caller identity authoritative and degrades unsafe labels', () {
      final document = _parsed(
        sourceName: r'C:\metadata\same-name.md',
        parts: const <DocumentPart>[
          TextPart(
            order: 0,
            text: 'formal content',
            role: TextRole.paragraph,
          ),
        ],
      );

      final first = adapter.convert(document, sourceId: 'caller_source_a');
      final second = adapter.convert(document, sourceId: 'caller_source_b');
      final unsafeLabel = adapter.convert(
        document,
        sourceId: 'caller_source_c',
        displayLabel: r'..\metadata.md',
      );

      expect(first.documentRef.sourceId, 'caller_source_a');
      expect(second.documentRef.sourceId, 'caller_source_b');
      expect(first.documentRef, isNot(second.documentRef));
      expect(unsafeLabel.documentRef.displayLabel, isNull);
      _expectIssueContracts(
        unsafeLabel,
        <String>['parsed_display_label_invalid'],
      );
      expect(_singlePartText(unsafeLabel.parts.single), 'formal content');
      expect(
        _publicStrings(unsafeLabel),
        isNot(contains(r'C:\metadata\same-name.md')),
      );
      expect(
        () => adapter.convert(document, sourceId: 'unsafe/source'),
        throwsFormatException,
      );
    });
  });

  group('ParsedSourceDocumentAdapter order', () {
    test('keeps encounter order and treats order as consistency only', () {
      SourceDocument convert(List<DocumentPart> parts, String sourceId) {
        return adapter.convert(
          _parsed(parts: parts),
          sourceId: sourceId,
        );
      }

      final consistent = convert(
        const <DocumentPart>[
          TextPart(order: 0, text: 'first', role: TextRole.paragraph),
          TextPart(order: 1, text: 'second', role: TextRole.paragraph),
        ],
        'order_consistent',
      );
      final conflicting = convert(
        const <DocumentPart>[
          TextPart(order: 2, text: 'encounter-first', role: TextRole.paragraph),
          TextPart(
              order: 0, text: 'encounter-second', role: TextRole.paragraph),
        ],
        'order_conflicting',
      );
      final duplicate = convert(
        const <DocumentPart>[
          TextPart(order: 0, text: 'duplicate-first', role: TextRole.paragraph),
          TextPart(
              order: 0, text: 'duplicate-second', role: TextRole.paragraph),
        ],
        'order_duplicate',
      );
      final negative = convert(
        const <DocumentPart>[
          TextPart(order: -1, text: 'negative', role: TextRole.paragraph),
          TextPart(order: 0, text: 'non-negative', role: TextRole.paragraph),
        ],
        'order_negative',
      );
      final gap = convert(
        const <DocumentPart>[
          TextPart(order: 0, text: 'gap-first', role: TextRole.paragraph),
          TextPart(order: 3, text: 'gap-second', role: TextRole.paragraph),
        ],
        'order_gap',
      );

      expect(
          consistent.parts.map(_singlePartText), <String?>['first', 'second']);
      expect(consistent.issues, isEmpty);
      expect(
        conflicting.parts.map(_singlePartText),
        <String?>['encounter-first', 'encounter-second'],
      );
      _expectIssueContracts(conflicting, <String>['parsed_order_invalid']);
      expect(
        duplicate.parts.map(_singlePartText),
        <String?>['duplicate-first', 'duplicate-second'],
      );
      _expectIssueContracts(duplicate, <String>['parsed_order_duplicate']);
      _expectIssueContracts(negative, <String>['parsed_order_invalid']);
      expect(
          gap.parts.map(_singlePartText), <String?>['gap-first', 'gap-second']);
      expect(gap.issues, isEmpty);
    });
  });

  group('ParsedSourceDocumentAdapter tables', () {
    test('preserves two-dimensional, empty, ragged, and duplicate cells', () {
      final converted = adapter.convert(
        _parsed(
          parts: <DocumentPart>[
            TablePart(
              order: 0,
              rows: <List<String>>[
                <String>['r1c1', '', r'C:\formal\cell'],
                <String>[],
                <String>['duplicate'],
                <String>['duplicate'],
                <String>['ragged', 'tail'],
              ],
            ),
          ],
        ),
        sourceId: 'table_source',
      );

      final table = converted.parts.single as SourceTablePart;
      expect(table.rows, hasLength(5));
      expect(table.rows[0].map(_singleContentText), <String?>[
        'r1c1',
        '',
        r'C:\formal\cell',
      ]);
      expect(table.rows[1], isEmpty);
      expect(table.rows[2].map(_singleContentText), <String?>['duplicate']);
      expect(table.rows[3].map(_singleContentText), <String?>['duplicate']);
      expect(
          table.rows[4].map(_singleContentText), <String?>['ragged', 'tail']);
      expect(converted.issues, isEmpty);
      expect(_allNodes(converted).whereType<RawFallbackNode>(), isEmpty);
    });

    test('keeps empty tables and marks an otherwise empty document', () {
      final empty = adapter.convert(
        _parsed(
          parts: <DocumentPart>[
            TablePart(order: 0, rows: <List<String>>[]),
          ],
        ),
        sourceId: 'empty_table',
      );
      final emptyRow = adapter.convert(
        _parsed(
          parts: <DocumentPart>[
            TablePart(order: 0, rows: <List<String>>[<String>[]]),
          ],
        ),
        sourceId: 'empty_row',
      );

      expect((empty.parts.single as SourceTablePart).rows, isEmpty);
      expect((emptyRow.parts.single as SourceTablePart).rows.single, isEmpty);
      _expectIssueContracts(empty, <String>['parsed_content_empty']);
      _expectIssueContracts(emptyRow, <String>['parsed_content_empty']);
    });
  });

  group('ParsedSourceDocumentAdapter images', () {
    test('uses safe IDs, preserves positions, and applies alt precedence', () {
      final converted = adapter.convert(
        _parsed(
          parts: const <DocumentPart>[
            ImagePart(
              order: 0,
              path: 'METADATA_PATH_A',
              relationshipId: 'METADATA_REL_A',
              assetId: 'asset_001',
              resolvedPath: 'METADATA_RESOLVED_A',
              altText: '  primary alt  ',
            ),
            TextPart(
              order: 1,
              text: 'between images',
              role: TextRole.paragraph,
            ),
            ImagePart(
              order: 2,
              path: 'METADATA_PATH_B',
              assetId: 'asset_001',
            ),
            ImagePart(
              order: 3,
              path: 'METADATA_PATH_C',
              assetId: 'asset_002',
              altText: '   ',
            ),
          ],
          imageAssets: const <DocumentImageAsset>[
            DocumentImageAsset(
              id: 'asset_001',
              order: 99,
              sourceName: 'METADATA_SOURCE_A',
              originalPath: 'METADATA_ORIGINAL_A',
              extractedPath: 'METADATA_EXTRACTED_A',
              altText: '  primary alt  ',
              byteLength: 111,
              isResolvable: true,
            ),
            DocumentImageAsset(
              id: 'asset_002',
              order: -9,
              sourceName: 'METADATA_SOURCE_B',
              originalPath: 'METADATA_ORIGINAL_B',
              extractedPath: 'METADATA_EXTRACTED_B',
              altText: 'fallback alt',
              byteLength: 222,
              isResolvable: false,
            ),
          ],
        ),
        sourceId: 'image_source',
      );

      expect(converted.parts[0], isA<SourceAssetPart>());
      expect(_singlePartText(converted.parts[1]), 'between images');
      expect(converted.parts[2], isA<SourceAssetPart>());
      expect(converted.parts[3], isA<SourceAssetPart>());

      final first = converted.parts[0] as SourceAssetPart;
      final repeated = converted.parts[2] as SourceAssetPart;
      final unresolved = converted.parts[3] as SourceAssetPart;
      expect(first.asset, repeated.asset);
      expect(first.asset.assetId, 'asset_000001');
      expect(unresolved.asset.assetId, 'asset_000002');
      expect(first.asset.kind, AssetKind.image);
      expect(first.asset.mimeType, isNull);
      expect(first.asset.pixelWidth, isNull);
      expect(first.asset.pixelHeight, isNull);
      expect(_singleContentText(first.alternativeText!), '  primary alt  ');
      expect(_singleContentText(repeated.alternativeText!), '  primary alt  ');
      expect(_singleContentText(unresolved.alternativeText!), 'fallback alt');
      _expectIssueContracts(converted, <String>['parsed_asset_unresolved']);
      final strings = _publicStrings(converted).toList(growable: false);
      expect(strings.any((value) => value.contains('asset_001')), isFalse);
      expect(strings.any((value) => value.contains('asset_002')), isFalse);
    });

    test('maps producer-shaped keys by part encounter order without leakage',
        () {
      const asciiKey = 'exam.docx_img_0';
      const unicodeAndSpaceKey = '高数 试卷.docx_img_0';
      final longKey = '${List<String>.filled(160, 'x').join()}_img_0';
      final parts = <DocumentPart>[
        const ImagePart(
          order: 0,
          path: 'ASCII_PART_PATH',
          relationshipId: 'ASCII_RELATIONSHIP',
          assetId: asciiKey,
        ),
        const ImagePart(
          order: 1,
          path: 'UNICODE_PART_PATH',
          assetId: unicodeAndSpaceKey,
        ),
        ImagePart(
          order: 2,
          path: 'LONG_PART_PATH',
          assetId: longKey,
        ),
        const ImagePart(
          order: 3,
          path: 'ASCII_REPEAT_PATH',
          assetId: asciiKey,
        ),
      ];
      final metadata = <DocumentImageAsset>[
        DocumentImageAsset(
          id: longKey,
          order: 80,
          sourceName: 'LONG_METADATA_SOURCE',
          originalPath: 'LONG_METADATA_ORIGINAL',
          extractedPath: 'LONG_METADATA_EXTRACTED',
          isResolvable: true,
        ),
        const DocumentImageAsset(
          id: asciiKey,
          order: 90,
          sourceName: 'ASCII_METADATA_SOURCE',
          originalPath: 'ASCII_METADATA_ORIGINAL',
          extractedPath: 'ASCII_METADATA_EXTRACTED',
          isResolvable: true,
        ),
        const DocumentImageAsset(
          id: unicodeAndSpaceKey,
          order: 70,
          sourceName: 'UNICODE_METADATA_SOURCE',
          originalPath: 'UNICODE_METADATA_ORIGINAL',
          extractedPath: 'UNICODE_METADATA_EXTRACTED',
          isResolvable: true,
        ),
      ];
      final document = _parsed(
        sourceName: 'PRODUCER_DOCUMENT_SOURCE',
        parts: parts,
        imageAssets: metadata,
      );

      final converted = adapter.convert(
        document,
        sourceId: 'producer_shape_source',
      );
      final repeated = adapter.convert(
        document,
        sourceId: 'producer_shape_source',
      );
      final metadataReordered = adapter.convert(
        _parsed(
          sourceName: 'PRODUCER_DOCUMENT_SOURCE',
          parts: parts,
          imageAssets: metadata.reversed.toList(growable: false),
        ),
        sourceId: 'producer_shape_source',
      );
      final assets = converted.parts.cast<SourceAssetPart>();

      expect(
        assets.map((part) => part.asset.assetId),
        <String>[
          'asset_000001',
          'asset_000002',
          'asset_000003',
          'asset_000001',
        ],
      );
      expect(assets[3].asset, same(assets[0].asset));
      expect(
        assets.every((part) => part.asset.assetId.length <= 128),
        isTrue,
      );
      expect(repeated, converted);
      expect(metadataReordered, converted);
      _expectIssueContracts(converted, const <String>[]);

      final strings = _publicStrings(converted).toList(growable: false);
      for (final forbidden in <String>[
        asciiKey,
        unicodeAndSpaceKey,
        longKey,
        'PRODUCER_DOCUMENT_SOURCE',
        'ASCII_PART_PATH',
        'ASCII_REPEAT_PATH',
        'ASCII_RELATIONSHIP',
        'ASCII_METADATA_SOURCE',
        'ASCII_METADATA_ORIGINAL',
        'ASCII_METADATA_EXTRACTED',
        'UNICODE_PART_PATH',
        'UNICODE_METADATA_SOURCE',
        'UNICODE_METADATA_ORIGINAL',
        'UNICODE_METADATA_EXTRACTED',
        'LONG_PART_PATH',
        'LONG_METADATA_SOURCE',
        'LONG_METADATA_ORIGINAL',
        'LONG_METADATA_EXTRACTED',
      ]) {
        expect(strings.any((value) => value.contains(forbidden)), isFalse);
      }
    });

    test('degrades missing IDs and handles missing, orphaned, and conflicts',
        () {
      final converted = adapter.convert(
        _parsed(
          parts: const <DocumentPart>[
            ImagePart(
              order: 0,
              path: 'META_NULL_PATH',
              relationshipId: 'META_NULL_REL',
              altText: 'formal invalid alt',
            ),
            ImagePart(order: 1, path: 'META_EMPTY_PATH', assetId: ''),
            ImagePart(order: 2, path: 'META_BAD_PATH', assetId: 'bad/id'),
            ImagePart(
              order: 3,
              path: 'META_MISSING_PATH',
              assetId: 'safe_missing',
              altText: 'missing metadata alt',
            ),
            ImagePart(
              order: 4,
              path: 'META_DUP_PATH',
              assetId: 'safe_duplicate',
            ),
          ],
          imageAssets: const <DocumentImageAsset>[
            DocumentImageAsset(
              id: 'safe_duplicate',
              order: 0,
              sourceName: 'META_DUP_SOURCE_A',
              originalPath: 'META_DUP_ORIGINAL_A',
              altText: 'first metadata alt',
              isResolvable: true,
            ),
            DocumentImageAsset(
              id: 'safe_duplicate',
              order: 1,
              sourceName: 'META_DUP_SOURCE_B',
              originalPath: 'META_DUP_ORIGINAL_B',
              altText: 'second metadata alt',
              isResolvable: false,
            ),
            DocumentImageAsset(
              id: 'safe_orphan',
              order: 2,
              sourceName: 'META_ORPHAN_SOURCE',
              originalPath: 'META_ORPHAN_PATH',
              isResolvable: true,
            ),
            DocumentImageAsset(
              id: 'bad/id',
              order: 3,
              sourceName: 'META_INVALID_SOURCE',
              originalPath: 'META_INVALID_PATH',
              isResolvable: false,
            ),
          ],
        ),
        sourceId: 'image_anomalies',
      );

      expect(converted.parts, hasLength(5));
      expect(
        converted.parts.take(2).map(
              (part) => (part as UnsupportedSourcePart).kindCode,
            ),
        <String>['parsed_image', 'parsed_image'],
      );
      expect(_singlePartText(converted.parts[0]), 'formal invalid alt');
      expect(_singlePartText(converted.parts[1]), '[Image]');
      expect(
        (converted.parts[2] as SourceAssetPart).asset.assetId,
        'asset_000001',
      );
      expect(
        (converted.parts[2] as SourceAssetPart).alternativeText,
        isNull,
      );
      expect(
        (converted.parts[3] as SourceAssetPart).asset.assetId,
        'asset_000002',
      );
      expect(
        _singleContentText(
          (converted.parts[3] as SourceAssetPart).alternativeText!,
        ),
        'missing metadata alt',
      );
      expect(
        (converted.parts[4] as SourceAssetPart).asset.assetId,
        'asset_000003',
      );
      expect(
        (converted.parts[4] as SourceAssetPart).alternativeText,
        isNull,
      );
      _expectIssueContracts(
        converted,
        <String>[
          'parsed_asset_identity_invalid',
          'parsed_asset_missing',
          'parsed_asset_unresolved',
          'parsed_asset_orphaned',
          'parsed_asset_metadata_conflict',
        ],
      );
      expect(
        converted.issues
            .where((issue) => issue.code == 'parsed_asset_identity_invalid'),
        hasLength(1),
      );
      final strings = _publicStrings(converted).toList(growable: false);
      for (final forbidden in <String>[
        'META_NULL_PATH',
        'META_NULL_REL',
        'META_BAD_PATH',
        'META_MISSING_PATH',
        'META_DUP_PATH',
        'META_DUP_SOURCE_A',
        'META_DUP_ORIGINAL_A',
        'META_ORPHAN_PATH',
        'META_INVALID_SOURCE',
        'META_INVALID_PATH',
        'bad/id',
        'safe_missing',
        'safe_duplicate',
        'safe_orphan',
      ]) {
        expect(strings.any((value) => value.contains(forbidden)), isFalse);
      }
    });
  });

  group('ParsedSourceDocumentAdapter privacy boundary', () {
    test('drops metadata values while preserving identical formal strings', () {
      const formalLocator = 'https://same.invalid/formal';
      const metadataOnly = <String>[
        'dir/metadata-file.png',
        r'..\metadata\file.png',
        r'C:metadata\file.png',
        r'C:\metadata\file.png',
        r'\\metadata\share',
        '/metadata-file.png',
        'file://metadata-file.png',
        'https://metadata.invalid/file.png',
        'data:image/png;base64,METADATA_ONLY',
        '  https://metadata-leading.invalid',
        'secret-token-value',
        'METADATA_EXCEPTION',
        'METADATA_STACK_TRACE',
      ];
      final converted = adapter.convert(
        _parsed(
          sourceName: formalLocator,
          signals: const DocumentSignals(
            questionMarkerCount: 991,
            answerMarkerCount: 992,
            imageCount: 993,
          ),
          diagnostics: <String, dynamic>{
            'payload_blob': <String, dynamic>{
              'api_response': formalLocator,
              'envelope': metadataOnly,
              'api_key': 'secret-token-value',
              'path': r'C:\metadata\file.png',
              'url': 'https://metadata.invalid/file.png',
              'exception': 'METADATA_EXCEPTION',
              'stackTrace': 'METADATA_STACK_TRACE',
            },
          },
          parts: const <DocumentPart>[
            TextPart(
              order: 0,
              text: formalLocator,
              role: TextRole.paragraph,
            ),
            TablePart(
              order: 1,
              rows: <List<String>>[
                <String>[formalLocator],
              ],
            ),
            ImagePart(
              order: 2,
              path: formalLocator,
              resolvedPath: formalLocator,
              relationshipId: formalLocator,
              assetId: 'privacy_asset',
              altText: formalLocator,
            ),
          ],
          imageAssets: const <DocumentImageAsset>[
            DocumentImageAsset(
              id: 'privacy_asset',
              order: 777,
              sourceName: formalLocator,
              originalPath: formalLocator,
              extractedPath: formalLocator,
              altText: formalLocator,
              byteLength: 987654321,
              isResolvable: true,
            ),
          ],
        ),
        sourceId: 'privacy_source',
      );
      final strings = _publicStrings(converted).toList(growable: false);

      expect(strings.where((value) => value == formalLocator), hasLength(3));
      for (final forbidden in metadataOnly) {
        expect(
          strings.any((value) => value.contains(forbidden)),
          isFalse,
          reason: forbidden,
        );
      }
      final asset = converted.parts[2] as SourceAssetPart;
      expect(asset.asset.mimeType, isNull);
      expect(asset.asset.pixelWidth, isNull);
      expect(asset.asset.pixelHeight, isNull);
      expect(_allNodes(converted).whereType<RawFallbackNode>(), isEmpty);
    });
  });

  group('ParsedSourceDocumentAdapter fallback and empty content', () {
    test('uses content status instead of text to decide redaction', () {
      const cases = <({
        ParsedDocumentContentStatus status,
        String text,
        bool redacted,
      })>[
        (
          status: ParsedDocumentContentStatus.usable,
          text: 'ordinary formal content',
          redacted: false,
        ),
        (
          status: ParsedDocumentContentStatus.usable,
          text: 'Docx Parsing and Fallback Failed: formal example',
          redacted: false,
        ),
        (
          status: ParsedDocumentContentStatus.infrastructureFailure,
          text: 'Docx Parsing and Fallback Failed: synthetic failure',
          redacted: true,
        ),
        (
          status: ParsedDocumentContentStatus.infrastructureFailure,
          text: 'ordinary-looking formal content',
          redacted: true,
        ),
      ];

      for (var index = 0; index < cases.length; index++) {
        final testCase = cases[index];
        final converted = adapter.convert(
          _parsed(
            format: ImportFormat.docx,
            fallbackUsed: true,
            contentStatus: testCase.status,
            parts: <DocumentPart>[
              TextPart(
                order: 0,
                text: testCase.text,
                role: TextRole.paragraph,
              ),
            ],
          ),
          sourceId: 'status_case_$index',
        );

        if (testCase.redacted) {
          expect(converted.parts, isEmpty);
          _expectIssueContracts(
            converted,
            <String>[
              'parsed_fallback_used',
              'parsed_failure_content_redacted',
              'parsed_content_empty',
            ],
          );
        } else {
          expect(converted.parts, hasLength(1));
          expect(_singlePartText(converted.parts.single), testCase.text);
          _expectIssueContracts(
            converted,
            <String>['parsed_fallback_used'],
          );
        }
      }
    });

    test('redacts failure payloads before inspecting parts or metadata', () {
      const payload = 'SYNTHETIC_FAILURE_PAYLOAD';
      final converted = adapter.convert(
        _parsed(
          contentStatus: ParsedDocumentContentStatus.infrastructureFailure,
          fallbackUsed: true,
          diagnostics: const <String, dynamic>{'failure': payload},
          parts: const <DocumentPart>[
            TextPart(
              order: 4,
              text: payload,
              role: TextRole.paragraph,
            ),
            TablePart(
              order: -1,
              rows: <List<String>>[
                <String>[payload],
              ],
            ),
            ImagePart(
              order: 4,
              path: payload,
              assetId: 'invalid/asset',
              altText: payload,
            ),
          ],
          imageAssets: const <DocumentImageAsset>[
            DocumentImageAsset(
              id: 'invalid/asset',
              order: 0,
              sourceName: payload,
              originalPath: payload,
              extractedPath: payload,
              altText: payload,
              isResolvable: false,
            ),
          ],
        ),
        sourceId: 'failure_payload',
      );

      expect(converted.parts, isEmpty);
      _expectIssueContracts(
        converted,
        <String>[
          'parsed_fallback_used',
          'parsed_failure_content_redacted',
          'parsed_content_empty',
        ],
      );
      expect(
        _publicStrings(converted).any((value) => value.contains(payload)),
        isFalse,
      );
    });

    test('preserves DOCX fallback text that collides with failure prefix', () {
      const formalText =
          'Docx Parsing and Fallback Failed: legitimate formal content';
      final converted = adapter.convert(
        _parsed(
          format: ImportFormat.docx,
          fallbackUsed: true,
          parts: const <DocumentPart>[
            TextPart(
              order: 0,
              text: formalText,
              role: TextRole.paragraph,
            ),
          ],
        ),
        sourceId: 'docx_collision',
      );

      expect(converted.parts, hasLength(1));
      expect(_singlePartText(converted.parts.single), formalText);
      _expectIssueContracts(
        converted,
        <String>['parsed_fallback_used'],
      );
    });

    test('redacts only typed ZIP boundaries and preserves colliding text', () {
      const sentinel = '\n--- Source: private/subdocument.txt ---\n';
      final converted = adapter.convert(
        _parsed(
          format: ImportFormat.zip,
          parts: const <DocumentPart>[
            GeneratedSourceBoundaryPart(
              order: 0,
              text: sentinel,
            ),
            TextPart(
              order: 1,
              text: 'formal ZIP body',
              role: TextRole.paragraph,
            ),
          ],
        ),
        sourceId: 'zip_boundary',
      );
      final boundary = converted.parts.first as UnsupportedSourcePart;

      expect(boundary.kindCode, 'parsed_source_boundary');
      expect(_singleContentText(boundary.fallbackContent), '[Source]');
      expect(_singlePartText(converted.parts[1]), 'formal ZIP body');
      _expectIssueContracts(
        converted,
        <String>['parsed_source_boundary_redacted'],
      );
      expect(
        _publicStrings(converted)
            .any((value) => value.contains('private/subdocument.txt')),
        isFalse,
      );

      final collidingFormalText = adapter.convert(
        _parsed(
          format: ImportFormat.zip,
          parts: const <DocumentPart>[
            TextPart(
              order: 0,
              text: sentinel,
              role: TextRole.paragraph,
            ),
          ],
        ),
        sourceId: 'zip_formal_collision',
      );
      expect(_singlePartText(collidingFormalText.parts.single), sentinel);
      _expectIssueContracts(collidingFormalText, const <String>[]);

      const ordinaryGeneratedText = 'ordinary generated boundary text';
      final typedOrdinaryText = adapter.convert(
        _parsed(
          parts: const <DocumentPart>[
            GeneratedSourceBoundaryPart(
              order: 0,
              text: ordinaryGeneratedText,
            ),
            TextPart(
              order: 1,
              text: 'formal body after generated boundary',
              role: TextRole.paragraph,
            ),
          ],
        ),
        sourceId: 'typed_boundary_without_sentinel',
      );
      expect(
        _singlePartText(typedOrdinaryText.parts.first),
        '[Source]',
      );
      expect(
        _singlePartText(typedOrdinaryText.parts[1]),
        'formal body after generated boundary',
      );
      expect(
        _publicStrings(typedOrdinaryText)
            .any((value) => value.contains(ordinaryGeneratedText)),
        isFalse,
      );
      _expectIssueContracts(
        typedOrdinaryText,
        const <String>['parsed_source_boundary_redacted'],
      );

      final boundaryOnly = adapter.convert(
        _parsed(
          format: ImportFormat.zip,
          parts: const <DocumentPart>[
            GeneratedSourceBoundaryPart(
              order: 0,
              text: '\n--- Source: only/metadata.txt ---\n',
            ),
          ],
        ),
        sourceId: 'zip_boundary_only',
      );
      _expectIssueContracts(
        boundaryOnly,
        <String>[
          'parsed_source_boundary_redacted',
          'parsed_content_empty',
        ],
      );
    });

    test('marks empty documents without dropping structural input parts', () {
      final empty = adapter.convert(
        _parsed(parts: const <DocumentPart>[]),
        sourceId: 'empty_parts',
      );
      final blankText = adapter.convert(
        _parsed(
          parts: const <DocumentPart>[
            TextPart(order: 0, text: ' \n ', role: TextRole.paragraph),
          ],
        ),
        sourceId: 'blank_text',
      );
      final invalidImage = adapter.convert(
        _parsed(
          parts: const <DocumentPart>[
            ImagePart(order: 0, path: 'METADATA_PATH'),
          ],
        ),
        sourceId: 'invalid_image_only',
      );
      final emptyFallback = adapter.convert(
        _parsed(parts: const <DocumentPart>[], fallbackUsed: true),
        sourceId: 'empty_fallback',
      );

      expect(empty.parts, isEmpty);
      _expectIssueContracts(empty, <String>['parsed_content_empty']);
      expect(blankText.parts, hasLength(1));
      expect(_singlePartText(blankText.parts.single), ' \n ');
      _expectIssueContracts(blankText, <String>['parsed_content_empty']);
      expect(invalidImage.parts.single, isA<UnsupportedSourcePart>());
      _expectIssueContracts(
        invalidImage,
        <String>['parsed_asset_identity_invalid'],
      );
      _expectIssueContracts(
        emptyFallback,
        <String>['parsed_fallback_used', 'parsed_content_empty'],
      );
    });
  });

  group('ParsedSourceDocumentAdapter immutability', () {
    test('does not mutate DTOs and returns a repeatable immutable value graph',
        () {
      final row = <String>['cell'];
      final rows = <List<String>>[row];
      final parts = <DocumentPart>[
        const TextPart(
          order: 0,
          text: 'repeatable',
          role: TextRole.paragraph,
        ),
        TablePart(order: 1, rows: rows),
        const ImagePart(
          order: 2,
          path: 'METADATA_IMAGE_PATH',
          assetId: 'immutable_asset',
          altText: 'immutable alt',
        ),
      ];
      final imageAssets = <DocumentImageAsset>[
        const DocumentImageAsset(
          id: 'immutable_asset',
          order: 12,
          sourceName: 'METADATA_ASSET_SOURCE',
          originalPath: 'METADATA_ASSET_PATH',
          altText: 'immutable alt',
          isResolvable: true,
        ),
      ];
      final nestedDiagnostics = <String, dynamic>{
        'nested': <String, dynamic>{'value': 'unchanged'},
      };
      const signals = DocumentSignals(questionMarkerCount: 9);
      final document = _parsed(
        parts: parts,
        imageAssets: imageAssets,
        diagnostics: nestedDiagnostics,
        signals: signals,
        fallbackUsed: true,
      );

      final first = adapter.convert(document, sourceId: 'immutable_source');
      final second = adapter.convert(document, sourceId: 'immutable_source');

      expect(second, first);
      expect(identical(document.parts, parts), isTrue);
      expect(identical((document.parts[1] as TablePart).rows, rows), isTrue);
      expect(
          identical((document.parts[1] as TablePart).rows.single, row), isTrue);
      expect(identical(document.imageAssets, imageAssets), isTrue);
      expect(identical(document.diagnostics, nestedDiagnostics), isTrue);
      expect(identical(document.signals, signals), isTrue);
      expect(row, <String>['cell']);
      expect(nestedDiagnostics, <String, dynamic>{
        'nested': <String, dynamic>{'value': 'unchanged'},
      });

      expect(
        () => first.parts.add(first.parts.first),
        throwsUnsupportedError,
      );
      expect(
        () => first.issues.add(first.issues.first),
        throwsUnsupportedError,
      );
      final table = first.parts[1] as SourceTablePart;
      expect(() => table.rows.clear(), throwsUnsupportedError);
      expect(() => table.rows.single.clear(), throwsUnsupportedError);
      expect(
        () => table.rows.single.single.nodes.add(const TextNode('later')),
        throwsUnsupportedError,
      );
      final asset = first.parts[2] as SourceAssetPart;
      expect(
        () => asset.alternativeText!.nodes.add(const TextNode('later')),
        throwsUnsupportedError,
      );
    });
  });
}

ParsedDocument _parsed({
  required List<DocumentPart> parts,
  String sourceName = 'METADATA_SOURCE_NAME',
  ImportFormat format = ImportFormat.unknown,
  DocumentSignals signals = const DocumentSignals(),
  ParsedDocumentContentStatus contentStatus =
      ParsedDocumentContentStatus.usable,
  bool fallbackUsed = false,
  Map<String, dynamic>? diagnostics,
  List<DocumentImageAsset>? imageAssets,
}) {
  return ParsedDocument(
    sourceName: sourceName,
    format: format,
    parts: parts,
    signals: signals,
    contentStatus: contentStatus,
    fallbackUsed: fallbackUsed,
    diagnostics: diagnostics,
    imageAssets: imageAssets,
  );
}

const _issueContracts = <String,
    ({
  ImportIssueSeverity severity,
  ImportIssueField field,
})>{
  'parsed_display_label_invalid': (
    severity: ImportIssueSeverity.info,
    field: ImportIssueField.source,
  ),
  'parsed_fallback_used': (
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.source,
  ),
  'parsed_failure_content_redacted': (
    severity: ImportIssueSeverity.error,
    field: ImportIssueField.source,
  ),
  'parsed_source_boundary_redacted': (
    severity: ImportIssueSeverity.info,
    field: ImportIssueField.source,
  ),
  'parsed_order_invalid': (
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.source,
  ),
  'parsed_order_duplicate': (
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.source,
  ),
  'parsed_asset_identity_invalid': (
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.asset,
  ),
  'parsed_asset_missing': (
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.asset,
  ),
  'parsed_asset_unresolved': (
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.asset,
  ),
  'parsed_asset_orphaned': (
    severity: ImportIssueSeverity.info,
    field: ImportIssueField.asset,
  ),
  'parsed_asset_metadata_conflict': (
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.asset,
  ),
  'parsed_content_empty': (
    severity: ImportIssueSeverity.error,
    field: ImportIssueField.source,
  ),
};

void _expectIssueContracts(SourceDocument document, List<String> codes) {
  expect(
    document.issues,
    <ImportIssue>[
      for (final code in codes)
        ImportIssue(
          code: code,
          severity: _issueContracts[code]!.severity,
          field: _issueContracts[code]!.field,
          sourceRef: document.documentRef,
        ),
    ],
  );
  expect(
    document.issues.every(
      (issue) =>
          issue.sourceRef == document.documentRef &&
          issue.sourceRef!.start == null &&
          issue.sourceRef!.end == null,
    ),
    isTrue,
  );
}

String? _singlePartText(SourcePart part) {
  final content = switch (part) {
    SourceContentPart(:final content) => content,
    UnsupportedSourcePart(:final fallbackContent) => fallbackContent,
    SourceAssetPart(:final alternativeText) => alternativeText,
    SourceTablePart() => null,
  };
  return content == null ? null : _singleContentText(content);
}

String? _singleContentText(RichContent content) {
  if (content.nodes.length != 1) return null;
  final node = content.nodes.single;
  return node is TextNode ? node.text : null;
}

Iterable<ContentNode> _allNodes(SourceDocument document) sync* {
  for (final part in document.parts) {
    switch (part) {
      case SourceContentPart(:final content):
        yield* content.nodes;
      case SourceTablePart(:final rows):
        for (final row in rows) {
          for (final cell in row) {
            yield* cell.nodes;
          }
        }
      case SourceAssetPart(:final alternativeText):
        if (alternativeText != null) yield* alternativeText.nodes;
      case UnsupportedSourcePart(:final fallbackContent):
        yield* fallbackContent.nodes;
    }
  }
}

Iterable<String> _publicStrings(SourceDocument document) sync* {
  yield* _sourceRefStrings(document.documentRef);
  for (final part in document.parts) {
    yield* _sourceRefStrings(part.sourceRef);
    switch (part) {
      case SourceContentPart(:final content, :final role):
        yield role.name;
        yield* _contentStrings(content);
      case SourceTablePart(:final rows):
        for (final row in rows) {
          for (final cell in row) {
            yield* _contentStrings(cell);
          }
        }
      case SourceAssetPart(:final asset, :final alternativeText):
        yield asset.assetId;
        yield asset.kind.name;
        if (asset.mimeType != null) yield asset.mimeType!;
        if (alternativeText != null) yield* _contentStrings(alternativeText);
      case UnsupportedSourcePart(:final kindCode, :final fallbackContent):
        yield kindCode;
        yield* _contentStrings(fallbackContent);
    }
  }
  for (final issue in document.issues) {
    yield issue.code;
    yield issue.severity.name;
    if (issue.field != null) yield issue.field!.name;
    if (issue.sourceRef != null) yield* _sourceRefStrings(issue.sourceRef!);
  }
}

Iterable<String> _sourceRefStrings(SourceRef sourceRef) sync* {
  yield sourceRef.sourceId;
  if (sourceRef.displayLabel != null) yield sourceRef.displayLabel!;
  if (sourceRef.start?.blockId != null) yield sourceRef.start!.blockId!;
  if (sourceRef.end?.blockId != null &&
      sourceRef.end!.blockId != sourceRef.start?.blockId) {
    yield sourceRef.end!.blockId!;
  }
}

Iterable<String> _contentStrings(RichContent content) sync* {
  for (final node in content.nodes) {
    switch (node) {
      case TextNode(:final text):
        yield text;
      case InlineMathNode(:final latex):
        yield latex;
      case BlockMathNode(:final latex):
        yield latex;
      case ImageNode(:final sourceId, :final localAssetId):
        yield sourceId;
        yield localAssetId;
      case TableNode(:final structure):
        for (final row in structure.rows) {
          for (final cell in row.cells) {
            yield* _contentStrings(cell.content);
          }
        }
      case RawFallbackNode(:final rawJson):
        yield* _jsonStrings(rawJson);
    }
  }
}

Iterable<String> _jsonStrings(Object? value) sync* {
  if (value is String) {
    yield value;
  } else if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is String) yield entry.key as String;
      yield* _jsonStrings(entry.value);
    }
  } else if (value is Iterable) {
    for (final item in value) {
      yield* _jsonStrings(item);
    }
  }
}
