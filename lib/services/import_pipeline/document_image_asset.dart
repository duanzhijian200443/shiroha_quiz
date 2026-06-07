class DocumentImageAsset {
  final String id;
  final int order;
  final String sourceName;
  final String originalPath;
  final String? extractedPath;
  final String? altText;
  final int? byteLength;
  final bool isResolvable;

  const DocumentImageAsset({
    required this.id,
    required this.order,
    required this.sourceName,
    required this.originalPath,
    this.extractedPath,
    this.altText,
    this.byteLength,
    required this.isResolvable,
  });

  Map<String, dynamic> toDiagnostics() {
    return {
      'id': id,
      'order': order,
      'sourceName': sourceName,
      'originalPath': originalPath,
      'extractedPath': extractedPath,
      'altText': altText,
      'byteLength': byteLength,
      'isResolvable': isResolvable,
    };
  }
}
