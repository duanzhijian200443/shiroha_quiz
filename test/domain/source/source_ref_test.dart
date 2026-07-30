import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  group('SourceRef valid construction', () {
    test('represents document, page, block, and ordered ranges', () {
      final document = SourceRef.document(sourceId: 'source_001');
      final pagePoint = SourcePoint.page(pageNumber: 1);
      final page = SourceRef.at(
        sourceId: 'source_001',
        point: pagePoint,
      );
      final blockPoint = SourcePoint.block(
        pageNumber: 2,
        blockId: 'block_002',
        readingOrder: 0,
      );
      final block = SourceRef.at(
        sourceId: 'source_001',
        point: blockPoint,
      );
      final samePageRange = SourceRef.range(
        sourceId: 'source_001',
        start: SourcePoint.block(
          pageNumber: 2,
          blockId: 'block_003',
          readingOrder: 1,
        ),
        end: SourcePoint.block(
          pageNumber: 2,
          blockId: 'block_005',
          readingOrder: 3,
        ),
      );
      final crossPageRange = SourceRef.range(
        sourceId: 'source_001',
        displayLabel: '数学试卷.pdf',
        start: SourcePoint.block(
          pageNumber: 2,
          blockId: 'block_006',
          readingOrder: 4,
        ),
        end: SourcePoint.block(
          pageNumber: 3,
          blockId: 'block_007',
          readingOrder: 0,
        ),
      );

      expect(document.start, isNull);
      expect(document.end, isNull);
      expect(page.start, pagePoint);
      expect(page.end, pagePoint);
      expect(pagePoint.blockId, isNull);
      expect(pagePoint.readingOrder, isNull);
      expect(block.start, blockPoint);
      expect(block.end, blockPoint);
      expect(samePageRange.start!.pageNumber, 2);
      expect(samePageRange.end!.readingOrder, 3);
      expect(crossPageRange.end!.pageNumber, 3);
      expect(crossPageRange.displayLabel, '数学试卷.pdf');
    });

    test('uses stable value equality and hash codes', () {
      final first = SourceRef.range(
        sourceId: 'source_001',
        start: SourcePoint.block(
          pageNumber: 1,
          blockId: 'block_001',
          readingOrder: 0,
        ),
        end: SourcePoint.block(
          pageNumber: 1,
          blockId: 'block_002',
          readingOrder: 1,
        ),
      );
      final equal = SourceRef.range(
        sourceId: 'source_001',
        start: SourcePoint.block(
          pageNumber: 1,
          blockId: 'block_001',
          readingOrder: 0,
        ),
        end: SourcePoint.block(
          pageNumber: 1,
          blockId: 'block_002',
          readingOrder: 1,
        ),
      );
      final different = SourceRef.document(sourceId: 'source_002');

      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect(<SourceRef>{first}, contains(equal));
      expect(different, isNot(first));
    });
  });

  group('SourceRef invalid construction', () {
    test('rejects unsafe source and block identifiers', () {
      final invalidSourceIds = <String>[
        '',
        ' ',
        'source id',
        'a' * 129,
        r'C:\private\paper.pdf',
        '/private/paper.pdf',
        'file://paper.pdf',
        'https://example.invalid/paper.pdf',
        'data:image/png;base64,synthetic',
      ];

      for (final sourceId in invalidSourceIds) {
        expect(
          () => SourceRef.document(sourceId: sourceId),
          throwsFormatException,
          reason: sourceId.isEmpty ? 'empty source ID' : 'unsafe source ID',
        );
      }

      final invalidBlockIds = <String>[
        '',
        ' ',
        'block id',
        'a' * 129,
        'folder/block',
        r'folder\block',
      ];
      for (final blockId in invalidBlockIds) {
        expect(
          () => SourcePoint.block(
            pageNumber: 1,
            blockId: blockId,
            readingOrder: 0,
          ),
          throwsFormatException,
        );
      }
    });

    test('rejects invalid positions and ranges', () {
      expect(
        () => SourcePoint.page(pageNumber: 0),
        throwsFormatException,
      );
      expect(
        () => SourcePoint.page(pageNumber: -1),
        throwsFormatException,
      );
      expect(
        () => SourcePoint.block(
          pageNumber: 1,
          blockId: 'block_001',
          readingOrder: -1,
        ),
        throwsFormatException,
      );

      final first = SourcePoint.block(
        pageNumber: 1,
        blockId: 'block_001',
        readingOrder: 0,
      );
      final second = SourcePoint.block(
        pageNumber: 1,
        blockId: 'block_002',
        readingOrder: 1,
      );
      expect(
        () => SourceRef.range(
          sourceId: 'source_001',
          start: second,
          end: first,
        ),
        throwsFormatException,
      );
      expect(
        () => SourceRef.range(
          sourceId: 'source_001',
          start: first,
          end: first,
        ),
        throwsFormatException,
      );
      expect(
        () => SourceRef.range(
          sourceId: 'source_001',
          start: SourcePoint.page(pageNumber: 1),
          end: second,
        ),
        throwsFormatException,
      );
    });

    test('rejects unsafe display labels without normalizing them', () {
      final invalidLabels = <String>[
        '',
        ' label.pdf',
        'label.pdf ',
        'a' * 161,
        '.',
        '..',
        'folder/label.pdf',
        r'folder\label.pdf',
        'file://label.pdf',
        'https://example.invalid/label.pdf',
        'label\u0000.pdf',
      ];

      for (final displayLabel in invalidLabels) {
        expect(
          () => SourceRef.document(
            sourceId: 'source_001',
            displayLabel: displayLabel,
          ),
          throwsFormatException,
        );
      }
    });
  });
}
