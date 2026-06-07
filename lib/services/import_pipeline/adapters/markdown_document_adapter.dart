import 'dart:io';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;

import '../document_image_asset.dart';
import '../document_part.dart';
import '../document_signals.dart';
import '../import_format.dart';
import '../parsed_document.dart';
import '../document_text_signal_detector.dart';

class MarkdownDocumentAdapter {
  static Future<ParsedDocument> parse({
    required String filePath,
    required String sourceName,
  }) async {
    try {
      final content = await File(filePath).readAsString();
      final baseDir = p.dirname(filePath);
      int assetCounter = 0;
      final List<String> warnings = [];

      DocumentImageAsset? resolveImage(
          String imageRef, String? altText, int order) {
        if (imageRef.isEmpty) return null;
        // Skip absolute URLs / data URIs
        if (imageRef.startsWith('http') || imageRef.startsWith('data:')) {
          return null;
        }

        final canonicalBase = p.canonicalize(baseDir);
        final canonicalImg = p.canonicalize(p.join(baseDir, imageRef));
        final isWithinBase = p.isWithin(canonicalBase, canonicalImg);

        final isAbsoluteOrUNC = p.isAbsolute(imageRef) ||
            imageRef.startsWith('/') ||
            imageRef.startsWith('\\') ||
            imageRef.startsWith(RegExp(r'^[a-zA-Z]:'));

        if (isAbsoluteOrUNC || !isWithinBase) {
          warnings.add('拒绝解析超出目录边界的图片路径: $imageRef');
          final assetId = '${sourceName}_img_${assetCounter++}';
          return DocumentImageAsset(
            id: assetId,
            order: order,
            sourceName: sourceName,
            originalPath: imageRef,
            extractedPath: null,
            altText: altText,
            byteLength: null,
            isResolvable: false,
          );
        }

        final assetId = '${sourceName}_img_${assetCounter++}';
        final exists = File(canonicalImg).existsSync();
        return DocumentImageAsset(
          id: assetId,
          order: order,
          sourceName: sourceName,
          originalPath: imageRef,
          extractedPath: exists ? canonicalImg : null,
          altText: altText,
          byteLength: exists ? File(canonicalImg).lengthSync() : null,
          isResolvable: exists,
        );
      }

      final parsed = parseContent(
          content: content, sourceName: sourceName, resolveImage: resolveImage);
      if (warnings.isNotEmpty) {
        final existing = parsed.diagnostics['warnings'];
        if (existing is List) {
          existing.addAll(warnings);
        } else {
          parsed.diagnostics['warnings'] = warnings;
        }
      }
      return parsed;
    } catch (e) {
      return ParsedDocument(
        sourceName: sourceName,
        format: ImportFormat.md,
        parts: [
          TextPart(
              order: 0,
              text: 'Markdown Parsing Failed: $e',
              role: TextRole.paragraph)
        ],
        signals: const DocumentSignals(),
        fallbackUsed: true,
      )..diagnostics['warning'] = 'Markdown文件 $sourceName 解析崩溃: $e';
    }
  }

  static ParsedDocument parseContent({
    required String content,
    required String sourceName,
    DocumentImageAsset? Function(String path, String? altText, int order)?
        resolveImage,
  }) {
    if (content.trim().isEmpty) {
      return ParsedDocument(
        sourceName: sourceName,
        format: ImportFormat.md,
        parts: [],
        signals: const DocumentSignals(),
        fallbackUsed: true,
      )..diagnostics['warning'] = 'Markdown文件 $sourceName 内容为空。';
    }

    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );
    final nodes = document.parseLines(content.replaceAll('\r', '').split('\n'));

    final visitor = _MarkdownVisitor(resolveImage: resolveImage);
    for (final node in nodes) {
      node.accept(visitor);
    }

    final parts = visitor.parts;
    final collectedAssets = visitor.imageAssets;
    final signals = _computeSignals(parts, imageCount: visitor.imageCount);

    final parsed = ParsedDocument(
      sourceName: sourceName,
      format: ImportFormat.md,
      parts: parts,
      signals: signals,
      fallbackUsed: false,
      imageAssets: collectedAssets,
    );

    final textParts = parts.where((p) => p is TextPart || p is TablePart);
    if (textParts.isEmpty && visitor.imageCount > 0) {
      parsed.diagnostics['warning'] =
          'Markdown文件 $sourceName 仅包含图片引用。当前阶段仅占位图片，需 Phase 4 混合解析。';
    }

    final unresolvedImages =
        collectedAssets.where((a) => !a.isResolvable).toList();
    if (unresolvedImages.isNotEmpty) {
      parsed.diagnostics['unresolvedImages'] =
          unresolvedImages.map((a) => a.originalPath).toList();
    }

    return parsed;
  }

  static TextRole _determineTextRole(String text, String? tag) {
    return DocumentTextSignalDetector.detectRole(text, markdownTag: tag);
  }

  static DocumentSignals _computeSignals(List<DocumentPart> parts,
      {required int imageCount}) {
    int questionMarkerCount = 0;
    int answerMarkerCount = 0;
    int tableCount = 0;
    int formulaLikeCount = 0;

    for (final part in parts) {
      if (part is TablePart) {
        tableCount++;
      } else if (part is TextPart) {
        final text = part.text.trim();
        // Ignore formula/marker checks for code blocks to prevent false positives.
        if (part.role != TextRole.formulaLike) {
          if (DocumentTextSignalDetector.hasQuestionMarker(text)) {
            questionMarkerCount++;
          }
          // Count answer markers even if they appear as headings (### 答案 / ### 解析)
          if (part.role == TextRole.answerBlock ||
              (part.role == TextRole.heading &&
                  DocumentTextSignalDetector.hasAnswerMarker(text))) {
            answerMarkerCount++;
          }
          if (DocumentTextSignalDetector.hasFormulaLikeSignal(text)) {
            formulaLikeCount++;
          }
        }
      }
    }

    return DocumentSignals(
      questionMarkerCount: questionMarkerCount,
      answerMarkerCount: answerMarkerCount,
      imageCount: imageCount,
      tableCount: tableCount,
      formulaLikeCount: formulaLikeCount,
      hasTailAnswerBlock: answerMarkerCount > 0,
    );
  }
}

class _MarkdownVisitor implements md.NodeVisitor {
  final List<DocumentPart> parts = [];
  final List<DocumentImageAsset> imageAssets = [];
  final DocumentImageAsset? Function(String path, String? altText, int order)?
      resolveImage;
  int imageCount = 0;
  int _order = 0;
  String? _currentTag;

  _MarkdownVisitor({this.resolveImage});

  @override
  bool visitElementBefore(md.Element element) {
    _currentTag = element.tag;
    if (element.tag == 'img') {
      final src = element.attributes['src'] ?? '';
      final alt = element.attributes['alt'];
      imageCount++;
      final asset = resolveImage?.call(src, alt, _order);
      if (asset != null) {
        imageAssets.add(asset);
        parts.add(ImagePart(
            order: _order++,
            path: src,
            relationshipId: alt,
            assetId: asset.id,
            resolvedPath: asset.extractedPath,
            altText: alt));
      } else {
        parts.add(ImagePart(
            order: _order++, path: src, relationshipId: alt, altText: alt));
      }
      return false;
    }
    if (element.tag == 'pre') {
      // Code block. Extract text content.
      final text = element.textContent;
      parts.add(TextPart(
          order: _order++,
          text: text,
          role: TextRole
              .formulaLike)); // formulaLike acts as code block role here to skip regex checks
      return false;
    }
    if (element.tag == 'table') {
      // Very basic table extraction from AST
      final rows = <List<String>>[];
      _extractTableRows(element, rows);
      if (rows.isNotEmpty) {
        parts.add(TablePart(order: _order++, rows: rows));
      }
      return false;
    }
    return true;
  }

  @override
  void visitText(md.Text text) {
    final t = text.text.trim();
    if (t.isNotEmpty) {
      parts.add(TextPart(
          order: _order++,
          text: text.text,
          role: MarkdownDocumentAdapter._determineTextRole(t, _currentTag)));
    }
  }

  @override
  void visitElementAfter(md.Element element) {
    if (element.tag == _currentTag) {
      _currentTag = null;
    }
  }

  void _extractTableRows(md.Element table, List<List<String>> outRows) {
    for (final child in table.children ?? []) {
      if (child is md.Element) {
        if (child.tag == 'tr') {
          final row = <String>[];
          for (final cell in child.children ?? []) {
            if (cell is md.Element && (cell.tag == 'td' || cell.tag == 'th')) {
              row.add(cell.textContent.trim());
            }
          }
          if (row.isNotEmpty) {
            outRows.add(row);
          }
        } else if (child.tag == 'thead' || child.tag == 'tbody') {
          _extractTableRows(child, outRows);
        }
      }
    }
  }
}
