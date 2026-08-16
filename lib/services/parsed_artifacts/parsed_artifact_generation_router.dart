import '../../application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../../core/observability/app_logger.dart';
import '../../core/observability/trace_context.dart';
import '../../domain/assets/library_file.dart';
import '../../domain/source/source_document.dart';

/// Thin composite over the deterministic (F1-I1) and OCR (F1-I2) generation
/// ports. Pure delegation: no parser, provider, filesystem, question, or
/// cache logic lives here.
///
/// OBS-1: [generate] runs the real generation operation inside a
/// `parsedArtifactGeneration` trace. When called inside an existing operation
/// (for example a future Agent turn) the trace becomes its child; a
/// standalone File Detail generation opens a new root correlation. Only
/// structural metadata (effective parser route, status, duration, opaque
/// artifact id) is logged; SourceDocument content, file paths and user file
/// names are never logged. The frozen F1 plan contract stays untouched.
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
  }) {
    return _tracedGenerate(
      parserRoute: plan.parserRoute,
      artifactId: artifactId,
      action: () => switch (plan.parserRoute) {
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
      },
    );
  }

  /// Best-effort observability only: trace/log failures never change the
  /// generation outcome.
  Future<SourceDocument> _tracedGenerate({
    required String parserRoute,
    required String artifactId,
    required Future<SourceDocument> Function() action,
  }) async {
    final stopwatch = Stopwatch()..start();
    return TraceContext.runOperation(
      operationKind: TraceOperationKind.parsedArtifactGeneration,
      action: () async {
        try {
          final document = await action();
          AppLogger.info(
            'ParsedArtifact generation completed',
            module: 'ParsedArtifacts',
            data: <String, Object?>{
              'stage': 'parsed_artifact_generation',
              'parserRoute': parserRoute,
              'artifactId': artifactId,
              'status': 'success',
              'durationMs': stopwatch.elapsedMilliseconds,
            },
          );
          return document;
        } catch (error) {
          AppLogger.error(
            'ParsedArtifact generation failed',
            module: 'ParsedArtifacts',
            data: <String, Object?>{
              'stage': 'parsed_artifact_generation',
              'parserRoute': parserRoute,
              'artifactId': artifactId,
              'status': 'failed',
              'errorType': error.runtimeType.toString(),
              'durationMs': stopwatch.elapsedMilliseconds,
            },
          );
          rethrow;
        }
      },
    );
  }
}
