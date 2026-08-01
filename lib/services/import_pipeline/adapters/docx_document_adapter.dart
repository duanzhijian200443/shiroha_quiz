import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:docx_to_text/docx_to_text.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../document_image_asset.dart';
import '../document_part.dart';
import '../document_signals.dart';
import '../import_format.dart';
import '../parsed_document.dart';
import '../document_text_signal_detector.dart';

class DocxDocumentAdapter {
  static Future<ParsedDocument> parse({
    required String filePath,
    required String sourceName,
  }) {
    return _parse(
      sourceName: sourceName,
      readBytes: () => File(filePath).readAsBytes(),
      fallbackToText: (bytes) => docxToText(bytes),
    );
  }

  @visibleForTesting
  static Future<ParsedDocument> parseForTesting({
    required String sourceName,
    required Future<Uint8List> Function() readBytes,
    required String Function(Uint8List) fallbackToText,
  }) {
    return _parse(
      sourceName: sourceName,
      readBytes: readBytes,
      fallbackToText: fallbackToText,
    );
  }

  static Future<ParsedDocument> _parse({
    required String sourceName,
    required Future<Uint8List> Function() readBytes,
    required String Function(Uint8List) fallbackToText,
  }) async {
    try {
      final bytes = await readBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // --- Phase 4-A: Extract word/media/* to temp dir ---
      final tempBase = Directory.systemTemp;
      final safeBase = sourceName.replaceAll(RegExp(r'[^\w.-]'), '_');
      final imgTempDir = Directory(p.join(tempBase.path,
          'shiroha_docx_${safeBase}_${DateTime.now().millisecondsSinceEpoch}'));
      await imgTempDir.create(recursive: true);

      final imageAssets = <DocumentImageAsset>[];
      final imageParts = <DocumentPart>[];
      int assetIdx = 0;

      for (final file in archive) {
        if (file.isFile && file.name.startsWith('word/media/')) {
          final basename = p.basename(file.name);
          final extractedFile = File(p.join(imgTempDir.path, basename));
          final imgBytes = file.content as List<int>;
          await extractedFile.writeAsBytes(imgBytes);

          final assetId = '${sourceName}_img_$assetIdx';
          final asset = DocumentImageAsset(
            id: assetId,
            order: assetIdx,
            sourceName: sourceName,
            originalPath: file.name,
            extractedPath: extractedFile.path,
            byteLength: imgBytes.length,
            isResolvable: true,
          );
          imageAssets.add(asset);
          imageParts.add(ImagePart(
            order: 0, // order will be re-assigned below; appended after text
            path: file.name,
            assetId: assetId,
            resolvedPath: extractedFile.path,
          ));
          assetIdx++;
        }
      }

      final documentXmlFile = archive.findFile('word/document.xml');
      if (documentXmlFile == null) {
        throw Exception('word/document.xml not found');
      }

      final documentXml = utf8.decode(documentXmlFile.content as List<int>,
          allowMalformed: true);

      final textParts = _parseDocumentXml(documentXml);
      int orderCounter = textParts.length;
      final allParts = <DocumentPart>[...textParts];
      for (final imgPart in imageParts) {
        final ip = imgPart as ImagePart;
        allParts.add(ImagePart(
          order: orderCounter++,
          path: ip.path,
          assetId: ip.assetId,
          resolvedPath: ip.resolvedPath,
        ));
      }

      final signals =
          _computeSignals(textParts, imageCount: imageAssets.length);

      final parsed = ParsedDocument(
        sourceName: sourceName,
        format: ImportFormat.docx,
        parts: allParts,
        signals: signals,
        contentStatus: ParsedDocumentContentStatus.usable,
        fallbackUsed: false,
        imageAssets: imageAssets,
      );
      if (imageAssets.isNotEmpty) {
        parsed.diagnostics['docxImagePlacement'] =
            'appended — Phase 4-A 未解析 relationship anchor，图片附于段落末尾';
        debugPrint(
            'DocxDocumentAdapter: Phase 4-A 提取 ${imageAssets.length} 张图片资产到 ${imgTempDir.path}');
      }
      return parsed;
    } catch (e) {
      // Fallback to docxToText if we crash
      debugPrint(
          'DocxDocumentAdapter: Parsing failed, falling back to docxToText. Phase 4-A image extraction failed: $e');
      String rawText = '';
      var contentStatus = ParsedDocumentContentStatus.infrastructureFailure;
      try {
        final bytes = await readBytes();
        rawText = fallbackToText(bytes);
        rawText = rawText
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n')
            .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
            .replaceAll(RegExp(r'\n{3,}'), '\n\n');
        contentStatus = ParsedDocumentContentStatus.usable;
      } catch (fallbackErr) {
        rawText = 'Docx Parsing and Fallback Failed: $e, $fallbackErr';
      }

      return ParsedDocument(
        sourceName: sourceName,
        format: ImportFormat.docx,
        parts: [TextPart(order: 0, text: rawText, role: TextRole.paragraph)],
        signals: const DocumentSignals(),
        contentStatus: contentStatus,
        fallbackUsed: true,
      )
        ..diagnostics['warning'] = 'Word文档 $sourceName 解析发生降级: $e'
        ..diagnostics['fallbackReason'] = e.toString();
    }
  }

  static List<DocumentPart> _parseDocumentXml(String xml) {
    final parts = <DocumentPart>[];
    int order = 0;

    int currentIndex = 0;
    while (currentIndex < xml.length) {
      int pIndex = xml.indexOf('<w:p', currentIndex);
      int tblIndex = xml.indexOf('<w:tbl', currentIndex);

      if (pIndex == -1 && tblIndex == -1) break;

      if (tblIndex != -1 && (pIndex == -1 || tblIndex < pIndex)) {
        // Parse table
        int tblEnd = xml.indexOf('</w:tbl>', tblIndex);
        if (tblEnd == -1) {
          currentIndex = tblIndex + 6;
          continue;
        }
        final tblXml = xml.substring(tblIndex, tblEnd + 8);
        final rows = _parseTableRows(tblXml);
        if (rows.isNotEmpty) {
          parts.add(TablePart(order: order++, rows: rows));
        }
        currentIndex = tblEnd + 8;
      } else if (pIndex != -1) {
        // Parse paragraph
        int pEnd = xml.indexOf('</w:p>', pIndex);
        if (pEnd == -1) {
          currentIndex = pIndex + 4;
          continue;
        }
        final pXml = xml.substring(pIndex, pEnd + 6);
        final text = _extractTextFromXml(pXml);
        if (text.trim().isNotEmpty) {
          final role = _determineTextRole(text);
          parts.add(TextPart(order: order++, text: text, role: role));
        }
        currentIndex = pEnd + 6;
      } else {
        break;
      }
    }

    return parts;
  }

  static List<List<String>> _parseTableRows(String tblXml) {
    final rows = <List<String>>[];
    int rIndex = 0;
    while (true) {
      int trStart = tblXml.indexOf('<w:tr', rIndex);
      if (trStart == -1) break;
      int trEnd = tblXml.indexOf('</w:tr>', trStart);
      if (trEnd == -1) break;

      final trXml = tblXml.substring(trStart, trEnd + 7);
      final cells = <String>[];
      int cIndex = 0;
      while (true) {
        int tcStart = trXml.indexOf('<w:tc', cIndex);
        if (tcStart == -1) break;
        int tcEnd = trXml.indexOf('</w:tc>', tcStart);
        if (tcEnd == -1) break;

        final tcXml = trXml.substring(tcStart, tcEnd + 7);
        cells.add(_extractTextFromXml(tcXml).trim());
        cIndex = tcEnd + 7;
      }
      if (cells.isNotEmpty) {
        rows.add(cells);
      }
      rIndex = trEnd + 7;
    }
    return rows;
  }

  static String _extractTextFromXml(String xmlNode) {
    final buffer = StringBuffer();

    final elementRegex = RegExp(
      r'<w:t(?:\s[^>]*?)?>(.*?)</w:t>|'
      r'<m:oMathPara(?:\s[^>]*?)?>(.*?)</m:oMathPara>|'
      r'<m:oMath(?:\s[^>]*?)?>(.*?)</m:oMath>|'
      r'<w:br(?:\s[^>]*?)?/?>|'
      r'<w:drawing(?:\s[^>]*?)?>|'
      r'<w:object(?:\s[^>]*?)?>|'
      r'<v:imagedata(?:\s[^>]*?)?>',
      dotAll: true,
    );

    final matches = elementRegex.allMatches(xmlNode);
    for (final match in matches) {
      if (match.group(1) != null) {
        // w:t
        buffer.write(match.group(1));
      } else if (match.group(2) != null) {
        // m:oMathPara
        final mathXml = match.group(2)!;
        final mathText = _extractAllTextNodes(mathXml).trim();
        buffer.write(mathText.isEmpty ? ' [FORMULA] ' : ' $mathText ');
      } else if (match.group(3) != null) {
        // m:oMath
        final mathXml = match.group(3)!;
        final mathText = _extractAllTextNodes(mathXml).trim();
        buffer.write(mathText.isEmpty ? ' [FORMULA] ' : ' $mathText ');
      } else {
        final matchedText = match.group(0) ?? '';
        if (matchedText.contains('w:br')) {
          buffer.write('\n');
        } else if (matchedText.contains('w:drawing') ||
            matchedText.contains('w:object') ||
            matchedText.contains('v:imagedata')) {
          buffer.write(' [IMAGE] ');
        }
      }
    }

    return buffer.toString();
  }

  static String _extractAllTextNodes(String xmlNode) {
    final buffer = StringBuffer();
    final matches =
        RegExp(r'<(w:t|m:t)(?:\s[^>]*?)?>([^<]*)</\1>').allMatches(xmlNode);
    for (final m in matches) {
      final text = m.group(2);
      if (text != null) {
        buffer.write(text);
      }
    }
    return buffer.toString();
  }

  static TextRole _determineTextRole(String text) {
    return DocumentTextSignalDetector.detectRole(text);
  }

  static DocumentSignals _computeSignals(List<DocumentPart> parts,
      {required int imageCount}) {
    int questionMarkerCount = 0;
    int answerMarkerCount = 0;
    int tableCount = 0;
    int formulaLikeCount = 0;
    bool hasTailAnswerBlock = false;

    for (final part in parts) {
      if (part is TablePart) {
        tableCount++;
      } else if (part is TextPart) {
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
      imageCount: imageCount,
      tableCount: tableCount,
      formulaLikeCount: formulaLikeCount,
      hasTailAnswerBlock: hasTailAnswerBlock ||
          (answerMarkerCount > 0 &&
              parts.isNotEmpty &&
              parts.last is TextPart &&
              (parts.last as TextPart).role == TextRole.answerBlock),
      hasInlineAnswers: false,
    );
  }
}
