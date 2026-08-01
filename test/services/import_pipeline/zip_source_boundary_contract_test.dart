import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/zip_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_part.dart';
import 'package:shiroha_quiz/services/import_pipeline/document_signals.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/parsed_document.dart';

void main() {
  test('typed ZIP boundary preserves legacy plain-text output and order', () {
    final boundary = ZipDocumentAdapter.sourceBoundaryForTesting(
      order: 7,
      sourceName: 'synthetic.md',
    );
    const body = TextPart(
      order: 8,
      text: 'formal body',
      role: TextRole.paragraph,
    );
    final typedDocument = ParsedDocument(
      sourceName: 'synthetic.zip',
      format: ImportFormat.zip,
      parts: <DocumentPart>[boundary, body],
      signals: const DocumentSignals(),
      contentStatus: ParsedDocumentContentStatus.usable,
    );
    final legacyDocument = ParsedDocument(
      sourceName: 'synthetic.zip',
      format: ImportFormat.zip,
      parts: const <DocumentPart>[
        TextPart(
          order: 7,
          text: '\n--- Source: synthetic.md ---\n',
          role: TextRole.paragraph,
        ),
        body,
      ],
      signals: const DocumentSignals(),
      contentStatus: ParsedDocumentContentStatus.usable,
    );

    expect(boundary, isA<GeneratedSourceBoundaryPart>());
    expect(boundary, isA<TextPart>());
    expect(boundary.order, 7);
    expect(boundary.role, TextRole.paragraph);
    expect(boundary.text, '\n--- Source: synthetic.md ---\n');
    expect(typedDocument.parts.map((part) => part.order), <int>[7, 8]);
    expect(
      typedDocument.toPlainTextForParsing(),
      '\n--- Source: synthetic.md ---\n\nformal body\n',
    );
    expect(
      typedDocument.toPlainTextForParsing(),
      legacyDocument.toPlainTextForParsing(),
    );
  });
}
