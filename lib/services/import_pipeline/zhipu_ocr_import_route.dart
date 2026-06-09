import '../ai_service.dart';
import 'import_format.dart';
import 'zhipu_ocr_document_service.dart';

class ZhipuOcrImportRouteResult {
  final List<Map<String, dynamic>> questions;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;

  const ZhipuOcrImportRouteResult({
    required this.questions,
    required this.warnings,
    required this.diagnostics,
  });
}

class ZhipuOcrImportRoute {
  const ZhipuOcrImportRoute({
    this.documentService = const ZhipuOcrDocumentService(),
  });

  final ZhipuOcrDocumentService documentService;

  bool supports(ImportFormat format) {
    return format == ImportFormat.pdf || format == ImportFormat.image;
  }

  Future<ZhipuOcrImportRouteResult> parseFile({
    required String filePath,
    required String sourceName,
    required String taskId,
  }) async {
    final ocrResult = await documentService.parseFile(
      filePath: filePath,
      sourceName: sourceName,
    );

    final questions = ocrResult.markdown.trim().length > 10
        ? await AiService.instance.parseTextToQuestions(
            ocrResult.markdown,
            taskId: taskId,
            isMarkdown: true,
          )
        : <Map<String, dynamic>>[];

    return ZhipuOcrImportRouteResult(
      questions: questions,
      warnings: ocrResult.warnings,
      diagnostics: ocrResult.diagnostics,
    );
  }
}
