import 'dart:io';

import '../../application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../../domain/assets/library_file.dart';
import '../../domain/source/source_document.dart';
import '../file_library/managed_file_storage.dart';
import '../import_pipeline/adapters/docx_document_adapter.dart';
import '../import_pipeline/adapters/markdown_document_adapter.dart';
import '../import_pipeline/adapters/parsed_source_document_adapter.dart';
import '../import_pipeline/adapters/pdf_text_extractor_adapter.dart';
import '../import_pipeline/adapters/txt_document_adapter.dart';
import '../import_pipeline/document_part.dart';
import '../import_pipeline/document_signals.dart';
import '../import_pipeline/import_format.dart';
import '../import_pipeline/parsed_document.dart';

const _parserVersions = <String, String>{
  'pdf_text': 'syncfusion_pdf_text.source_adapter.v1',
  'docx_text': 'docx_document_adapter.source_adapter.v1',
  'txt': 'txt_document_adapter.source_adapter.v1',
  'markdown': 'markdown_document_adapter.source_adapter.v1',
};

/// Deterministic production generation adapter (F1-I1).
///
/// Reuses the existing parser truth:
/// - pdf_text: shared Syncfusion PDF text extraction
///   ([PdfTextExtractorAdapter]);
/// - docx_text: [DocxDocumentAdapter];
/// - txt: [TxtDocumentAdapter];
/// - markdown: [MarkdownDocumentAdapter].
///
/// Every `ParsedDocument` flows through [ParsedSourceDocumentAdapter] (the
/// only safe projection; the R2D acceptance allowlist authorizes exactly this
/// production consumer). OCR, image OCR, ZIP, and vision are never invoked:
/// `ocr_pdf`/`ocr_image` selections fail with `unsupportedRoute`.
final class DeterministicParsedArtifactGenerationAdapter
    implements ParsedArtifactGenerationPort {
  DeterministicParsedArtifactGenerationAdapter({
    required ManagedFileStorage managedFileStorage,
  }) : _managedFileStorage = managedFileStorage;

  final ManagedFileStorage _managedFileStorage;

  static const ParsedSourceDocumentAdapter _sourceDocumentAdapter =
      ParsedSourceDocumentAdapter();

  /// Monotonic same-process marker that keeps DOCX producer temp cleanup
  /// strictly scoped to the generating call.
  static int _docxTempCallCounter = 0;

  @override
  Future<ParsedArtifactGenerationPlan> resolvePlan({
    required LibraryFile file,
    required ParsedArtifactParseOptions options,
  }) async {
    final route = _resolveRoute(file, options);
    return ParsedArtifactGenerationPlan(
      parserRoute: route,
      parserVersion: _parserVersions[route]!,
      optionsSchemaVersion: 1,
    );
  }

  @override
  Future<SourceDocument> generate({
    required LibraryFile file,
    required String artifactId,
    required ParsedArtifactGenerationPlan plan,
  }) async {
    try {
      return switch (plan.parserRoute) {
        'pdf_text' => await _generatePdf(file, artifactId),
        'docx_text' => await _generateDocx(file, artifactId),
        'txt' => await _generateTxt(file, artifactId),
        'markdown' => await _generateMarkdown(file, artifactId),
        _ => throw const ParsedArtifactGenerationException(
            ParsedArtifactGenerationFailure.unsupportedRoute,
          ),
      };
    } on ParsedArtifactGenerationException {
      rethrow;
    } on FileSystemException {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.sourceUnavailable,
      );
    } catch (_) {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.parseFailed,
      );
    }
  }

  String _resolveRoute(
    LibraryFile file,
    ParsedArtifactParseOptions options,
  ) {
    switch (options.routeSelection) {
      case ParsedArtifactRouteSelection.auto:
        return _autoRoute(file);
      case ParsedArtifactRouteSelection.pdfText:
        _requireFormatCompatible(file, ImportFormat.pdf);
        return 'pdf_text';
      case ParsedArtifactRouteSelection.docxText:
        _requireFormatCompatible(file, ImportFormat.docx);
        return 'docx_text';
      case ParsedArtifactRouteSelection.txt:
        _requireFormatCompatible(file, ImportFormat.txt);
        return 'txt';
      case ParsedArtifactRouteSelection.markdown:
        _requireFormatCompatible(file, ImportFormat.md);
        return 'markdown';
      case ParsedArtifactRouteSelection.ocrPdf:
      case ParsedArtifactRouteSelection.ocrImage:
        throw const ParsedArtifactGenerationException(
          ParsedArtifactGenerationFailure.unsupportedRoute,
        );
    }
  }

  String _autoRoute(LibraryFile file) {
    final format = ImportFormatDetection.fromPath(file.displayName);
    return switch (format) {
      ImportFormat.pdf => 'pdf_text',
      ImportFormat.docx => 'docx_text',
      ImportFormat.txt => 'txt',
      ImportFormat.md => 'markdown',
      ImportFormat.image ||
      ImportFormat.zip ||
      ImportFormat.unknown =>
        throw const ParsedArtifactGenerationException(
          ParsedArtifactGenerationFailure.unsupportedRoute,
        ),
    };
  }

  /// Explicit selections proceed unless safe format detection clearly
  /// conflicts with the requested route. An unknown extension carries no
  /// reliable signal and does not block an explicit route.
  void _requireFormatCompatible(LibraryFile file, ImportFormat expected) {
    final detected = ImportFormatDetection.fromPath(file.displayName);
    if (detected == ImportFormat.unknown) return;
    if (detected != expected) {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.unsupportedRoute,
      );
    }
  }

  Future<SourceDocument> _generateTxt(
    LibraryFile file,
    String artifactId,
  ) async {
    final managed = await _resolveManagedFile(file);
    final parsed = await TxtDocumentAdapter.parse(
      filePath: managed.path,
      sourceName: file.displayName,
    );
    return _convertParsed(parsed, file, artifactId);
  }

  Future<SourceDocument> _generateMarkdown(
    LibraryFile file,
    String artifactId,
  ) async {
    final managed = await _resolveManagedFile(file);
    final parsed = await MarkdownDocumentAdapter.parse(
      filePath: managed.path,
      sourceName: file.displayName,
    );
    return _convertParsed(parsed, file, artifactId);
  }

  Future<SourceDocument> _generateDocx(
    LibraryFile file,
    String artifactId,
  ) async {
    final managed = await _resolveManagedFile(file);
    // The DOCX producer embeds sourceName into its system-temp directory
    // name. A unique per-call marker keeps cleanup scoped to this call, so
    // two concurrent DOCX generations can never delete each other's temp
    // directories. The marker only affects internal producer metadata and is
    // redacted by the safe SourceDocument projection.
    final uniqueSourceName = '${file.displayName}.gen${_docxTempCallCounter++}';
    try {
      final parsed = await DocxDocumentAdapter.parse(
        filePath: managed.path,
        sourceName: uniqueSourceName,
      );
      return _convertParsed(parsed, file, artifactId);
    } finally {
      await _cleanupProducerTempDirs(
        'shiroha_docx_${_safeTempBase(uniqueSourceName)}_',
      );
    }
  }

  Future<SourceDocument> _generatePdf(
    LibraryFile file,
    String artifactId,
  ) async {
    final managed = await _resolveManagedFile(file);
    final text = await PdfTextExtractorAdapter.extractText(
      filePath: managed.path,
    );
    if (text.trim().isEmpty) {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.sourceUnavailable,
      );
    }
    final parsed = ParsedDocument(
      sourceName: file.displayName,
      format: ImportFormat.pdf,
      parts: <DocumentPart>[
        TextPart(order: 0, text: text, role: TextRole.paragraph),
      ],
      signals: const DocumentSignals(),
      contentStatus: ParsedDocumentContentStatus.usable,
    );
    return _convertParsed(parsed, file, artifactId);
  }

  SourceDocument _convertParsed(
    ParsedDocument parsed,
    LibraryFile file,
    String artifactId,
  ) {
    if (parsed.contentStatus ==
        ParsedDocumentContentStatus.infrastructureFailure) {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.parseFailed,
      );
    }
    return _sourceDocumentAdapter.convert(
      parsed,
      sourceId: artifactId,
      displayLabel: file.displayName,
    );
  }

  Future<File> _resolveManagedFile(LibraryFile file) async {
    try {
      if (!await _managedFileStorage.managedFileExists(file.storageKey)) {
        throw const ParsedArtifactGenerationException(
          ParsedArtifactGenerationFailure.sourceUnavailable,
        );
      }
      return _managedFileStorage.resolveManagedFile(file.storageKey);
    } on ParsedArtifactGenerationException {
      rethrow;
    } catch (_) {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.sourceUnavailable,
      );
    }
  }

  /// Deletes system-temp directories created by the DOCX producer for the
  /// current call. The prefix is unique per call; cleanup is best-effort and
  /// never changes the parse outcome or surfaces a path.
  Future<void> _cleanupProducerTempDirs(String uniquePrefix) async {
    try {
      final tempRoot = Directory.systemTemp.absolute.path;
      for (final dir in Directory.systemTemp
          .listSync(followLinks: false)
          .whereType<Directory>()) {
        if (dir.parent.absolute.path != tempRoot) continue;
        final basename = dir.path.split(Platform.pathSeparator).last;
        if (!basename.startsWith(uniquePrefix)) continue;
        try {
          await dir.delete(recursive: true);
        } catch (_) {
          // Best-effort; an orphaned producer temp dir never changes the
          // primary outcome.
        }
      }
    } catch (_) {
      // Cleanup failure is never surfaced.
    }
  }
}

String _safeTempBase(String sourceName) {
  return sourceName.replaceAll(RegExp(r'[^\w.-]'), '_');
}
