import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/docx_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/markdown_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/txt_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/zip_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/parsed_document.dart';

void main() {
  group('ParsedDocumentContentStatus producers', () {
    test('pure Markdown and TXT content remains usable, including empty', () {
      final markdown = MarkdownDocumentAdapter.parseContent(
        content: 'formal markdown',
        sourceName: 'synthetic.md',
      );
      final emptyMarkdown = MarkdownDocumentAdapter.parseContent(
        content: '',
        sourceName: 'synthetic.md',
      );
      final txt = TxtDocumentAdapter.parseContent(
        content: 'formal text',
        sourceName: 'synthetic.txt',
      );
      final emptyTxt = TxtDocumentAdapter.parseContent(
        content: '',
        sourceName: 'synthetic.txt',
      );

      for (final document in <ParsedDocument>[
        markdown,
        emptyMarkdown,
        txt,
        emptyTxt,
      ]) {
        expect(document.contentStatus, ParsedDocumentContentStatus.usable);
      }
      expect(markdown.fallbackUsed, isFalse);
      expect(emptyMarkdown.fallbackUsed, isTrue);
      expect(txt.fallbackUsed, isFalse);
      expect(emptyTxt.fallbackUsed, isTrue);
    });

    test('Markdown, TXT, and ZIP catch paths mark failure placeholders',
        () async {
      final markdown = await MarkdownDocumentAdapter.parseForTesting(
        sourceName: 'synthetic.md',
        readContent: () async => throw StateError('synthetic read failure'),
      );
      final txt = await TxtDocumentAdapter.parseForTesting(
        sourceName: 'synthetic.txt',
        readBytes: () async => throw StateError('synthetic read failure'),
      );
      final zip = await ZipDocumentAdapter.parseForTesting(
        sourceName: 'synthetic.zip',
        readBytes: () async => throw StateError('synthetic read failure'),
      );

      for (final document in <ParsedDocument>[markdown, txt, zip]) {
        expect(document.fallbackUsed, isTrue);
        expect(
          document.contentStatus,
          ParsedDocumentContentStatus.infrastructureFailure,
        );
      }
    });

    test('DOCX control flow distinguishes fallback success and dual failure',
        () async {
      var successfulReads = 0;
      final successfulFallback = await DocxDocumentAdapter.parseForTesting(
        sourceName: 'synthetic.docx',
        readBytes: () async {
          successfulReads++;
          if (successfulReads == 1) {
            throw StateError('synthetic primary failure');
          }
          return Uint8List.fromList(<int>[1]);
        },
        fallbackToText: (_) =>
            'Docx Parsing and Fallback Failed: legitimate formal content',
      );

      var failedReads = 0;
      final failedFallback = await DocxDocumentAdapter.parseForTesting(
        sourceName: 'synthetic.docx',
        readBytes: () async {
          failedReads++;
          if (failedReads == 1) {
            throw StateError('synthetic primary failure');
          }
          return Uint8List.fromList(<int>[1]);
        },
        fallbackToText: (_) => throw StateError('synthetic fallback failure'),
      );

      expect(successfulReads, 2);
      expect(successfulFallback.fallbackUsed, isTrue);
      expect(
        successfulFallback.contentStatus,
        ParsedDocumentContentStatus.usable,
      );
      expect(failedReads, 2);
      expect(failedFallback.fallbackUsed, isTrue);
      expect(
        failedFallback.contentStatus,
        ParsedDocumentContentStatus.infrastructureFailure,
      );
    });
  });
}
