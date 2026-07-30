import '../../data/models/ai_engine_profile.dart';
import 'ocr_document.dart';

abstract interface class OcrDocumentClient {
  String get modelId;

  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  });
}
