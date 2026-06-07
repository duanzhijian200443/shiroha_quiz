import 'import_format.dart';

class ImportFileDetector {
  static ImportFormat detect(String filePath) {
    return ImportFormatDetection.fromPath(filePath);
  }
}
