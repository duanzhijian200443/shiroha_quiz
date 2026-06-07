import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../document_image_asset.dart';
import '../document_part.dart';
import '../document_signals.dart';
import '../import_format.dart';
import '../parsed_document.dart';
import 'markdown_document_adapter.dart';
import 'txt_document_adapter.dart';

class ZipDocumentAdapter {
  static Future<ParsedDocument> parse({
    required String filePath,
    required String sourceName,
  }) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final List<String> warnings = [];
      final filesMap = <String, ArchiveFile>{};

      for (final file in archive) {
        if (file.isFile) {
          if (_isIgnored(file.name)) continue;
          if (_isUnsafePath(file.name)) {
            if (_isImagePath(file.name)) {
              warnings.add('拒绝解析具有潜在路径穿透风险的非法路径图片: ${file.name}');
            } else {
              warnings.add('拒绝解析具有潜在路径穿透风险的非法路径文件: ${file.name}');
            }
            continue;
          }
          filesMap[file.name] = file;
        }
      }

      final parts = <DocumentPart>[];
      final Map<String, dynamic> diagnostics = {};
      int order = 0;

      // --- Phase 4-A: Extract images to temp dir ---
      final tempBase = Directory.systemTemp;
      final safeBase = sourceName.replaceAll(RegExp(r'[^\w.-]'), '_');
      final imgTempDir = Directory(p.join(tempBase.path,
          'shiroha_zip_${safeBase}_${DateTime.now().millisecondsSinceEpoch}'));
      await imgTempDir.create(recursive: true);

      final availableImageAssets = <String, DocumentImageAsset>{};
      int assetIdx = 0;

      for (final archiveFile in filesMap.values) {
        if (_isImagePath(archiveFile.name)) {
          final rawSafeName = _safeExtractName(archiveFile.name);
          if (rawSafeName == null) {
            warnings.add('跳过非法路径图片: ${archiveFile.name}');
            continue;
          }
          final safeName = '${assetIdx}_$rawSafeName';
          final extractedFile = File(p.join(imgTempDir.path, safeName));
          final imgBytes = archiveFile.content as List<int>;
          await extractedFile.writeAsBytes(imgBytes);

          final assetId = '${sourceName}_img_$assetIdx';
          final asset = DocumentImageAsset(
            id: assetId,
            order: assetIdx,
            sourceName: sourceName,
            originalPath: archiveFile.name,
            extractedPath: extractedFile.path,
            byteLength: imgBytes.length,
            isResolvable: true,
          );
          availableImageAssets[archiveFile.name] = asset;
          assetIdx++;
        }
      }

      final textFiles = filesMap.values.where((f) {
        final lowerName = f.name.toLowerCase();
        return lowerName.endsWith('.md') ||
            lowerName.endsWith('.markdown') ||
            lowerName.endsWith('.txt');
      }).toList();

      // Sort text files alphabetically by normalized path to maintain stable ordering
      textFiles.sort((a, b) {
        final normA = p.posix.normalize(a.name.toLowerCase());
        final normB = p.posix.normalize(b.name.toLowerCase());
        return normA.compareTo(normB);
      });

      if (textFiles.isEmpty && availableImageAssets.isNotEmpty) {
        warnings.add('Zip 包内仅包含图片没有文本。当前阶段仅占位图片，需要 Vision 视觉解析。');
      } else if (textFiles.isEmpty) {
        warnings.add('Zip 包内未找到任何支持的文本文件或图片。');
      }

      // Track which images were actually referenced in markdown
      final referencedAssetIds = <String>{};
      final imageAssetsList = <DocumentImageAsset>[];
      var combinedSignals = const DocumentSignals();

      for (final file in textFiles) {
        final lowerName = file.name.toLowerCase();
        ParsedDocument doc;

        parts.add(TextPart(
            order: order++,
            text: '\n--- Source: ${file.name} ---\n',
            role: TextRole.paragraph));

        final data = file.content as List<int>;

        if (lowerName.endsWith('.md') || lowerName.endsWith('.markdown')) {
          final contentUtf8 = _decodeUtf8Safe(data);
          doc = MarkdownDocumentAdapter.parseContent(
            content: contentUtf8,
            sourceName: file.name,
            resolveImage: (imageRef, altText, subOrder) {
              final resolvedKey = _resolveMarkdownImagePath(
                  markdownPath: file.name,
                  imageRef: imageRef,
                  availableImages: availableImageAssets.keys.toSet());

              if (resolvedKey != null) {
                final asset = availableImageAssets[resolvedKey]!;
                referencedAssetIds.add(asset.id);
                // We return a clone with updated altText if needed
                final usedAsset = DocumentImageAsset(
                  id: asset.id,
                  order: asset.order,
                  sourceName: asset.sourceName,
                  originalPath: asset.originalPath,
                  extractedPath: asset.extractedPath,
                  altText: altText,
                  byteLength: asset.byteLength,
                  isResolvable: true,
                );
                if (!imageAssetsList.any((a) => a.id == usedAsset.id)) {
                  imageAssetsList.add(usedAsset);
                }
                return usedAsset;
              }
              return null; // unresolved
            },
          );
        } else {
          final contentUtf8 = _decodeUtf8Safe(data);
          doc = TxtDocumentAdapter.parseContent(
              content: contentUtf8, sourceName: file.name);
        }

        for (final p in doc.parts) {
          if (p is TextPart) {
            parts.add(TextPart(order: order++, text: p.text, role: p.role));
          } else if (p is TablePart) {
            parts.add(TablePart(order: order++, rows: p.rows));
          } else if (p is ImagePart) {
            parts.add(ImagePart(
              order: order++,
              path: p.path,
              relationshipId: p.relationshipId,
              assetId: p.assetId,
              resolvedPath: p.resolvedPath,
              altText: p.altText,
            ));
          }
        }

        combinedSignals = combinedSignals + doc.signals;
        diagnostics[file.name] = doc.toDiagnostics();
      }

      // Add unreferenced images as parts at the end
      final unreferencedImages = <String>[];
      for (final entry in availableImageAssets.entries) {
        final asset = entry.value;
        if (!referencedAssetIds.contains(asset.id)) {
          imageAssetsList.add(asset);
          unreferencedImages.add(asset.originalPath);
          parts.add(ImagePart(
            order: order++,
            path: asset.originalPath,
            assetId: asset.id,
            resolvedPath: asset.extractedPath,
          ));
        }
      }

      if (unreferencedImages.isNotEmpty) {
        diagnostics['unreferencedImages'] = unreferencedImages;
      }

      if (warnings.isNotEmpty) {
        diagnostics['warnings'] = warnings;
      }

      // Overwrite total image count properly
      combinedSignals = DocumentSignals(
        questionMarkerCount: combinedSignals.questionMarkerCount,
        answerMarkerCount: combinedSignals.answerMarkerCount,
        imageCount: availableImageAssets.length,
        tableCount: combinedSignals.tableCount,
        formulaLikeCount: combinedSignals.formulaLikeCount,
        hasTailAnswerBlock: combinedSignals.hasTailAnswerBlock,
      );

      return ParsedDocument(
        sourceName: sourceName,
        format: ImportFormat.zip,
        parts: parts,
        signals: combinedSignals,
        fallbackUsed: false,
        diagnostics: diagnostics,
        imageAssets: imageAssetsList,
      );
    } catch (e) {
      return ParsedDocument(
        sourceName: sourceName,
        format: ImportFormat.zip,
        parts: [
          TextPart(
              order: 0,
              text: 'Zip Parsing Failed: $e',
              role: TextRole.paragraph)
        ],
        signals: const DocumentSignals(),
        fallbackUsed: true,
      )..diagnostics['warning'] = 'Zip包 $sourceName 解析崩溃: $e';
    }
  }

  static bool _isIgnored(String path) {
    final normalized = p.posix.normalize(path.replaceAll('\\', '/'));
    if (normalized.split('/').contains('__MACOSX')) return true;
    final basename = p.posix.basename(normalized);
    if (basename == '.DS_Store' || basename == 'Thumbs.db') return true;
    return false;
  }

  static bool _isUnsafePath(String path) {
    final normalized = p.posix.normalize(path.replaceAll('\\', '/'));
    if (normalized.contains('..') ||
        normalized.startsWith('/') ||
        normalized.startsWith(RegExp(r'^[a-zA-Z]:')) ||
        normalized.isEmpty) {
      return true;
    }
    return false;
  }

  static bool _isImagePath(String path) {
    final lowerName = path.toLowerCase();
    return lowerName.endsWith('.png') ||
        lowerName.endsWith('.jpg') ||
        lowerName.endsWith('.jpeg') ||
        lowerName.endsWith('.webp');
  }

  static String _normalizeArchivePath(String path) {
    return p.posix.normalize(path);
  }

  static String? _safeExtractName(String archivePath) {
    if (_isUnsafePath(archivePath)) {
      return null;
    }
    return p.posix
        .normalize(archivePath.replaceAll('\\', '/'))
        .replaceAll('/', '_');
  }

  static String? _resolveMarkdownImagePath({
    required String markdownPath,
    required String imageRef,
    required Set<String> availableImages,
  }) {
    if (imageRef.isEmpty) return null;

    final normRef = _normalizeArchivePath(imageRef);
    final normMd = _normalizeArchivePath(markdownPath);

    // 1. Exact match
    if (availableImages.contains(normRef)) return normRef;

    // 2. Relative to markdown file
    final mdDir = p.posix.dirname(normMd);
    final relativeMatch =
        mdDir == '.' ? normRef : p.posix.normalize('$mdDir/$normRef');
    if (availableImages.contains(relativeMatch)) return relativeMatch;

    // 3. Basename match fallback (if unique)
    final refBasename = p.posix.basename(normRef);
    final matches = availableImages
        .where((a) => p.posix.basename(a) == refBasename)
        .toList();
    if (matches.length == 1) return matches.first;

    return null;
  }

  static String _decodeUtf8Safe(List<int> data) {
    if (data.length >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF) {
      return utf8.decode(data.sublist(3), allowMalformed: true);
    }
    return utf8.decode(data, allowMalformed: true);
  }
}
