/// Canonical text normalization shared by OCR regionization, typed assembly,
/// and OCR legacy compatibility reconstruction.
///
/// Keeping this primitive shared prevents raw owned source materialization from
/// becoming a second whitespace authority after the regionizer has normalized
/// the authoritative OCR text.
String normalizeOcrText(String text) {
  return text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
