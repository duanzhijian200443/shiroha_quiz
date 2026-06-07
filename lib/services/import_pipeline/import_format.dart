enum ImportFormat { pdf, image, docx, zip, txt, md, unknown }

extension ImportFormatDetection on ImportFormat {
  static ImportFormat fromPath(String path) {
    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('.pdf')) {
      return ImportFormat.pdf;
    }
    if (lowerPath.endsWith('.docx')) {
      return ImportFormat.docx;
    }
    if (lowerPath.endsWith('.zip')) {
      return ImportFormat.zip;
    }
    if (lowerPath.endsWith('.md') || lowerPath.endsWith('.markdown')) {
      return ImportFormat.md;
    }
    if (lowerPath.endsWith('.txt')) {
      return ImportFormat.txt;
    }
    if (lowerPath.endsWith('.png') ||
        lowerPath.endsWith('.jpg') ||
        lowerPath.endsWith('.jpeg')) {
      return ImportFormat.image;
    }
    return ImportFormat.unknown;
  }
}
