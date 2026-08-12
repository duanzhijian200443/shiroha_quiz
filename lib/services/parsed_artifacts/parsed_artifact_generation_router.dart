import '../../application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../../domain/assets/library_file.dart';
import '../../domain/source/source_document.dart';

/// Thin composite over the deterministic (F1-I1) and OCR (F1-I2) generation
/// ports. Pure delegation: no parser, provider, filesystem, question, or
/// cache logic lives here.
final class ParsedArtifactGenerationRouter
    implements ParsedArtifactGenerationPort {
  ParsedArtifactGenerationRouter({
    required ParsedArtifactGenerationPort deterministicGeneration,
    required ParsedArtifactGenerationPort ocrGeneration,
  })  : _deterministicGeneration = deterministicGeneration,
        _ocrGeneration = ocrGeneration;

  final ParsedArtifactGenerationPort _deterministicGeneration;
  final ParsedArtifactGenerationPort _ocrGeneration;

  @override
  Future<ParsedArtifactGenerationPlan> resolvePlan({
    required LibraryFile file,
    required ParsedArtifactParseOptions options,
  }) async {
    return switch (options.routeSelection) {
      ParsedArtifactRouteSelection.ocrPdf ||
      ParsedArtifactRouteSelection.ocrImage =>
        _ocrGeneration.resolvePlan(file: file, options: options),
      ParsedArtifactRouteSelection.auto ||
      ParsedArtifactRouteSelection.pdfText ||
      ParsedArtifactRouteSelection.docxText ||
      ParsedArtifactRouteSelection.txt ||
      ParsedArtifactRouteSelection.markdown =>
        _deterministicGeneration.resolvePlan(file: file, options: options),
    };
  }

  @override
  Future<SourceDocument> generate({
    required LibraryFile file,
    required String artifactId,
    required ParsedArtifactGenerationPlan plan,
  }) async {
    return switch (plan.parserRoute) {
      'pdf_text' ||
      'docx_text' ||
      'txt' ||
      'markdown' =>
        _deterministicGeneration.generate(
          file: file,
          artifactId: artifactId,
          plan: plan,
        ),
      'ocr_pdf' || 'ocr_image' => _ocrGeneration.generate(
          file: file,
          artifactId: artifactId,
          plan: plan,
        ),
      _ => throw const ParsedArtifactGenerationException(
          ParsedArtifactGenerationFailure.unsupportedRoute,
        ),
    };
  }
}
