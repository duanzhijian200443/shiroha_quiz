// R2D acceptance: runtime producer/parser outputs through both adapters.
//
// Evidence classes (do not mislabel):
// - runtime system-temp file  : TXT/Markdown/DOCX/ZIP real `parse(filePath)`.
// - runtime synthetic fixture : OCR `OcrDocument.fromLayoutParsingResponse`.
// - runtime repository fixture: the no-production-call-site check over `lib/`.
//
// This is NOT real OCR, a production pipeline, or a live Provider proof.
// All input files live in per-test `Directory.systemTemp` subdirectories and
// are removed in tearDown; DOCX/ZIP producer extraction directories are
// removed through a unique-prefix before/after snapshot.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/docx_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/markdown_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/parsed_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/txt_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/zip_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/parsed_document.dart';

final _assetIdPattern = RegExp(r'^asset_\d{6}$');

void main() {
  const parsedAdapter = ParsedSourceDocumentAdapter();
  const ocrAdapter = OcrSourceDocumentAdapter();

  group('R2D acceptance: runtime producers through adapters', () {
    test(
        'TXT runtime temp file: segment order and formal locators preserved, '
        'metadata canaries hidden', () async {
      final dir = await _createTempDir('txt_private-temp-path-canary');
      addTearDown(() => _deleteDir(dir));
      final file = File(
        '${dir.path}${Platform.pathSeparator}original-file-name-canary.txt',
      );
      await file.writeAsString(
        r'formal first paragraph with https://example.invalid and '
        r'C:\lesson\example and \(x+1\)'
        '\n\n'
        'private-temp-path-canary'
        '\n\n'
        'formal last paragraph',
        flush: true,
      );

      final parsed = await TxtDocumentAdapter.parse(
        filePath: file.path,
        sourceName: 'provider-secret-canary',
      );

      expect(parsed.contentStatus, ParsedDocumentContentStatus.usable);
      expect(parsed.fallbackUsed, isFalse);
      expect(
        parsed.parts.map((part) => (part as TextPart).text),
        <String>[
          r'formal first paragraph with https://example.invalid and '
              r'C:\lesson\example and \(x+1\)',
          'private-temp-path-canary',
          'formal last paragraph',
        ],
      );

      final partsBefore = parsed.parts;
      final first = parsedAdapter.convert(parsed, sourceId: 'r2d_txt_source');
      final second = parsedAdapter.convert(parsed, sourceId: 'r2d_txt_source');

      expect(second, first);
      expect(identical(parsed.parts, partsBefore), isTrue);
      expect(parsed.contentStatus, ParsedDocumentContentStatus.usable);
      _expectDocumentContracts(first);
      expect(first.documentRef.sourceId, 'r2d_txt_source');
      expect(first.documentRef.displayLabel, isNull);
      expect(first.issues, isEmpty);

      final texts = first.parts.map(_singleText).toList();
      expect(texts, hasLength(3));
      expect(texts[0], contains('https://example.invalid'));
      expect(texts[0], contains(r'C:\lesson\example'));
      expect(texts[0], contains(r'\(x+1\)'));
      expect(texts[1], 'private-temp-path-canary');

      final strings = _publicStrings(first).toList(growable: false);
      expect(
        strings.where((value) => value == 'private-temp-path-canary'),
        hasLength(1),
      );
      for (final forbidden in <String>[
        file.path,
        dir.path,
        'original-file-name-canary.txt',
        'provider-secret-canary',
      ]) {
        expect(
          strings.any((value) => value.contains(forbidden)),
          isFalse,
          reason: forbidden,
        );
      }
    });

    test(
        'Markdown runtime temp file: heading, GFM table and image alt kept, '
        'paths and producer keys hidden', () async {
      final dir = await _createTempDir('md_private-temp-path-canary');
      addTearDown(() => _deleteDir(dir));
      final imageFile = File(
        '${dir.path}${Platform.pathSeparator}resolved-path-canary.png',
      );
      await imageFile.writeAsBytes(<int>[137, 80, 78, 71, 1, 2, 3, 4]);
      final mdFile = File(
        '${dir.path}${Platform.pathSeparator}中文 空格.md',
      );
      await mdFile.writeAsString(
        '# 标题\n'
        '\n'
        '正文 paragraph\n'
        '\n'
        '| A | B |\n'
        '|---|---|\n'
        '| 1 | 2 |\n'
        '\n'
        '![alt-canary](resolved-path-canary.png)',
        flush: true,
      );

      final parsed = await MarkdownDocumentAdapter.parse(
        filePath: mdFile.path,
        sourceName: 'provider-secret-canary',
      );

      expect(parsed.contentStatus, ParsedDocumentContentStatus.usable);
      expect(parsed.parts, hasLength(4));
      final heading = parsed.parts[0] as TextPart;
      final body = parsed.parts[1] as TextPart;
      final table = parsed.parts[2] as TablePart;
      final image = parsed.parts[3] as ImagePart;
      expect(heading.role, TextRole.heading);
      expect(heading.text, '标题');
      expect(body.role, TextRole.paragraph);
      expect(body.text, '正文 paragraph');
      expect(table.rows, <List<String>>[
        <String>['A', 'B'],
        <String>['1', '2'],
      ]);
      expect(image.altText, 'alt-canary');
      expect(image.assetId, 'provider-secret-canary_img_0');
      expect(image.resolvedPath, isNotNull);

      final first = parsedAdapter.convert(parsed, sourceId: 'r2d_md_source');
      final second = parsedAdapter.convert(parsed, sourceId: 'r2d_md_source');
      expect(second, first);
      _expectDocumentContracts(first);
      expect(first.issues, isEmpty);

      expect(
        first.parts.take(2).map((part) => (part as SourceContentPart).role),
        <SourceContentRole>[
          SourceContentRole.heading,
          SourceContentRole.paragraph,
        ],
      );
      final convertedTable = first.parts[2] as SourceTablePart;
      expect(
        convertedTable.rows.map(
          (row) => row.map((cell) => cell.nodes.single as TextNode).map(
                (node) => node.text,
              ),
        ),
        <Iterable<String>>[
          <String>['A', 'B'],
          <String>['1', '2'],
        ],
      );
      final asset = first.parts[3] as SourceAssetPart;
      _expectOpaqueAsset(asset);
      expect(_singleText(asset), 'alt-canary');

      final strings = _publicStrings(first).toList(growable: false);
      for (final expected in <String>[
        '标题',
        '正文 paragraph',
        'A',
        'B',
        '1',
        '2',
        'alt-canary',
        'asset_000001',
      ]) {
        expect(strings.any((value) => value.contains(expected)), isTrue,
            reason: expected);
      }
      for (final forbidden in <String>[
        dir.path,
        mdFile.path,
        imageFile.path,
        '中文 空格.md',
        'resolved-path-canary.png',
        'provider-secret-canary',
        'img_0',
      ]) {
        expect(
          strings.any((value) => value.contains(forbidden)),
          isFalse,
          reason: forbidden,
        );
      }
    });

    test(
        'DOCX runtime success: paragraph, 2x2 table and media become a safe '
        'SourceDocument without temp leaks', () async {
      final dir = await _createTempDir('docx_private-temp-path-canary');
      addTearDown(() => _deleteDir(dir));
      final docxFile = File(
        '${dir.path}${Platform.pathSeparator}synthetic.docx',
      );
      await docxFile.writeAsBytes(_buildMinimalDocxBytes());

      final producerSourceName = _uniqueProducerSourceName('docx_success', dir);
      final result = await _withProducerTempCleanup(
        exactPrefix: 'shiroha_docx_${producerSourceName}_',
        action: () async {
          late ParsedDocument parsed;
          await _silenceDebugPrint(() async {
            parsed = await DocxDocumentAdapter.parse(
              filePath: docxFile.path,
              sourceName: producerSourceName,
            );
          });
          final partsBefore = parsed.parts;
          final first = parsedAdapter.convert(
            parsed,
            sourceId: 'r2d_docx_success',
          );
          final second = parsedAdapter.convert(
            parsed,
            sourceId: 'r2d_docx_success',
          );
          return (
            parsed: parsed,
            partsBefore: partsBefore,
            first: first,
            second: second,
          );
        },
      );
      final parsed = result.parsed;
      final first = result.first;
      final second = result.second;

      expect(second, first);
      expect(identical(parsed.parts, result.partsBefore), isTrue);

      expect(parsed.contentStatus, ParsedDocumentContentStatus.usable);
      expect(parsed.fallbackUsed, isFalse);
      expect(parsed.parts, hasLength(4));
      expect(
        parsed.parts.map((part) => part.runtimeType),
        <Type>[
          TextPart,
          TablePart,
          TextPart,
          ImagePart,
        ],
      );
      expect((parsed.parts[0] as TextPart).text, 'formal docx paragraph');
      expect(
        (parsed.parts[1] as TablePart).rows,
        <List<String>>[
          <String>['r1c1', 'r1c2'],
          <String>['r2c1', 'r2c2'],
        ],
      );
      expect((parsed.parts[2] as TextPart).text, 'after table');
      expect(
        (parsed.parts[3] as ImagePart).assetId,
        '${producerSourceName}_img_0',
      );

      _expectDocumentContracts(first);
      expect(first.issues, isEmpty);
      expect(first.parts, hasLength(4));
      expect(first.parts[0], isA<SourceContentPart>());
      expect(first.parts[1], isA<SourceTablePart>());
      expect(first.parts[2], isA<SourceContentPart>());
      expect(first.parts[3], isA<SourceAssetPart>());
      expect(_singleText(first.parts[2]), 'after table');
      _expectOpaqueAsset(first.parts[3] as SourceAssetPart);
      expect(
        (first.parts[3] as SourceAssetPart).asset.assetId,
        'asset_000001',
      );

      final strings = _publicStrings(first).toList(growable: false);
      for (final expected in <String>[
        'formal docx paragraph',
        'r1c1',
        'r1c2',
        'r2c1',
        'r2c2',
        'after table',
        'asset_000001',
      ]) {
        expect(strings.any((value) => value.contains(expected)), isTrue,
            reason: expected);
      }
      for (final forbidden in <String>[
        dir.path,
        docxFile.path,
        'shiroha_docx_',
        producerSourceName,
        'img_0',
        'image1.png',
        'word/media',
      ]) {
        expect(
          strings.any((value) => value.contains(forbidden)),
          isFalse,
          reason: forbidden,
        );
      }
    });

    test(
        'DOCX runtime failure: corrupted non-zip docx yields typed '
        'infrastructureFailure with no canary or path leakage', () async {
      final dir = await _createTempDir('docx_fail_private-temp-path-canary');
      addTearDown(() => _deleteDir(dir));
      final corrupt = File(
        '${dir.path}${Platform.pathSeparator}corrupt.docx',
      );
      await corrupt.writeAsBytes(
        utf8.encode(
          'definitely not a zip: diagnostics-canary '
          'private-temp-path-canary',
        ),
      );

      final producerSourceName = _uniqueProducerSourceName('docx_failure', dir);
      final parsed = await _withProducerTempCleanup(
        exactPrefix: 'shiroha_docx_${producerSourceName}_',
        action: () => _silenceDebugPrint(
          () => DocxDocumentAdapter.parse(
            filePath: corrupt.path,
            sourceName: producerSourceName,
          ),
        ),
      );

      expect(
        parsed.contentStatus,
        ParsedDocumentContentStatus.infrastructureFailure,
      );
      expect(parsed.fallbackUsed, isTrue);

      final first = parsedAdapter.convert(
        parsed,
        sourceId: 'r2d_docx_failure',
      );
      final second = parsedAdapter.convert(
        parsed,
        sourceId: 'r2d_docx_failure',
      );
      expect(second, first);
      _expectDocumentContracts(first);
      expect(first.parts, isEmpty);
      expect(
        first.issues.map((issue) => issue.code).toList(),
        <String>[
          'parsed_fallback_used',
          'parsed_failure_content_redacted',
          'parsed_content_empty',
        ],
      );

      final strings = _publicStrings(first).toList(growable: false);
      for (final forbidden in <String>[
        dir.path,
        corrupt.path,
        'corrupt.docx',
        producerSourceName,
        'diagnostics-canary',
        'private-temp-path-canary',
        'shiroha_docx_',
      ]) {
        expect(
          strings.any((value) => value.contains(forbidden)),
          isFalse,
          reason: forbidden,
        );
      }
    });

    test(
        'ZIP runtime: generated boundaries redact internal names and '
        'sentinel-like user text survives verbatim', () async {
      final dir = await _createTempDir('zip_private-temp-path-canary');
      addTearDown(() => _deleteDir(dir));
      final zipFile = File(
        '${dir.path}${Platform.pathSeparator}synthetic.zip',
      );
      await zipFile.writeAsBytes(
        _buildZipBytes(<String, String>{
          'sub/original-file-name-canary-a.txt':
              'first formal body\n\n--- Source: user-sentinel-canary ---\n',
          'sub/original-file-name-canary-b.md':
              '# Second heading\n\nsecond body',
        }),
      );

      final producerSourceName = _uniqueProducerSourceName('zip', dir);
      final result = await _withProducerTempCleanup(
        exactPrefix: 'shiroha_zip_${producerSourceName}_',
        action: () async {
          final parsed = await ZipDocumentAdapter.parse(
            filePath: zipFile.path,
            sourceName: producerSourceName,
          );
          final partsBefore = parsed.parts;
          final first =
              parsedAdapter.convert(parsed, sourceId: 'r2d_zip_source');
          final second =
              parsedAdapter.convert(parsed, sourceId: 'r2d_zip_source');
          return (
            parsed: parsed,
            partsBefore: partsBefore,
            first: first,
            second: second,
          );
        },
      );
      final parsed = result.parsed;
      final first = result.first;
      final second = result.second;

      expect(parsed.contentStatus, ParsedDocumentContentStatus.usable);
      expect(parsed.fallbackUsed, isFalse);
      expect(parsed.parts, hasLength(6));
      expect(
        parsed.parts.map((part) => part.runtimeType),
        <Type>[
          GeneratedSourceBoundaryPart,
          TextPart,
          TextPart,
          GeneratedSourceBoundaryPart,
          TextPart,
          TextPart,
        ],
      );
      expect(
        parsed.parts.map(
          (part) => part is GeneratedSourceBoundaryPart
              ? 'BOUNDARY'
              : (part as TextPart).text,
        ),
        <String>[
          'BOUNDARY',
          'first formal body',
          '--- Source: user-sentinel-canary ---',
          'BOUNDARY',
          'Second heading',
          'second body',
        ],
      );

      expect(second, first);
      expect(identical(parsed.parts, result.partsBefore), isTrue);
      _expectDocumentContracts(first);
      expect(
        first.issues.map((issue) => issue.code).toList(),
        <String>['parsed_source_boundary_redacted'],
      );
      expect(first.parts, hasLength(6));
      expect(
        first.parts.map(
          (part) =>
              part is UnsupportedSourcePart ? part.kindCode : _singleText(part),
        ),
        <String?>[
          'parsed_source_boundary',
          'first formal body',
          '--- Source: user-sentinel-canary ---',
          'parsed_source_boundary',
          'Second heading',
          'second body',
        ],
      );
      expect(
        (first.parts[1] as SourceContentPart).role,
        SourceContentRole.paragraph,
      );
      expect(
        (first.parts[4] as SourceContentPart).role,
        SourceContentRole.heading,
      );
      for (final boundary in first.parts.whereType<UnsupportedSourcePart>()) {
        expect(_singleText(boundary), '[Source]');
      }

      final strings = _publicStrings(first).toList(growable: false);
      for (final expected in <String>[
        '[Source]',
        'first formal body',
        '--- Source: user-sentinel-canary ---',
        'Second heading',
        'second body',
      ]) {
        expect(strings.any((value) => value.contains(expected)), isTrue,
            reason: expected);
      }
      for (final forbidden in <String>[
        dir.path,
        zipFile.path,
        'original-file-name-canary',
        'sub/',
        producerSourceName,
        'shiroha_zip_',
      ]) {
        expect(
          strings.any((value) => value.contains(forbidden)),
          isFalse,
          reason: forbidden,
        );
      }
    });

    test('producer temp cleanup preserves another newly-created app directory',
        () async {
      final dir = await _createTempDir('cleanup_scope');
      addTearDown(() => _deleteDir(dir));
      final unique = _uniqueProducerSourceName('cleanup', dir);
      final ownedPrefix = 'shiroha_docx_${unique}_';
      final before = _snapshotProducerTempDirs();
      final owned = await Directory.systemTemp.createTemp(ownedPrefix);
      final unrelated = await Directory.systemTemp.createTemp(
        'shiroha_docx_unrelated_${unique}_',
      );
      addTearDown(() => _deleteDir(owned));
      addTearDown(() => _deleteDir(unrelated));

      await _cleanupNewProducerTempDirs(
        before,
        exactPrefix: ownedPrefix,
      );

      expect(await owned.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
    });

    test(
        'OCR runtime synthetic layout response: stable page/order mapping, '
        'role coverage and no side channels', () {
      final response = <String, dynamic>{
        'md_results': 'raw-response-canary markdown fallback',
        'layout_details': <List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[
            <String, dynamic>{
              'index': 1,
              'label': 'heading',
              'content': 'Page One Heading',
              'bbox_2d': <double>[111.5, 222.5, 333.5, 444.5],
              'confidence': 0.98765,
            },
          ],
          <Map<String, dynamic>>[
            <String, dynamic>{
              'index': 1,
              'label': 'text',
              'content': 'Page Two Text',
              'bbox_2d': <double>[111.5, 222.5, 333.5, 444.5],
              'confidence': 0.98765,
            },
            <String, dynamic>{
              'index': 2,
              'label': 'formula',
              'content': 'x^2 + y^2',
              'bbox_2d': <double>[111.5, 222.5, 333.5, 444.5],
              'confidence': 0.98765,
            },
            <String, dynamic>{
              'index': 3,
              'label': 'table',
              'content': 'row|cell',
              'bbox_2d': <double>[111.5, 222.5, 333.5, 444.5],
              'confidence': 0.98765,
            },
            <String, dynamic>{
              'index': 4,
              'label': 'image',
              'content': 'figure caption',
              'bbox_2d': <double>[111.5, 222.5, 333.5, 444.5],
              'confidence': 0.98765,
            },
            <String, dynamic>{
              'index': 5,
              'label': 'unknown',
              'content': 'widget payload',
              'bbox_2d': <double>[111.5, 222.5, 333.5, 444.5],
              'confidence': 0.98765,
            },
          ],
        ],
        'data_info': <String, dynamic>{
          'pages': <Map<String, dynamic>>[
            <String, dynamic>{'width': 123456789, 'height': 987654321},
            <String, dynamic>{'width': 123456789, 'height': 987654321},
          ],
        },
        'usage': <String, dynamic>{
          'provider-secret-canary': 'raw-response-canary',
        },
      };
      final document = OcrDocument.fromLayoutParsingResponse(
        response,
        sourceName: 'provider-secret-canary',
      );

      expect(document.pages, hasLength(2));
      expect(document.pages[0].blocks, hasLength(1));
      expect(document.pages[1].blocks, hasLength(5));
      final pagesBefore = document.pages;

      final first = ocrAdapter.convert(document, sourceId: 'r2d_ocr_source');
      final second = ocrAdapter.convert(document, sourceId: 'r2d_ocr_source');
      expect(second, first);
      expect(identical(document.pages, pagesBefore), isTrue);
      _expectDocumentContracts(first);
      expect(first.parts, hasLength(6));

      expect(
        first.parts.map(
          (part) => part is SourceContentPart
              ? part.role
              : (part as UnsupportedSourcePart).kindCode,
        ),
        <Object>[
          SourceContentRole.heading,
          SourceContentRole.paragraph,
          SourceContentRole.formula,
          'ocr_table',
          'ocr_image',
          'ocr_unknown',
        ],
      );
      expect(
        first.parts.map(_singleText),
        <String?>[
          'Page One Heading',
          'Page Two Text',
          'x^2 + y^2',
          'row|cell',
          'figure caption',
          'widget payload',
        ],
      );
      expect(
        first.parts.map((part) => part.sourceRef.start!.pageNumber),
        <int>[1, 2, 2, 2, 2, 2],
      );
      expect(
        first.parts.map((part) => part.sourceRef.start!.blockId),
        <String?>[
          'p001_b0001',
          'p002_b0001',
          'p002_b0002',
          'p002_b0003',
          'p002_b0004',
          'p002_b0005',
        ],
      );
      expect(
        first.parts.map((part) => part.sourceRef.start!.readingOrder),
        <int?>[0, 0, 1, 2, 3, 4],
      );
      expect(
        first.issues
            .where((issue) => issue.code == 'ocr_structure_unsupported'),
        hasLength(3),
      );

      final strings = _publicStrings(first).toList(growable: false);
      for (final expected in <String>[
        'Page One Heading',
        'Page Two Text',
        'x^2 + y^2',
        'row|cell',
        'figure caption',
        'widget payload',
        'p001_b0001',
        'p002_b0005',
      ]) {
        expect(strings.any((value) => value.contains(expected)), isTrue,
            reason: expected);
      }
      for (final forbidden in <String>[
        'provider-secret-canary',
        'raw-response-canary',
        '123456789',
        '987654321',
        '111.5',
        '0.98765',
      ]) {
        expect(
          strings.any((value) => value.contains(forbidden)),
          isFalse,
          reason: forbidden,
        );
      }
    });

    test(
        'privacy contrast: identical canary in metadata vanishes while the '
        'formal copy survives exactly once', () async {
      final dir = await _createTempDir('private-temp-path-canary');
      addTearDown(() => _deleteDir(dir));
      final file = File(
        '${dir.path}${Platform.pathSeparator}plain.txt',
      );
      await file.writeAsString(
        'formal line private-temp-path-canary',
        flush: true,
      );

      final parsed = await TxtDocumentAdapter.parse(
        filePath: file.path,
        sourceName: 'private-temp-path-canary',
      );
      final converted = parsedAdapter.convert(
        parsed,
        sourceId: 'r2d_contrast_source',
      );
      final strings = _publicStrings(converted).toList(growable: false);

      expect(
        strings.where((value) => value.contains('private-temp-path-canary')),
        hasLength(1),
      );
      expect(
        strings.any((value) => value.contains(dir.path)),
        isFalse,
      );
    });

    test(
      'only the frozen typed-candidate seam may reference the OCR adapter',
      () {
        const skip = <String>{
          'lib/services/import_pipeline/adapters/'
              'parsed_source_document_adapter.dart',
          'lib/services/import_pipeline/adapters/'
              'ocr_source_document_adapter.dart',
        };
        // R7B frozen typed-candidate seam: the only authorized production
        // caller of OcrSourceDocumentAdapter.
        const authorizedOcrCaller =
            'lib/services/import_pipeline/ocr_typed_candidate.dart';
        final offenders = <String>[];
        for (final entity in Directory('lib').listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final normalized = entity.path.replaceAll('\\', '/');
          if (skip.contains(normalized)) continue;
          final content = entity.readAsStringSync();
          if (content.contains('ParsedSourceDocumentAdapter')) {
            offenders.add('$normalized references ParsedSourceDocumentAdapter');
          }
          if (content.contains('OcrSourceDocumentAdapter') &&
              normalized != authorizedOcrCaller) {
            offenders.add('$normalized references OcrSourceDocumentAdapter');
          }
        }
        expect(
          offenders,
          isEmpty,
          reason:
              'ParsedSourceDocumentAdapter must have no production callers; '
              'OcrSourceDocumentAdapter is allowed only in the frozen '
              'typed-candidate seam '
              '(lib/services/import_pipeline/ocr_typed_candidate.dart)',
        );
      },
    );
  });
}

/// Recursively collects every public string reachable from [document],
/// including source refs, block ids, roles, text/math nodes, table cells,
/// asset fields, unsupported fallbacks, and issue metadata.
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
        if (alternativeText != null) {
          yield* _contentStrings(alternativeText);
        }
      case UnsupportedSourcePart(:final kindCode, :final fallbackContent):
        yield kindCode;
        yield* _contentStrings(fallbackContent);
    }
  }
  for (final issue in document.issues) {
    yield issue.code;
    yield issue.severity.name;
    if (issue.field != null) yield issue.field!.name;
    if (issue.sourceRef != null) {
      yield* _sourceRefStrings(issue.sourceRef!);
    }
  }
}

Iterable<String> _sourceRefStrings(SourceRef sourceRef) sync* {
  yield sourceRef.sourceId;
  if (sourceRef.displayLabel != null) yield sourceRef.displayLabel!;
  final start = sourceRef.start;
  final end = sourceRef.end;
  if (start != null) {
    yield start.pageNumber.toString();
    if (start.blockId != null) yield start.blockId!;
    if (start.readingOrder != null) yield start.readingOrder!.toString();
  }
  if (end != null && end != start) {
    yield end.pageNumber.toString();
    if (end.blockId != null) yield end.blockId!;
    if (end.readingOrder != null) yield end.readingOrder!.toString();
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

/// Asserts the caller-owned identity is authoritative and every member
/// SourceRef is consistent with the document identity.
void _expectDocumentContracts(SourceDocument document) {
  final documentRef = document.documentRef;
  for (final part in document.parts) {
    expect(part.sourceRef.sourceId, documentRef.sourceId);
    expect(part.sourceRef.displayLabel, documentRef.displayLabel);
  }
  for (final issue in document.issues) {
    final sourceRef = issue.sourceRef;
    if (sourceRef != null) {
      expect(sourceRef.sourceId, documentRef.sourceId);
      expect(sourceRef.displayLabel, documentRef.displayLabel);
    }
  }
  expect(
    () => document.parts.add(_dummyPart()),
    throwsUnsupportedError,
  );
  expect(
    () => document.issues.add(
      ImportIssue(
        code: 'dummy_issue',
        severity: ImportIssueSeverity.info,
      ),
    ),
    throwsUnsupportedError,
  );
  for (final part in document.parts) {
    switch (part) {
      case SourceContentPart(:final content):
        expect(
          () => content.nodes.add(const TextNode('later')),
          throwsUnsupportedError,
        );
      case SourceTablePart(:final rows):
        expect(() => rows.clear(), throwsUnsupportedError);
        for (final row in rows) {
          expect(() => row.clear(), throwsUnsupportedError);
          for (final cell in row) {
            expect(
              () => cell.nodes.add(const TextNode('later')),
              throwsUnsupportedError,
            );
          }
        }
      case SourceAssetPart(:final alternativeText):
        if (alternativeText != null) {
          expect(
            () => alternativeText.nodes.add(const TextNode('later')),
            throwsUnsupportedError,
          );
        }
      case UnsupportedSourcePart(:final fallbackContent):
        expect(
          () => fallbackContent.nodes.add(const TextNode('later')),
          throwsUnsupportedError,
        );
    }
  }
}

void _expectOpaqueAsset(SourceAssetPart part) {
  expect(part.asset.kind, AssetKind.image);
  expect(part.asset.mimeType, isNull);
  expect(part.asset.pixelWidth, isNull);
  expect(part.asset.pixelHeight, isNull);
  expect(
    _assetIdPattern.hasMatch(part.asset.assetId),
    isTrue,
    reason: 'asset ids must be generated opaque tokens, not producer keys',
  );
}

String? _singleText(SourcePart part) {
  final content = switch (part) {
    SourceContentPart(:final content) => content,
    UnsupportedSourcePart(:final fallbackContent) => fallbackContent,
    SourceAssetPart(:final alternativeText) => alternativeText,
    SourceTablePart() => null,
  };
  if (content == null || content.nodes.length != 1) return null;
  final node = content.nodes.single;
  return node is TextNode ? node.text : null;
}

SourcePart _dummyPart() {
  return UnsupportedSourcePart(
    sourceRef: SourceRef.document(sourceId: 'dummy'),
    kindCode: 'dummy',
    fallbackContent: RichContent(nodes: <ContentNode>[const TextNode('dummy')]),
  );
}

Future<Directory> _createTempDir(String label) {
  return Directory.systemTemp.createTemp('r2d_${label}_');
}

Future<void> _deleteDir(Directory dir) async {
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}

Set<String> _snapshotProducerTempDirs() {
  return Directory.systemTemp
      .listSync()
      .whereType<Directory>()
      .map((dir) => dir.path)
      .toSet();
}

String _uniqueProducerSourceName(String label, Directory dir) {
  final basename = dir.path.split(Platform.pathSeparator).last;
  final safeBasename = basename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return '${label}_$safeBasename';
}

Future<T> _withProducerTempCleanup<T>({
  required String exactPrefix,
  required Future<T> Function() action,
}) async {
  final before = _snapshotProducerTempDirs();
  try {
    return await action();
  } finally {
    await _cleanupNewProducerTempDirs(before, exactPrefix: exactPrefix);
  }
}

Future<void> _cleanupNewProducerTempDirs(
  Set<String> before, {
  required String exactPrefix,
}) async {
  if (!RegExp(r'^shiroha_(?:docx|zip)_[A-Za-z0-9._-]+_$')
      .hasMatch(exactPrefix)) {
    throw ArgumentError.value(exactPrefix, 'exactPrefix');
  }
  final tempRoot = Directory.systemTemp.absolute.path;
  for (final dir in Directory.systemTemp
      .listSync(followLinks: false)
      .whereType<Directory>()) {
    if (before.contains(dir.path)) continue;
    if (dir.parent.absolute.path != tempRoot) continue;
    final basename = dir.path.split(Platform.pathSeparator).last;
    if (!basename.startsWith(exactPrefix)) continue;
    await dir.delete(recursive: true);
  }
}

Future<T> _silenceDebugPrint<T>(Future<T> Function() body) async {
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {};
  try {
    return await body();
  } finally {
    debugPrint = original;
  }
}

List<int> _buildMinimalDocxBytes() {
  const documentXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
<w:p><w:r><w:t>formal docx paragraph</w:t></w:r></w:p>
<w:tbl>
<w:tr><w:tc><w:p><w:r><w:t>r1c1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>r1c2</w:t></w:r></w:p></w:tc></w:tr>
<w:tr><w:tc><w:p><w:r><w:t>r2c1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>r2c2</w:t></w:r></w:p></w:tc></w:tr>
</w:tbl>
<w:p><w:r><w:t>after table</w:t></w:r></w:p>
</w:body></w:document>''';
  final archive = Archive();
  final documentBytes = utf8.encode(documentXml);
  archive.addFile(
    ArchiveFile('word/document.xml', documentBytes.length, documentBytes),
  );
  const imageBytes = <int>[137, 80, 78, 71, 1, 2, 3, 4];
  archive.addFile(
    ArchiveFile('word/media/image1.png', imageBytes.length, imageBytes),
  );
  return ZipEncoder().encode(archive)!;
}

List<int> _buildZipBytes(Map<String, String> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive)!;
}
