import '../../../domain/assets/asset_ref.dart';
import '../../../domain/content/content_node.dart';
import '../../../domain/content/rich_content.dart';
import '../../../domain/content/rich_content_limits.dart';
import '../../../domain/import/import_issue.dart';
import '../../../domain/source/source_document.dart';
import '../../../domain/source/source_part.dart';
import '../../../domain/source/source_ref.dart';
import '../document_image_asset.dart';
import '../document_part.dart';
import '../parsed_document.dart';

const _imageFallbackText = '[Image]';
const _sourceBoundaryFallbackText = '[Source]';

const _issueSpecs = <_IssueSpec>[
  _IssueSpec(
    code: 'parsed_display_label_invalid',
    severity: ImportIssueSeverity.info,
    field: ImportIssueField.source,
  ),
  _IssueSpec(
    code: 'parsed_fallback_used',
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.source,
  ),
  _IssueSpec(
    code: 'parsed_failure_content_redacted',
    severity: ImportIssueSeverity.error,
    field: ImportIssueField.source,
  ),
  _IssueSpec(
    code: 'parsed_source_boundary_redacted',
    severity: ImportIssueSeverity.info,
    field: ImportIssueField.source,
  ),
  _IssueSpec(
    code: 'parsed_order_invalid',
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.source,
  ),
  _IssueSpec(
    code: 'parsed_order_duplicate',
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.source,
  ),
  _IssueSpec(
    code: 'parsed_asset_identity_invalid',
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.asset,
  ),
  _IssueSpec(
    code: 'parsed_asset_missing',
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.asset,
  ),
  _IssueSpec(
    code: 'parsed_asset_unresolved',
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.asset,
  ),
  _IssueSpec(
    code: 'parsed_asset_orphaned',
    severity: ImportIssueSeverity.info,
    field: ImportIssueField.asset,
  ),
  _IssueSpec(
    code: 'parsed_asset_metadata_conflict',
    severity: ImportIssueSeverity.warning,
    field: ImportIssueField.asset,
  ),
  _IssueSpec(
    code: 'parsed_content_empty',
    severity: ImportIssueSeverity.error,
    field: ImportIssueField.source,
  ),
];

final class ParsedSourceDocumentAdapter {
  const ParsedSourceDocumentAdapter();

  SourceDocument convert(
    ParsedDocument document, {
    required String sourceId,
    String? displayLabel,
  }) {
    final identityRef = SourceRef.document(sourceId: sourceId);
    final issueCodes = <String>{};
    var safeDisplayLabel = displayLabel;

    if (displayLabel != null) {
      try {
        SourceRef.document(
          sourceId: sourceId,
          displayLabel: displayLabel,
        );
      } on FormatException {
        safeDisplayLabel = null;
        issueCodes.add('parsed_display_label_invalid');
      }
    }

    final documentRef = safeDisplayLabel == null
        ? identityRef
        : SourceRef.document(
            sourceId: sourceId,
            displayLabel: safeDisplayLabel,
          );

    if (document.fallbackUsed) {
      issueCodes.add('parsed_fallback_used');
    }
    if (document.contentStatus ==
        ParsedDocumentContentStatus.infrastructureFailure) {
      issueCodes.add('parsed_failure_content_redacted');
      issueCodes.add('parsed_content_empty');
      return _buildSourceDocument(
        documentRef: documentRef,
        parts: const <SourcePart>[],
        issueCodes: issueCodes,
      );
    }

    _collectOrderIssues(document.parts, issueCodes);

    final assetsByProducerKey = <String, AssetRef>{};
    var nextAssetOrdinal = 1;
    for (final part in document.parts) {
      if (part is! ImagePart) continue;
      final producerKey = part.assetId;
      if (producerKey == null || producerKey.isEmpty) continue;
      assetsByProducerKey.putIfAbsent(
        producerKey,
        () => AssetRef(
          assetId: _safeDomainAssetId(nextAssetOrdinal++),
          kind: AssetKind.image,
        ),
      );
    }

    final metadataByProducerKey = <String, List<DocumentImageAsset>>{};
    for (final metadata in document.imageAssets) {
      final producerKey = metadata.id;
      if (producerKey.isEmpty) {
        issueCodes.add('parsed_asset_identity_invalid');
        continue;
      }
      metadataByProducerKey
          .putIfAbsent(producerKey, () => <DocumentImageAsset>[])
          .add(metadata);
    }

    for (final entry in metadataByProducerKey.entries) {
      if (entry.value.length != 1) {
        issueCodes.add('parsed_asset_metadata_conflict');
      }
      if (!assetsByProducerKey.containsKey(entry.key)) {
        issueCodes.add('parsed_asset_orphaned');
      }
    }

    final parts = <SourcePart>[];
    var hasFormalContent = false;

    for (final part in document.parts) {
      switch (part) {
        case GeneratedSourceBoundaryPart():
          parts.add(
            UnsupportedSourcePart(
              sourceRef: documentRef,
              kindCode: 'parsed_source_boundary',
              fallbackContent: _textContent(_sourceBoundaryFallbackText),
            ),
          );
          issueCodes.add('parsed_source_boundary_redacted');
        case TextPart(:final text, :final role):
          final partRole = _mapTextRole(role);
          for (final chunk in _boundedTextChunks(text)) {
            parts.add(
              SourceContentPart(
                sourceRef: documentRef,
                content: _textContent(chunk),
                role: partRole,
              ),
            );
          }
          if (text.trim().isNotEmpty) {
            hasFormalContent = true;
          }
        case TablePart(:final rows):
          parts.add(
            SourceTablePart(
              sourceRef: documentRef,
              rows: <List<RichContent>>[
                for (final row in rows)
                  <RichContent>[
                    for (final cell in row) _textContent(cell),
                  ],
              ],
            ),
          );
          if (rows.any(
            (row) => row.any((cell) => cell.trim().isNotEmpty),
          )) {
            hasFormalContent = true;
          }
        case ImagePart():
          final mapped = _mapImagePart(
            part: part,
            sourceRef: documentRef,
            assetByProducerKey: assetsByProducerKey,
            metadataByProducerKey: metadataByProducerKey,
            issueCodes: issueCodes,
          );
          parts.add(mapped);
          hasFormalContent = true;
      }
    }

    if (!hasFormalContent) {
      issueCodes.add('parsed_content_empty');
    }

    return _buildSourceDocument(
      documentRef: documentRef,
      parts: parts,
      issueCodes: issueCodes,
    );
  }
}

SourceDocument _buildSourceDocument({
  required SourceRef documentRef,
  required List<SourcePart> parts,
  required Set<String> issueCodes,
}) {
  return SourceDocument(
    sourceId: documentRef.sourceId,
    displayLabel: documentRef.displayLabel,
    parts: parts,
    issues: <ImportIssue>[
      for (final spec in _issueSpecs)
        if (issueCodes.contains(spec.code))
          ImportIssue(
            code: spec.code,
            severity: spec.severity,
            field: spec.field,
            sourceRef: documentRef,
          ),
    ],
  );
}

void _collectOrderIssues(
  List<DocumentPart> parts,
  Set<String> issueCodes,
) {
  final seenOrders = <int>{};
  int? previousNonNegativeOrder;

  for (final part in parts) {
    final order = part.order;
    if (order < 0) {
      issueCodes.add('parsed_order_invalid');
      continue;
    }
    if (!seenOrders.add(order)) {
      issueCodes.add('parsed_order_duplicate');
    }
    if (previousNonNegativeOrder != null && order < previousNonNegativeOrder) {
      issueCodes.add('parsed_order_invalid');
    }
    previousNonNegativeOrder = order;
  }
}

SourcePart _mapImagePart({
  required ImagePart part,
  required SourceRef sourceRef,
  required Map<String, AssetRef> assetByProducerKey,
  required Map<String, List<DocumentImageAsset>> metadataByProducerKey,
  required Set<String> issueCodes,
}) {
  final producerKey = part.assetId;
  final partAltText = _nonBlankText(part.altText);
  if (producerKey == null || producerKey.isEmpty) {
    issueCodes.add('parsed_asset_identity_invalid');
    return UnsupportedSourcePart(
      sourceRef: sourceRef,
      kindCode: 'parsed_image',
      fallbackContent: _textContent(partAltText ?? _imageFallbackText),
    );
  }

  final asset = assetByProducerKey[producerKey]!;
  final metadataCandidates = metadataByProducerKey[producerKey];
  DocumentImageAsset? metadata;
  if (metadataCandidates == null) {
    issueCodes.add('parsed_asset_missing');
  } else if (metadataCandidates.length == 1) {
    metadata = metadataCandidates.single;
    if (!metadata.isResolvable) {
      issueCodes.add('parsed_asset_unresolved');
    }
  } else {
    issueCodes.add('parsed_asset_metadata_conflict');
  }

  final metadataAltText = _nonBlankText(metadata?.altText);
  if (partAltText != null &&
      metadataAltText != null &&
      partAltText != metadataAltText) {
    issueCodes.add('parsed_asset_metadata_conflict');
  }
  final alternativeText = partAltText ?? metadataAltText;

  return SourceAssetPart(
    sourceRef: sourceRef,
    asset: asset,
    alternativeText:
        alternativeText == null ? null : _textContent(alternativeText),
  );
}

String _safeDomainAssetId(int ordinal) {
  return 'asset_${ordinal.toString().padLeft(6, '0')}';
}

SourceContentRole _mapTextRole(TextRole role) {
  return switch (role) {
    TextRole.paragraph => SourceContentRole.paragraph,
    TextRole.heading => SourceContentRole.heading,
    TextRole.answerBlock => SourceContentRole.answerLike,
    TextRole.tableCell || TextRole.formulaLike => SourceContentRole.unknown,
  };
}

String? _nonBlankText(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return value;
}

RichContent _textContent(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

/// One projected text node may not exceed the shared RichContent admission
/// bound, so a long text part is split instead of making the whole document
/// unrepresentable.
const int _maxTextNodeRunes = RichContentLimits.maxNodeScalars;

final _blankLineSeparatorPattern = RegExp(r'\n[ \t]*\n');

/// Splits one document text into ordered chunks that each fit one [TextNode].
///
/// Chunking preserves paragraph (blank-line) boundaries first, then line
/// boundaries, and only then hard-splits at the rune bound. Concatenating the
/// returned chunks reproduces [text] exactly, including separator whitespace.
List<String> _boundedTextChunks(String text) {
  final totalRunes = text.runes.length;
  if (totalRunes <= _maxTextNodeRunes) {
    return <String>[text];
  }

  final chunks = <String>[];
  var start = 0;
  var consumedRunes = 0;
  while (start < text.length) {
    if (totalRunes - consumedRunes <= _maxTextNodeRunes) {
      chunks.add(text.substring(start));
      break;
    }

    // A code-unit window of the rune bound never exceeds it; stepping back off
    // a trailing high surrogate keeps the cut on a rune boundary.
    var end = start + _maxTextNodeRunes;
    while (end > start && _isHighSurrogate(text.codeUnitAt(end - 1))) {
      end--;
    }
    final window = text.substring(start, end);

    var cut = _lastBlankLineEnd(window);
    if (cut <= 0) {
      cut = window.lastIndexOf('\n') + 1;
    }
    if (cut <= 0) {
      cut = window.length;
    }

    final chunk = text.substring(start, start + cut);
    chunks.add(chunk);
    consumedRunes += chunk.runes.length;
    start += cut;
  }
  return chunks;
}

int _lastBlankLineEnd(String window) {
  var end = 0;
  for (final match in _blankLineSeparatorPattern.allMatches(window)) {
    end = match.end;
  }
  return end;
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

final class _IssueSpec {
  const _IssueSpec({
    required this.code,
    required this.severity,
    required this.field,
  });

  final String code;
  final ImportIssueSeverity severity;
  final ImportIssueField field;
}
