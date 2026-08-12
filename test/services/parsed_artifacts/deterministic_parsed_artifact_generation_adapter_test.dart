import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/deterministic_parsed_artifact_generation_adapter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

const _sha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

LibraryFile libraryFile({
  String fileId = 'file-1',
  String displayName = 'notes.txt',
  String storageKey = 'library/file-1',
}) {
  return LibraryFile(
    fileId: fileId,
    displayName: displayName,
    mimeType: 'application/octet-stream',
    sizeBytes: 3,
    sha256: _sha256,
    storageKey: storageKey,
    createdAt: DateTime.utc(2026, 8, 13),
  );
}

void main() {
  late Directory tempDir;
  late ManagedFileStorageAdapter managedStorage;
  late DeterministicParsedArtifactGenerationAdapter adapter;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('i1_generation_');
    managedStorage = ManagedFileStorageAdapter(managedRoot: tempDir);
    adapter = DeterministicParsedArtifactGenerationAdapter(
      managedFileStorage: managedStorage,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> seedManagedFile({
    required List<int> bytes,
    String storageKey = 'library/file-1',
  }) async {
    final fixture = File(
        p.join(tempDir.path, 'fixture_${storageKey.replaceAll('/', '_')}'));
    await fixture.writeAsBytes(bytes);
    await managedStorage.copyIntoManagedStorage(
      externalPath: fixture.path,
      storageKey: storageKey,
    );
    await fixture.delete();
  }

  Future<ParsedArtifactGenerationPlan> resolvePlan(
    LibraryFile file,
    ParsedArtifactRouteSelection selection,
  ) {
    return adapter.resolvePlan(
      file: file,
      options: ParsedArtifactParseOptions(routeSelection: selection),
    );
  }

  group('route resolution', () {
    test('auto resolves each deterministic format', () async {
      final cases = <String, String>{
        'a.pdf': 'pdf_text',
        'a.docx': 'docx_text',
        'a.txt': 'txt',
        'a.md': 'markdown',
        'a.markdown': 'markdown',
      };
      for (final entry in cases.entries) {
        final plan = await resolvePlan(
          libraryFile(displayName: entry.key),
          ParsedArtifactRouteSelection.auto,
        );
        expect(plan.parserRoute, entry.value, reason: entry.key);
        expect(plan.parserRoute, isNot('auto'));
        expect(plan.parserVersion, isNotEmpty);
        expect(plan.optionsSchemaVersion, 1);
      }
    });

    test('auto rejects image, zip, and unknown formats', () async {
      for (final name in <String>[
        'a.png',
        'a.jpg',
        'a.jpeg',
        'a.zip',
        'a.unknown',
        'noextension',
      ]) {
        await expectLater(
          resolvePlan(
            libraryFile(displayName: name),
            ParsedArtifactRouteSelection.auto,
          ),
          throwsA(
            isA<ParsedArtifactGenerationException>().having(
              (error) => error.failure,
              'failure',
              ParsedArtifactGenerationFailure.unsupportedRoute,
            ),
          ),
          reason: name,
        );
      }
    });

    test('explicit deterministic routes resolve and conflict-check', () async {
      final cases = <String, ParsedArtifactRouteSelection>{
        'a.pdf': ParsedArtifactRouteSelection.pdfText,
        'a.docx': ParsedArtifactRouteSelection.docxText,
        'a.txt': ParsedArtifactRouteSelection.txt,
        'a.md': ParsedArtifactRouteSelection.markdown,
      };
      for (final entry in cases.entries) {
        final plan = await resolvePlan(
          libraryFile(displayName: entry.key),
          entry.value,
        );
        expect(plan.parserRoute, _expectedRoute(entry.value),
            reason: entry.key);
      }
      // Unknown extension carries no conflict signal for an explicit route.
      final unknown = await resolvePlan(
        libraryFile(displayName: 'noextension'),
        ParsedArtifactRouteSelection.txt,
      );
      expect(unknown.parserRoute, 'txt');
    });

    test('explicit route conflicting with detected format is unsupported',
        () async {
      for (final (name, selection) in <(String, ParsedArtifactRouteSelection)>[
        ('a.png', ParsedArtifactRouteSelection.pdfText),
        ('a.docx', ParsedArtifactRouteSelection.txt),
        ('a.pdf', ParsedArtifactRouteSelection.markdown),
        ('a.zip', ParsedArtifactRouteSelection.docxText),
      ]) {
        await expectLater(
          resolvePlan(
            libraryFile(displayName: name),
            selection,
          ),
          throwsA(
            isA<ParsedArtifactGenerationException>().having(
              (error) => error.failure,
              'failure',
              ParsedArtifactGenerationFailure.unsupportedRoute,
            ),
          ),
          reason: name,
        );
      }
    });

    test('OCR selections are always unsupported in I1', () async {
      for (final selection in <ParsedArtifactRouteSelection>[
        ParsedArtifactRouteSelection.ocrPdf,
        ParsedArtifactRouteSelection.ocrImage,
      ]) {
        await expectLater(
          resolvePlan(
            libraryFile(displayName: 'a.pdf'),
            selection,
          ),
          throwsA(
            isA<ParsedArtifactGenerationException>().having(
              (error) => error.failure,
              'failure',
              ParsedArtifactGenerationFailure.unsupportedRoute,
            ),
          ),
        );
      }
    });

    test('generate defensively rejects OCR routes', () async {
      await expectLater(
        adapter.generate(
          file: libraryFile(),
          artifactId: 'artifact-1',
          plan: ParsedArtifactGenerationPlan(
            parserRoute: 'ocr_pdf',
            parserVersion: 'x',
            optionsSchemaVersion: 1,
          ),
        ),
        throwsA(
          isA<ParsedArtifactGenerationException>().having(
            (error) => error.failure,
            'failure',
            ParsedArtifactGenerationFailure.unsupportedRoute,
          ),
        ),
      );
    });
  });

  group('real deterministic generation', () {
    test('TXT round-trips through TxtDocumentAdapter', () async {
      await seedManagedFile(
        bytes: utf8.encode('first paragraph\n\nsecond paragraph'),
      );
      final file = libraryFile();

      final plan = await resolvePlan(file, ParsedArtifactRouteSelection.auto);
      expect(plan.parserRoute, 'txt');
      final document = await adapter.generate(
        file: file,
        artifactId: 'artifact-txt',
        plan: plan,
      );

      expect(document.documentRef.sourceId, 'artifact-txt');
      expect(document.documentRef.displayLabel, 'notes.txt');
      final texts = document.parts
          .map(
            (part) => part is SourceContentPart &&
                    part.content.nodes.single is TextNode
                ? (part.content.nodes.single as TextNode).text
                : null,
          )
          .toList();
      expect(texts, <String?>['first paragraph', 'second paragraph']);
    });

    test('Markdown keeps safe content and hides image paths', () async {
      await seedManagedFile(
        bytes: utf8.encode(
          '# Title\n\nbody\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n'
          '![alt-canary](resolved-path-canary.png)',
        ),
      );
      await seedManagedFile(
        bytes: <int>[137, 80, 78, 71, 1, 2, 3, 4],
        storageKey: 'library/resolved-path-canary.png',
      );
      final file = libraryFile(displayName: 'doc.md');

      final plan =
          await resolvePlan(file, ParsedArtifactRouteSelection.markdown);
      final document = await adapter.generate(
        file: file,
        artifactId: 'artifact-md',
        plan: plan,
      );

      expect(document.documentRef.sourceId, 'artifact-md');
      expect(document.parts, hasLength(4));
      expect(document.parts[2], isA<SourceTablePart>());
      final asset = document.parts[3] as SourceAssetPart;
      expect(asset.asset.assetId, 'asset_000001');
      expect(
        (asset.alternativeText?.nodes.single as TextNode).text,
        'alt-canary',
      );
      final strings = _publicStrings(document);
      for (final forbidden in <String>[
        'resolved-path-canary',
        tempDir.path,
        'http',
      ]) {
        expect(
          strings.any((value) => value.contains(forbidden)),
          isFalse,
          reason: forbidden,
        );
      }
    });

    test('DOCX round-trips through DocxDocumentAdapter', () async {
      await seedManagedFile(bytes: _buildMinimalDocxBytes());
      final file = libraryFile(displayName: 'doc.docx');

      final plan =
          await resolvePlan(file, ParsedArtifactRouteSelection.docxText);
      final document = await adapter.generate(
        file: file,
        artifactId: 'artifact-docx',
        plan: plan,
      );

      expect(document.documentRef.sourceId, 'artifact-docx');
      expect(
        _singleText(document.parts[0]),
        'formal docx paragraph',
      );
      expect(document.parts[1], isA<SourceTablePart>());
      final strings = _publicStrings(document);
      expect(
        strings.any((value) => value.contains('shiroha_docx_')),
        isFalse,
      );
    });

    test('DOCX generation leaves no producer temp dirs behind', () async {
      final before = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .map((dir) => dir.path)
          .toSet();
      await seedManagedFile(bytes: _buildMinimalDocxBytes());
      final file = libraryFile(displayName: 'doc.docx');

      final plan =
          await resolvePlan(file, ParsedArtifactRouteSelection.docxText);
      final document = await adapter.generate(
        file: file,
        artifactId: 'artifact-docx',
        plan: plan,
      );
      expect(document.documentRef.sourceId, 'artifact-docx');

      final after = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .map((dir) => dir.path)
          .toSet();
      final newProducerDirs = after
          .difference(before)
          .where((path) => p.basename(path).startsWith('shiroha_docx_'))
          .toList();
      expect(newProducerDirs, isEmpty);
    });

    test('concurrent same-name DOCX generations stay isolated and leak-free',
        () async {
      final before = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .map((dir) => dir.path)
          .toSet();
      await seedManagedFile(
        bytes: _buildMinimalDocxBytes(),
        storageKey: 'library/file-1',
      );
      await seedManagedFile(
        bytes: _buildMinimalDocxBytes(),
        storageKey: 'library/file-2',
      );
      final first = libraryFile(
        fileId: 'file-1',
        displayName: 'doc.docx',
        storageKey: 'library/file-1',
      );
      final second = libraryFile(
        fileId: 'file-2',
        displayName: 'doc.docx',
        storageKey: 'library/file-2',
      );

      final results = await Future.wait(<Future<SourceDocument>>[
        adapter.generate(
          file: first,
          artifactId: 'artifact-docx-1',
          plan: ParsedArtifactGenerationPlan(
            parserRoute: 'docx_text',
            parserVersion: 'docx_document_adapter.source_adapter.v1',
            optionsSchemaVersion: 1,
          ),
        ),
        adapter.generate(
          file: second,
          artifactId: 'artifact-docx-2',
          plan: ParsedArtifactGenerationPlan(
            parserRoute: 'docx_text',
            parserVersion: 'docx_document_adapter.source_adapter.v1',
            optionsSchemaVersion: 1,
          ),
        ),
      ]);

      expect(
        results.map((document) => document.documentRef.sourceId).toList(),
        <String>['artifact-docx-1', 'artifact-docx-2'],
      );
      final after = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .map((dir) => dir.path)
          .toSet();
      final newProducerDirs = after
          .difference(before)
          .where((path) => p.basename(path).startsWith('shiroha_docx_'))
          .toList();
      expect(newProducerDirs, isEmpty);
    });

    test('PDF text round-trips through the shared extractor', () async {
      await seedManagedFile(bytes: _buildTextPdf('formal pdf text'));
      final file = libraryFile(displayName: 'doc.pdf');

      final plan =
          await resolvePlan(file, ParsedArtifactRouteSelection.pdfText);
      final document = await adapter.generate(
        file: file,
        artifactId: 'artifact-pdf',
        plan: plan,
      );

      expect(document.documentRef.sourceId, 'artifact-pdf');
      expect(_singleText(document.parts.single), contains('formal pdf text'));
    });

    test('empty PDF is sourceUnavailable without OCR', () async {
      await seedManagedFile(bytes: _buildBlankPdf());
      final file = libraryFile(displayName: 'doc.pdf');

      final plan =
          await resolvePlan(file, ParsedArtifactRouteSelection.pdfText);
      await expectLater(
        adapter.generate(
          file: file,
          artifactId: 'artifact-pdf',
          plan: plan,
        ),
        throwsA(
          isA<ParsedArtifactGenerationException>().having(
            (error) => error.failure,
            'failure',
            ParsedArtifactGenerationFailure.sourceUnavailable,
          ),
        ),
      );
    });
  });

  group('failure translation', () {
    test('missing managed source is sourceUnavailable', () async {
      final file = libraryFile();
      final plan = await resolvePlan(file, ParsedArtifactRouteSelection.txt);
      try {
        await adapter.generate(
          file: file,
          artifactId: 'artifact-1',
          plan: plan,
        );
        fail('expected sourceUnavailable');
      } on ParsedArtifactGenerationException catch (error) {
        expect(
          error.failure,
          ParsedArtifactGenerationFailure.sourceUnavailable,
        );
        expect(error.toString(), isNot(contains(tempDir.path)));
        expect(error.toString(), isNot(contains('library/file-1')));
      }
    });

    test('corrupt DOCX is parseFailed without publishing failure parts',
        () async {
      await seedManagedFile(
        bytes: utf8.encode('definitely not a zip: canary text'),
      );
      final file = libraryFile(displayName: 'corrupt.docx');

      final plan =
          await resolvePlan(file, ParsedArtifactRouteSelection.docxText);
      await expectLater(
        adapter.generate(
          file: file,
          artifactId: 'artifact-1',
          plan: plan,
        ),
        throwsA(
          isA<ParsedArtifactGenerationException>().having(
            (error) => error.failure,
            'failure',
            ParsedArtifactGenerationFailure.parseFailed,
          ),
        ),
      );
    });

    test('malformed PDF is parseFailed', () async {
      await seedManagedFile(
        bytes: utf8.encode('not a pdf at all'),
      );
      final file = libraryFile(displayName: 'bad.pdf');

      final plan =
          await resolvePlan(file, ParsedArtifactRouteSelection.pdfText);
      await expectLater(
        adapter.generate(
          file: file,
          artifactId: 'artifact-1',
          plan: plan,
        ),
        throwsA(
          isA<ParsedArtifactGenerationException>().having(
            (error) => error.failure,
            'failure',
            ParsedArtifactGenerationFailure.parseFailed,
          ),
        ),
      );
    });
  });
}

String _expectedRoute(ParsedArtifactRouteSelection selection) {
  return switch (selection) {
    ParsedArtifactRouteSelection.pdfText => 'pdf_text',
    ParsedArtifactRouteSelection.docxText => 'docx_text',
    ParsedArtifactRouteSelection.txt => 'txt',
    ParsedArtifactRouteSelection.markdown => 'markdown',
    _ => throw StateError('unexpected'),
  };
}

String? _singleText(SourcePart part) {
  if (part is! SourceContentPart) return null;
  final nodes = part.content.nodes;
  if (nodes.length != 1) return null;
  final node = nodes.single;
  return node is TextNode ? node.text : null;
}

Iterable<String> _publicStrings(SourceDocument document) sync* {
  yield document.documentRef.sourceId;
  if (document.documentRef.displayLabel != null) {
    yield document.documentRef.displayLabel!;
  }
  for (final part in document.parts) {
    yield part.sourceRef.sourceId;
    if (part.sourceRef.displayLabel != null) {
      yield part.sourceRef.displayLabel!;
    }
    switch (part) {
      case SourceContentPart(:final content):
        for (final node in content.nodes) {
          if (node is TextNode) yield node.text;
        }
      case SourceAssetPart(:final asset, :final alternativeText):
        yield asset.assetId;
        if (alternativeText != null) {
          for (final node in alternativeText.nodes) {
            if (node is TextNode) yield node.text;
          }
        }
      case SourceTablePart(:final rows):
        for (final row in rows) {
          for (final cell in row) {
            for (final node in cell.nodes) {
              if (node is TextNode) yield node.text;
            }
          }
        }
      case UnsupportedSourcePart(:final kindCode, :final fallbackContent):
        yield kindCode;
        for (final node in fallbackContent.nodes) {
          if (node is TextNode) yield node.text;
        }
    }
  }
  for (final issue in document.issues) {
    yield issue.code;
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
  return ZipEncoder().encode(archive)!;
}

List<int> _buildTextPdf(String text) {
  final document = PdfDocument();
  document.pages.add().graphics.drawString(
        text,
        PdfStandardFont(PdfFontFamily.helvetica, 12),
      );
  final bytes = document.saveSync();
  document.dispose();
  return bytes;
}

List<int> _buildBlankPdf() {
  final document = PdfDocument();
  document.pages.add();
  final bytes = document.saveSync();
  document.dispose();
  return bytes;
}
