import 'dart:convert';
import 'dart:io';

import '../document_part.dart';
import '../document_signals.dart';
import '../import_format.dart';
import '../parsed_document.dart';
import '../document_text_signal_detector.dart';

class TxtDocumentAdapter {
  static Future<ParsedDocument> parse({
    required String filePath,
    required String sourceName,
  }) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      // Handle UTF-8 with optional BOM
      String content;
      if (bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF) {
        content = utf8.decode(bytes.sublist(3), allowMalformed: true);
      } else {
        content = utf8.decode(bytes, allowMalformed: true);
      }
      return parseContent(content: content, sourceName: sourceName);
    } catch (e) {
      return ParsedDocument(
        sourceName: sourceName,
        format: ImportFormat.txt,
        parts: [
          TextPart(
              order: 0,
              text: 'TXT Parsing Failed: $e',
              role: TextRole.paragraph)
        ],
        signals: const DocumentSignals(),
        fallbackUsed: true,
      )..diagnostics['warning'] = '文本文件 $sourceName 解析崩溃: $e';
    }
  }

  static ParsedDocument parseContent({
    required String content,
    required String sourceName,
  }) {
    // Normalize CRLF to LF
    content = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    if (content.trim().isEmpty) {
      return ParsedDocument(
        sourceName: sourceName,
        format: ImportFormat.txt,
        parts: [],
        signals: const DocumentSignals(),
        fallbackUsed: true,
      )..diagnostics['warning'] = '文本文件 $sourceName 内容为空。';
    }

    final parts = <DocumentPart>[];
    final paragraphs = content.split(RegExp(r'\n{2,}'));
    int order = 0;

    for (final p in paragraphs) {
      final text = p.trim();
      if (text.isNotEmpty) {
        final role = DocumentTextSignalDetector.detectRole(text);
        parts.add(TextPart(order: order++, text: text, role: role));
      }
    }

    final signals = _computeSignals(parts);

    return ParsedDocument(
      sourceName: sourceName,
      format: ImportFormat.txt,
      parts: parts,
      signals: signals,
      fallbackUsed: false,
    );
  }

  static DocumentSignals _computeSignals(List<DocumentPart> parts) {
    int questionMarkerCount = 0;
    int answerMarkerCount = 0;
    int formulaLikeCount = 0;
    bool hasTailAnswerBlock = false;

    for (final part in parts) {
      if (part is TextPart) {
        final text = part.text.trim();
        if (DocumentTextSignalDetector.hasQuestionMarker(text)) {
          questionMarkerCount++;
        }
        if (DocumentTextSignalDetector.hasAnswerMarker(text)) {
          answerMarkerCount++;
        }
        if (DocumentTextSignalDetector.hasFormulaLikeSignal(text)) {
          formulaLikeCount++;
        }
        if (DocumentTextSignalDetector.looksLikeTailAnswerBlock(text)) {
          hasTailAnswerBlock = true;
        }
      }
    }

    return DocumentSignals(
      questionMarkerCount: questionMarkerCount,
      answerMarkerCount: answerMarkerCount,
      formulaLikeCount: formulaLikeCount,
      hasTailAnswerBlock: hasTailAnswerBlock ||
          (answerMarkerCount > 0 &&
              parts.isNotEmpty &&
              parts.last is TextPart &&
              (parts.last as TextPart).role == TextRole.answerBlock),
    );
  }
}
