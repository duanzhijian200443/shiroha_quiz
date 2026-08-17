import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../../domain/assets/asset_ref.dart';
import '../../../domain/content/content_node.dart';
import '../../../domain/content/rich_content.dart';
import '../../../domain/import/import_issue.dart';
import '../../../domain/source/source_document.dart';
import '../../../domain/source/source_part.dart';
import '../../../domain/source/source_ref.dart';
import '../../backup/sha256.dart';
import '../../file_library/managed_content_asset_store.dart';
import '../ocr_document.dart';

final _ocrTypeControlPattern = RegExp(r'[\u0000-\u001f\u007f]');

final class OcrSourceDocumentAdapter {
  const OcrSourceDocumentAdapter({ContentAssetStore? assetStore})
      : _assetStore = assetStore;

  final ContentAssetStore? _assetStore;

  SourceDocument convert(
    OcrDocument document, {
    required String sourceId,
    String? displayLabel,
  }) {
    final identityRef = SourceRef.document(sourceId: sourceId);
    var safeDisplayLabel = displayLabel;
    final issues = <ImportIssue>[];

    if (displayLabel != null) {
      try {
        SourceRef.document(
          sourceId: sourceId,
          displayLabel: displayLabel,
        );
      } on FormatException {
        safeDisplayLabel = null;
        issues.add(
          _issue(
            code: 'ocr_display_label_invalid',
            severity: ImportIssueSeverity.info,
            sourceRef: identityRef,
          ),
        );
      }
    }

    final documentRef = safeDisplayLabel == null
        ? identityRef
        : SourceRef.document(
            sourceId: sourceId,
            displayLabel: safeDisplayLabel,
          );
    final indexedBlocks = _usableBlocks(document);

    if (indexedBlocks.isEmpty) {
      return _convertWithoutBlocks(
        document: document,
        documentRef: documentRef,
        issues: issues,
      );
    }

    final validBlockIdCounts = <String, int>{};
    for (final indexed in indexedBlocks) {
      final blockId = indexed.block.blockId;
      if (_isValidBlockId(blockId)) {
        validBlockIdCounts[blockId] = (validBlockIdCounts[blockId] ?? 0) + 1;
      }
    }

    indexedBlocks.sort(_compareIndexedBlocks);
    final assetStore =
        _assetStore ?? DefaultContentAssetResolver.instance.activeStore;
    final parts = <SourcePart>[];
    for (final indexed in indexedBlocks) {
      final block = indexed.block;
      final validBlockId = _isValidBlockId(block.blockId);
      final invalidLocation = indexed.pageIndex <= 0 ||
          block.pageIndex <= 0 ||
          !validBlockId ||
          block.readingOrder < 0;
      final pageMismatch = block.pageIndex != indexed.pageIndex;
      final duplicateBlockId =
          validBlockId && validBlockIdCounts[block.blockId]! > 1;
      final sourceRef = invalidLocation || pageMismatch || duplicateBlockId
          ? _fallbackRef(documentRef, indexed.pageIndex)
          : SourceRef.at(
              sourceId: documentRef.sourceId,
              displayLabel: documentRef.displayLabel,
              point: SourcePoint.block(
                pageNumber: indexed.pageIndex,
                blockId: block.blockId,
                readingOrder: block.readingOrder,
              ),
            );

      if (invalidLocation) {
        issues.add(
          _issue(
            code: 'ocr_location_invalid',
            severity: ImportIssueSeverity.warning,
            sourceRef: sourceRef,
          ),
        );
      }
      if (pageMismatch) {
        issues.add(
          _issue(
            code: 'ocr_page_mismatch',
            severity: ImportIssueSeverity.warning,
            sourceRef: sourceRef,
          ),
        );
      }
      if (duplicateBlockId) {
        issues.add(
          _issue(
            code: 'ocr_block_identity_duplicate',
            severity: ImportIssueSeverity.warning,
            sourceRef: sourceRef,
          ),
        );
      }

      final mapped = _mapBlock(block, sourceRef, assetStore);
      parts.add(mapped.part);
      if (mapped.structureUnsupported) {
        issues.add(
          _issue(
            code: 'ocr_structure_unsupported',
            severity: ImportIssueSeverity.warning,
            sourceRef: sourceRef,
          ),
        );
      }
    }

    return SourceDocument(
      sourceId: documentRef.sourceId,
      displayLabel: documentRef.displayLabel,
      parts: parts,
      issues: issues,
    );
  }
}

List<_IndexedOcrBlock> _usableBlocks(OcrDocument document) {
  final indexedBlocks = <_IndexedOcrBlock>[];
  for (var pageEncounter = 0;
      pageEncounter < document.pages.length;
      pageEncounter++) {
    final page = document.pages[pageEncounter];
    for (var blockEncounter = 0;
        blockEncounter < page.blocks.length;
        blockEncounter++) {
      final block = page.blocks[blockEncounter];
      if (block.text.trim().isEmpty) {
        continue;
      }
      indexedBlocks.add(
        _IndexedOcrBlock(
          block: block,
          pageIndex: page.pageIndex,
          pageEncounter: pageEncounter,
          blockEncounter: blockEncounter,
        ),
      );
    }
  }
  return indexedBlocks;
}

int _compareIndexedBlocks(_IndexedOcrBlock left, _IndexedOcrBlock right) {
  final pageComparison = left.pageIndex.compareTo(right.pageIndex);
  if (pageComparison != 0) return pageComparison;

  final readingOrderComparison =
      left.block.readingOrder.compareTo(right.block.readingOrder);
  if (readingOrderComparison != 0) return readingOrderComparison;

  final pageEncounterComparison =
      left.pageEncounter.compareTo(right.pageEncounter);
  if (pageEncounterComparison != 0) return pageEncounterComparison;

  return left.blockEncounter.compareTo(right.blockEncounter);
}

SourceDocument _convertWithoutBlocks({
  required OcrDocument document,
  required SourceRef documentRef,
  required List<ImportIssue> issues,
}) {
  if (document.markdown.trim().isEmpty) {
    return SourceDocument(
      sourceId: documentRef.sourceId,
      displayLabel: documentRef.displayLabel,
      parts: const <SourcePart>[],
      issues: <ImportIssue>[
        ...issues,
        _issue(
          code: 'ocr_content_empty',
          severity: ImportIssueSeverity.error,
          sourceRef: documentRef,
        ),
      ],
    );
  }
  return SourceDocument(
    sourceId: documentRef.sourceId,
    displayLabel: documentRef.displayLabel,
    parts: <SourcePart>[
      UnsupportedSourcePart(
        sourceRef: documentRef,
        kindCode: 'ocr_markdown_fallback',
        fallbackContent: _textContent(document.markdown),
      ),
    ],
    issues: <ImportIssue>[
      ...issues,
      _issue(
        code: 'ocr_markdown_fallback',
        severity: ImportIssueSeverity.warning,
        sourceRef: documentRef,
      ),
    ],
  );
}

({SourcePart part, bool structureUnsupported}) _mapBlock(
  OcrBlock block,
  SourceRef sourceRef,
  ContentAssetStore? assetStore,
) {
  final normalizedType = _normalizeType(block.type);
  return switch (normalizedType) {
    'paragraph' || 'text' => (
        part: SourceContentPart(
          sourceRef: sourceRef,
          content: _textContent(block.text),
          role: SourceContentRole.paragraph,
        ),
        structureUnsupported: false,
      ),
    'title' || 'heading' || 'header' => (
        part: SourceContentPart(
          sourceRef: sourceRef,
          content: _textContent(block.text),
          role: SourceContentRole.heading,
        ),
        structureUnsupported: false,
      ),
    'formula' || 'equation' => (
        part: SourceContentPart(
          sourceRef: sourceRef,
          content: _textContent(block.text),
          role: SourceContentRole.formula,
        ),
        structureUnsupported: false,
      ),
    'table' => (
        part: UnsupportedSourcePart(
          sourceRef: sourceRef,
          kindCode: 'ocr_table',
          fallbackContent: _textContent(block.text),
        ),
        structureUnsupported: true,
      ),
    'image' || 'figure' => _mapImageBlock(block, sourceRef, assetStore),
    _ => (
        part: UnsupportedSourcePart(
          sourceRef: sourceRef,
          kindCode: 'ocr_unknown',
          fallbackContent: _textContent(block.text),
        ),
        structureUnsupported: true,
      ),
  };
}

({SourcePart part, bool structureUnsupported}) _mapImageBlock(
  OcrBlock block,
  SourceRef sourceRef,
  ContentAssetStore? assetStore,
) {
  final text = block.text.trim();
  if (text.isEmpty) {
    return (
      part: UnsupportedSourcePart(
        sourceRef: sourceRef,
        kindCode: 'ocr_image',
        fallbackContent: _textContent(block.text),
      ),
      structureUnsupported: true,
    );
  }

  final isDataUrl = text.startsWith('data:image/');
  final isExistingAsset = text.startsWith('content_assets/');

  if (!isDataUrl && !isExistingAsset) {
    return (
      part: UnsupportedSourcePart(
        sourceRef: sourceRef,
        kindCode: 'ocr_image',
        fallbackContent: _textContent(block.text),
      ),
      structureUnsupported: true,
    );
  }

  try {
    String assetId;
    if (isDataUrl) {
      if (assetStore != null) {
        final key = assetStore.storeDataUrlSync(text);
        assetId = p.basename(key);
      } else {
        final commaIndex = text.indexOf(',');
        if (commaIndex == -1) throw const FormatException('Invalid Data URL');
        final bytes = base64Decode(
          text.substring(commaIndex + 1).replaceAll(RegExp(r'\s+'), ''),
        );
        if (bytes.isEmpty) throw const FormatException('Empty image bytes');
        final digest = sha256Hex(bytes);
        assetId = '$digest.png';
      }
    } else {
      assetId = p.basename(text);
    }

    return (
      part: SourceAssetPart(
        sourceRef: sourceRef,
        asset: AssetRef(
          assetId: assetId,
          kind: AssetKind.image,
        ),
        alternativeText: null,
      ),
      structureUnsupported: false,
    );
  } catch (_) {
    return (
      part: UnsupportedSourcePart(
        sourceRef: sourceRef,
        kindCode: 'ocr_image_invalid',
        fallbackContent: _textContent(block.text),
      ),
      structureUnsupported: true,
    );
  }
}

String? _normalizeType(String value) {
  if (value.length > 64 || _ocrTypeControlPattern.hasMatch(value)) {
    return null;
  }
  final normalized = value.trim().toLowerCase();
  return normalized.isEmpty ? null : normalized;
}

bool _isValidBlockId(String blockId) {
  try {
    SourcePoint.block(
      pageNumber: 1,
      blockId: blockId,
      readingOrder: 0,
    );
    return true;
  } on FormatException {
    return false;
  }
}

SourceRef _fallbackRef(SourceRef documentRef, int pageIndex) {
  if (pageIndex <= 0) return documentRef;
  return SourceRef.at(
    sourceId: documentRef.sourceId,
    displayLabel: documentRef.displayLabel,
    point: SourcePoint.page(pageNumber: pageIndex),
  );
}

RichContent _textContent(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

ImportIssue _issue({
  required String code,
  required ImportIssueSeverity severity,
  required SourceRef sourceRef,
}) {
  return ImportIssue(
    code: code,
    severity: severity,
    field: ImportIssueField.source,
    sourceRef: sourceRef,
  );
}

final class _IndexedOcrBlock {
  const _IndexedOcrBlock({
    required this.block,
    required this.pageIndex,
    required this.pageEncounter,
    required this.blockEncounter,
  });

  final OcrBlock block;
  final int pageIndex;
  final int pageEncounter;
  final int blockEncounter;
}
