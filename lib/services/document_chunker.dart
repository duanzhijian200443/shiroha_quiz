class DocumentChunker {
  const DocumentChunker({
    this.textBatchLimit = 1500,
    this.markdownBatchLimit = 2000,
  });

  final int textBatchLimit;
  final int markdownBatchLimit;

  List<String> split(String rawText, {required bool isMarkdown}) {
    return isMarkdown
        ? splitMarkdownIntoMicroBatches(rawText)
        : splitTextIntoMicroBatches(rawText);
  }

  List<String> splitTextIntoMicroBatches(String rawText) {
    final questionBlocks = <String>[];
    final currentChunk = StringBuffer();
    final paragraphs = rawText.split(RegExp(r'\n\s*\n'));

    for (final paragraph in paragraphs) {
      final text = paragraph.trim();
      if (text.isEmpty) continue;

      if (currentChunk.length + text.length > textBatchLimit) {
        if (currentChunk.isNotEmpty) {
          questionBlocks.add(currentChunk.toString());
          currentChunk.clear();
        }
      }
      currentChunk.writeln(text);
      currentChunk.writeln();
    }
    if (currentChunk.isNotEmpty) {
      questionBlocks.add(currentChunk.toString());
    }

    final microBatches = <String>[];
    final currentBatch = StringBuffer();
    for (final block in questionBlocks) {
      if (currentBatch.length + block.length > textBatchLimit &&
          currentBatch.isNotEmpty) {
        microBatches.add(currentBatch.toString());
        currentBatch.clear();
      }
      currentBatch.writeln(block);
      currentBatch.writeln();
    }
    if (currentBatch.isNotEmpty) {
      microBatches.add(currentBatch.toString());
    }
    return microBatches;
  }

  List<String> splitMarkdownIntoMicroBatches(String rawText) {
    final microBatches = <String>[];
    final currentBatch = StringBuffer();
    final parts =
        rawText.split(RegExp(r'\n(?=(?:#{1,6}\s|\d+\.|[一二三四五六七八九十]+、))'));

    for (final part in parts) {
      final text = part.trim();
      if (text.isEmpty) continue;

      if (currentBatch.length + text.length > markdownBatchLimit) {
        if (currentBatch.isNotEmpty) {
          microBatches.add(currentBatch.toString());
          currentBatch.clear();
        }
      }
      currentBatch.writeln(text);
      currentBatch.writeln();
    }
    if (currentBatch.isNotEmpty) {
      microBatches.add(currentBatch.toString());
    }
    return microBatches;
  }
}
