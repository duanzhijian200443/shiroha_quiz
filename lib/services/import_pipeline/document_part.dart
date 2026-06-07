enum TextRole {
  paragraph,
  heading,
  tableCell,
  formulaLike,
  answerBlock,
}

sealed class DocumentPart {
  final int order;
  const DocumentPart(this.order);
}

class TextPart extends DocumentPart {
  final String text;
  final TextRole role;

  const TextPart({
    required int order,
    required this.text,
    required this.role,
  }) : super(order);
}

class TablePart extends DocumentPart {
  final List<List<String>> rows;

  const TablePart({
    required int order,
    required this.rows,
  }) : super(order);
}

class ImagePart extends DocumentPart {
  final String path;
  final String? relationshipId;
  final String? assetId;
  final String? resolvedPath;
  final String? altText;

  const ImagePart({
    required int order,
    required this.path,
    this.relationshipId,
    this.assetId,
    this.resolvedPath,
    this.altText,
  }) : super(order);
}
