import '../../../application/content/content_asset_authority.dart';
import '../../../core/observability/app_logger.dart';
import '../../../domain/assets/asset_ref.dart';
import '../../../domain/content/content_node.dart';
import '../../../domain/content/rich_content.dart';
import '../../../domain/content/rich_content_privacy_admission.dart';
import '../../../domain/import/import_issue.dart';
import '../../../domain/source/source_document.dart';
import '../../../domain/source/source_part.dart';
import '../../../domain/source/source_ref.dart';
import '../ocr_document.dart';
import '../ocr_table_projection.dart';

final _ocrTypeControlPattern = RegExp(r'[\u0000-\u001f\u007f]');

final class OcrSourceDocumentAdapter {
  const OcrSourceDocumentAdapter({
    ContentAssetStore? assetStore,
    this.onAssetCreated,
  }) : _assetStore = assetStore;

  final ContentAssetStore? _assetStore;
  final void Function(String localAssetId)? onAssetCreated;

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
        SourceRef.document(sourceId: sourceId, displayLabel: displayLabel);
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

      final mapped = _mapBlock(
        block,
        sourceRef,
        _assetStore,
        onAssetCreated: onAssetCreated,
      );
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
      if (block.text.trim().isEmpty &&
          block.imagePayload == null &&
          !_isStructuralBlockType(block.type)) {
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

bool _isStructuralBlockType(String type) {
  final normalized = type.trim().toLowerCase();
  return normalized == 'image' ||
      normalized == 'figure' ||
      normalized == 'table';
}

SourceDocument _convertWithoutBlocks({
  required OcrDocument document,
  required SourceRef documentRef,
  required List<ImportIssue> issues,
}) {
  final markdown = document.markdown;
  if (markdown.trim().isNotEmpty) {
    return SourceDocument(
      sourceId: documentRef.sourceId,
      displayLabel: documentRef.displayLabel,
      parts: <SourcePart>[
        UnsupportedSourcePart(
          sourceRef: documentRef,
          kindCode: 'ocr_markdown_fallback',
          fallbackContent: _textContent(
            _safeStructuralFallback(markdown, '[不支持的内容]'),
          ),
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

  return SourceDocument(
    sourceId: documentRef.sourceId,
    displayLabel: documentRef.displayLabel,
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

({SourcePart part, bool structureUnsupported}) _mapBlock(
  OcrBlock block,
  SourceRef sourceRef,
  ContentAssetStore? assetStore, {
  void Function(String localAssetId)? onAssetCreated,
}) {
  final normalizedType = _normalizeType(block.type);
  return switch (normalizedType) {
    'text' || 'paragraph' => (
        part: SourceContentPart(
          sourceRef: sourceRef,
          content: _textContent(block.text),
          role: SourceContentRole.paragraph,
        ),
        structureUnsupported: false,
      ),
    'title' || 'heading' => (
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
    'table' => _mapTableBlock(block, sourceRef),
    'image' || 'figure' => _mapImageBlock(
        block,
        sourceRef,
        assetStore,
        onAssetCreated: onAssetCreated,
      ),
    _ => (
        part: UnsupportedSourcePart(
          sourceRef: sourceRef,
          kindCode: 'ocr_unknown',
          fallbackContent: _textContent(
            _safeStructuralFallback(block.text, '[不支持的内容]'),
          ),
        ),
        structureUnsupported: true,
      ),
  };
}

({SourcePart part, bool structureUnsupported}) _mapTableBlock(
  OcrBlock block,
  SourceRef sourceRef,
) {
  final projection = OcrTableProjector.analyzeHtmlTable(
    block.text,
    sourceRef: sourceRef,
  );
  final table = projection.table;
  if (table != null) {
    return (part: table, structureUnsupported: false);
  }
  final failureCategory = projection.failureCategory;
  if (failureCategory != null) {
    AppLogger.info(
      'OCR table projection classified',
      module: 'ImportPipeline',
      data: <String, Object?>{
        'stage': 'table_projection',
        'category': ocrTableProjectionFailureCategoryValue(failureCategory),
        'count': 1,
      },
    );
  }
  return (
    part: UnsupportedSourcePart(
      sourceRef: sourceRef,
      kindCode: 'ocr_table',
      fallbackContent: _textContent(
        OcrTableProjector.projectHtmlToPlainText(block.text) ??
            _safeStructuralFallback(block.text, '[表格]'),
      ),
    ),
    structureUnsupported: true,
  );
}

({SourcePart part, bool structureUnsupported}) _mapImageBlock(
  OcrBlock block,
  SourceRef sourceRef,
  ContentAssetStore? assetStore, {
  void Function(String localAssetId)? onAssetCreated,
}) {
  final payload = block.imagePayload ?? OcrImagePayload.fromDataUrl(block.text);
  final localAssetId = block.blockId;
  if (assetStore != null &&
      payload != null &&
      sourceRef.start?.blockId == localAssetId) {
    try {
      final stored = assetStore.storeBytesSync(
        sourceId: sourceRef.sourceId,
        localAssetId: localAssetId,
        bytes: payload.bytes,
        mimeType: payload.mimeType,
      );
      if (stored.created) onAssetCreated?.call(localAssetId);
      return (
        part: SourceAssetPart(
          sourceRef: sourceRef,
          asset: AssetRef(
            assetId: localAssetId,
            kind: AssetKind.image,
            mimeType: stored.mimeType,
          ),
        ),
        structureUnsupported: false,
      );
    } catch (_) {
      // An image that cannot be admitted is explicit unsupported structure;
      // the provider locator or bytes never enter the fallback content.
    }
  }
  return (
    part: UnsupportedSourcePart(
      sourceRef: sourceRef,
      kindCode: 'ocr_image',
      fallbackContent: _textContent(
        payload == null ? _safeStructuralFallback(block.text, '[图片]') : '[图片]',
      ),
    ),
    structureUnsupported: true,
  );
}

String _safeStructuralFallback(String value, String placeholder) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || _containsUnsafeLocator(trimmed)) {
    return placeholder;
  }
  return value;
}

bool _containsUnsafeLocator(String value) {
  return value.contains('<') ||
      RegExp(r'!?\[[^\]]*\]\([^)]*\)').hasMatch(value) ||
      RichContentPrivacyAdmission.isUnsafeFallbackString(value);
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
    SourcePoint.block(pageNumber: 1, blockId: blockId, readingOrder: 0);
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

int _compareIndexedBlocks(_IndexedOcrBlock left, _IndexedOcrBlock right) {
  final pageComparison = left.pageIndex.compareTo(right.pageIndex);
  if (pageComparison != 0) return pageComparison;
  final orderComparison = left.block.readingOrder.compareTo(
    right.block.readingOrder,
  );
  if (orderComparison != 0) return orderComparison;
  final pageEncounterComparison = left.pageEncounter.compareTo(
    right.pageEncounter,
  );
  if (pageEncounterComparison != 0) return pageEncounterComparison;
  return left.blockEncounter.compareTo(right.blockEncounter);
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
