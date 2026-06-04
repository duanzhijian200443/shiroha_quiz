import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/document_chunker.dart';

void main() {
  group('DocumentChunker', () {
    test('splits plain text by paragraph batches', () {
      const chunker = DocumentChunker(textBatchLimit: 20);

      final chunks = chunker.splitTextIntoMicroBatches(
        '第一段题干\n\n第二段题干比较长\n\n第三段',
      );

      expect(chunks, isNotEmpty);
      expect(chunks.join('\n'), contains('第一段题干'));
      expect(chunks.join('\n'), contains('第三段'));
    });

    test('splits markdown on headings and numbered sections', () {
      const chunker = DocumentChunker(markdownBatchLimit: 18);

      final chunks = chunker.splitMarkdownIntoMicroBatches(
        '# 标题\n内容\n1. 第一题\n题干\n二、第二题\n题干',
      );

      expect(chunks.length, greaterThan(1));
      expect(chunks.join('\n'), contains('1. 第一题'));
      expect(chunks.join('\n'), contains('二、第二题'));
    });
  });
}
