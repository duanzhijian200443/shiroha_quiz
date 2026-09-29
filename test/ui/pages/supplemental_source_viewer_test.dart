// P6 SV-C2: read-only original source viewer widget regression.
//
// Synthetic fixtures only: no real PDF/OCR/provider, no network, no private
// files. Proves format dispatch over the SV-C1 inspection value, exact
// original-bytes handoff through the presentation-only PDF surface seam,
// page-hint pass-through/clamping, and fixed safe failure states that never
// leak raw exceptions, extracted text, paths, or storage keys.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_source_inspection.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/ui/pages/supplemental_source_viewer.dart';

const String _fileId = 'sv_c2_file';
const String _artifactId = 'sv_c2_artifact';
const String _sha256 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _storageKey = 'p6/sv-c2/storage-key';

const String _unableMessage = '无法显示原文件内容';
const String _unsupportedMessage = '当前格式暂不支持应用内原文查看，因此无法完成原文核验。';

void main() {
  testWidgets('text/plain renders the raw UTF-8 original content',
      (tester) async {
    final bytes = utf8.encode('答案：A\n第二行原文');
    final inspection = await _inspect(
      bytes: bytes,
      mimeType: 'text/plain',
    );
    final opener = _FakePdfOpener();

    await _pumpViewer(tester, inspection: inspection, opener: opener);

    expect(find.text('答案：A\n第二行原文'), findsOneWidget);
    expect(find.text('answers.pdf'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('supplemental-source-viewer-text')),
      findsOneWidget,
    );
    expect(opener.callCount, 0,
        reason: 'text must not go through the PDF seam');
    expect(find.textContaining(_storageKey), findsNothing);
  });

  testWidgets('text/markdown is shown as raw text without Markdown conversion',
      (tester) async {
    final inspection = await _inspect(
      bytes: utf8.encode('# 标题\n**加粗** 原文'),
      mimeType: 'text/markdown',
    );
    final opener = _FakePdfOpener();

    await _pumpViewer(tester, inspection: inspection, opener: opener);

    expect(find.text('# 标题\n**加粗** 原文'), findsOneWidget);
    expect(find.text('标题'), findsNothing,
        reason: 'markdown headings must not be parsed into styled nodes');
    expect(find.text('加粗'), findsNothing,
        reason: 'markdown emphasis must not be parsed into styled nodes');
    expect(opener.callCount, 0);
  });

  testWidgets('invalid UTF-8 shows the fixed safe state without exception leak',
      (tester) async {
    final inspection = await _inspect(
      bytes: <int>[0xff, 0xfe, 0x00, 0x9f],
      mimeType: 'text/plain',
    );
    final opener = _FakePdfOpener();

    await _pumpViewer(tester, inspection: inspection, opener: opener);

    expect(find.text(_unableMessage), findsOneWidget);
    expect(find.textContaining('FormatException'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
    expect(opener.callCount, 0);
  });

  testWidgets('image mime builds the image surface from the exact bytes',
      (tester) async {
    final bytes = List<int>.generate(16, (index) => index);
    final inspection = await _inspect(
      bytes: bytes,
      mimeType: 'image/png',
    );
    final opener = _FakePdfOpener();

    await _pumpViewer(tester, inspection: inspection, opener: opener);

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is MemoryImage &&
            _sameBytes(
              (widget.image as MemoryImage).bytes,
              bytes,
            ),
      ),
      findsOneWidget,
      reason: 'the image surface must use the original managed bytes',
    );
    expect(
      find.byKey(const ValueKey<String>('supplemental-source-viewer-image')),
      findsOneWidget,
    );
    expect(opener.callCount, 0);
  });

  testWidgets('DOCX stays unsupported and never falls back to extracted text',
      (tester) async {
    final inspection = await _inspect(
      bytes: utf8.encode('extracted body text that must not be shown'),
      mimeType:
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    );
    final opener = _FakePdfOpener();

    await _pumpViewer(tester, inspection: inspection, opener: opener);

    expect(find.text(_unsupportedMessage), findsOneWidget);
    expect(find.textContaining('extracted body text'), findsNothing);
    expect(opener.callCount, 0,
        reason: 'unsupported formats must not open the PDF seam');
  });

  testWidgets('unknown mime stays unsupported', (tester) async {
    final inspection = await _inspect(
      bytes: utf8.encode('opaque bytes'),
      mimeType: 'application/octet-stream',
    );
    final opener = _FakePdfOpener();

    await _pumpViewer(tester, inspection: inspection, opener: opener);

    expect(find.text(_unsupportedMessage), findsOneWidget);
    expect(find.textContaining('opaque bytes'), findsNothing);
    expect(opener.callCount, 0);
  });

  testWidgets('PDF hands the exact original bytes to the surface opener',
      (tester) async {
    final bytes = utf8.encode('%PDF-1.7 synthetic');
    final inspection = await _inspect(
      bytes: bytes,
      mimeType: 'application/pdf',
    );
    final opener = _FakePdfOpener();

    await _pumpViewer(tester, inspection: inspection, opener: opener);

    expect(opener.callCount, 1);
    expect(opener.receivedBytes.single, orderedEquals(bytes));
  });

  testWidgets('PDF without a page hint does not fabricate an exact page',
      (tester) async {
    final inspection = await _inspect(
      bytes: utf8.encode('%PDF-1.7 synthetic'),
      mimeType: 'application/pdf',
    );
    final opener = _FakePdfOpener(pagesCount: 5);

    await _pumpViewer(
      tester,
      inspection: inspection,
      opener: opener,
      pageHint: null,
    );

    expect(opener.buildViewCount, 1);
    expect(
      opener.receivedInitialPages.single,
      isNull,
      reason: 'null hint must stay null instead of a fabricated page number',
    );
  });

  testWidgets('PDF passes a valid 1-based page hint through unchanged',
      (tester) async {
    final inspection = await _inspect(
      bytes: utf8.encode('%PDF-1.7 synthetic'),
      mimeType: 'application/pdf',
    );
    final opener = _FakePdfOpener(pagesCount: 5);

    await _pumpViewer(
      tester,
      inspection: inspection,
      opener: opener,
      pageHint: 3,
    );

    expect(opener.receivedInitialPages.single, 3);
  });

  testWidgets('out-of-range page hints clamp into the valid page range',
      (tester) async {
    final inspection = await _inspect(
      bytes: utf8.encode('%PDF-1.7 synthetic'),
      mimeType: 'application/pdf',
    );

    final opener = _FakePdfOpener(pagesCount: 5);
    await _pumpViewer(
      tester,
      inspection: inspection,
      opener: opener,
      pageHint: 99,
    );
    expect(opener.receivedInitialPages.single, 5);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(
      opener.disposeCount,
      1,
      reason: 'the prepared surface is released when the viewer is disposed',
    );

    await _pumpViewer(
      tester,
      inspection: inspection,
      opener: opener,
      pageHint: 0,
    );
    expect(
      opener.receivedInitialPages.last,
      1,
      reason: 'non-positive hints clamp to the first page',
    );
  });

  testWidgets('PDF open failure shows the fixed safe state without details',
      (tester) async {
    final inspection = await _inspect(
      bytes: utf8.encode('%PDF-1.7 synthetic'),
      mimeType: 'application/pdf',
    );
    final opener = _FakePdfOpener(errorOnOpen: true);

    await _pumpViewer(tester, inspection: inspection, opener: opener);

    expect(find.text(_unableMessage), findsOneWidget);
    expect(find.textContaining('synthetic pdf open failure'), findsNothing);
  });

  testWidgets('empty PDF disposes the surface and shows the fixed safe state',
      (tester) async {
    final inspection = await _inspect(
      bytes: utf8.encode('%PDF-1.7 synthetic'),
      mimeType: 'application/pdf',
    );
    final opener = _FakePdfOpener(pagesCount: 0);

    await _pumpViewer(tester, inspection: inspection, opener: opener);

    expect(find.text(_unableMessage), findsOneWidget);
    expect(opener.buildViewCount, 0);
    expect(opener.disposeCount, 1);
  });

  testWidgets(
      'PDF page render failure after a successful open falls back to the '
      'fixed safe state', (tester) async {
    final inspection = await _inspect(
      bytes: utf8.encode('%PDF-1.7 synthetic'),
      mimeType: 'application/pdf',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SupplementalSourceViewerScreen(
          inspection: inspection,
          pdfSurfaceOpener: (_) => openSupplementalPdfSurfaceFromDocument(
            Future<pdfx.PdfDocument>.value(_RenderFailurePdfDocument()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(_unableMessage),
      findsOneWidget,
      reason: 'a failed page render must land in the fixed safe error state',
    );
    expect(find.textContaining('synthetic page render failure'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('sv-c2-fake'), findsNothing);
  });
}

bool _sameBytes(Uint8List actual, List<int> expected) {
  if (actual.length != expected.length) {
    return false;
  }
  for (var index = 0; index < actual.length; index++) {
    if (actual[index] != expected[index]) {
      return false;
    }
  }
  return true;
}

Future<SupplementalSourceInspection> _inspect({
  required List<int> bytes,
  required String mimeType,
  String displayName = 'answers.pdf',
}) async {
  final file = LibraryFile(
    fileId: _fileId,
    displayName: displayName,
    mimeType: mimeType,
    sizeBytes: bytes.length,
    sha256: _sha256,
    storageKey: _storageKey,
    createdAt: DateTime.utc(2026, 1, 1),
  );
  final service = SupplementalSourceInspectionService(
    fileCatalog: _FakeFileCatalog(file),
    artifactPort: _FakeArtifactPort(),
    sourceReader: _FakeSourceReader(bytes),
    maxBytes: 1 << 30,
  );
  return service.inspect(_fileId);
}

Future<void> _pumpViewer(
  WidgetTester tester, {
  required SupplementalSourceInspection inspection,
  required _FakePdfOpener opener,
  int? pageHint,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SupplementalSourceViewerScreen(
        inspection: inspection,
        pageHint: pageHint,
        pdfSurfaceOpener: opener.call,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// pdfx document whose page rendering always fails after a successful open.
class _RenderFailurePdfDocument extends pdfx.PdfDocument {
  _RenderFailurePdfDocument()
      : super(
          sourceName: 'memory',
          id: 'sv-c2-fake-document',
          pagesCount: 1,
        );

  @override
  Future<pdfx.PdfPage> getPage(
    int pageNumber, {
    bool autoCloseAndroid = false,
  }) async {
    return _RenderFailurePdfPage(document: this);
  }

  @override
  Future<void> close() async {}
}

class _RenderFailurePdfPage extends pdfx.PdfPage {
  _RenderFailurePdfPage({required super.document})
      : super(
          id: 'sv-c2-fake-page',
          pageNumber: 1,
          width: 100,
          height: 140,
          autoCloseAndroid: false,
        );

  @override
  Future<pdfx.PdfPageImage?> render({
    required double width,
    required double height,
    pdfx.PdfPageImageFormat format = pdfx.PdfPageImageFormat.jpeg,
    String? backgroundColor,
    Rect? cropRect,
    int quality = 100,
    bool forPrint = false,
    bool removeTempFile = true,
  }) async {
    throw Exception('synthetic page render failure');
  }

  @override
  Future<pdfx.PdfPageTexture> createTexture() async {
    throw UnimplementedError();
  }

  @override
  Future<void> close() async {}
}

class _FakePdfOpener {
  _FakePdfOpener({this.pagesCount = 5, this.errorOnOpen = false});

  final int pagesCount;
  final bool errorOnOpen;

  int callCount = 0;
  int buildViewCount = 0;
  int disposeCount = 0;
  final List<Uint8List> receivedBytes = <Uint8List>[];
  final List<int?> receivedInitialPages = <int?>[];

  Future<SupplementalPdfSurface> call(Uint8List originalBytes) async {
    callCount++;
    receivedBytes.add(originalBytes);
    if (errorOnOpen) {
      throw Exception('synthetic pdf open failure');
    }
    return SupplementalPdfSurface(
      pagesCount: pagesCount,
      buildView: (initialPage) {
        buildViewCount++;
        receivedInitialPages.add(initialPage);
        return SizedBox(
          key: ValueKey<String>('fake-pdf-surface-page-$initialPage'),
        );
      },
      dispose: () async {
        disposeCount++;
      },
    );
  }
}

class _FakeFileCatalog implements LibraryFileRepositoryPort {
  _FakeFileCatalog(this.file);

  final LibraryFile file;

  @override
  Future<void> save(LibraryFile file) async {}

  @override
  Future<LibraryFile?> findById(String fileId) async => file;

  @override
  Future<List<LibraryFile>> findAll() async => <LibraryFile>[file];
}

class _FakeArtifactPort implements ParsedArtifactLifecyclePort {
  final ParsedArtifactSnapshot _snapshot = ParsedArtifactSnapshot(
    artifact: ParsedArtifact(
      fileId: _fileId,
      artifactId: _artifactId,
      revision: 1,
      payloadSchemaVersion: 1,
    ),
    sourceDocument: SourceDocument(sourceId: _artifactId),
  );

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async =>
      _snapshot;

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> removeCurrentArtifact({
    required String fileId,
    required int expectedRevision,
  }) async {
    throw UnimplementedError();
  }
}

class _FakeSourceReader implements SupplementalSourceReaderPort {
  _FakeSourceReader(this.bytes);

  final List<int> bytes;

  @override
  Future<SupplementalSourceReadResult> readOriginalBytes({
    required LibraryFile file,
    required int maxBytes,
  }) async {
    return SupplementalSourceReadResult(
      bytes: bytes,
      actualSizeBytes: bytes.length,
      actualSha256: _sha256,
    );
  }
}
