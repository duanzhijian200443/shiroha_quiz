final _opaqueIdentifierPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
final _displayLabelControlPattern = RegExp(r'[\u0000-\u001f\u007f]');
final _displayLabelSchemePattern = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:');

final class SourcePoint {
  factory SourcePoint.page({required int pageNumber}) {
    _validatePageNumber(pageNumber);
    return SourcePoint._(
      pageNumber: pageNumber,
      blockId: null,
      readingOrder: null,
    );
  }

  factory SourcePoint.block({
    required int pageNumber,
    required String blockId,
    required int readingOrder,
  }) {
    _validatePageNumber(pageNumber);
    _validateOpaqueIdentifier(blockId);
    if (readingOrder < 0) {
      throw const FormatException(
        'Source point reading order must be non-negative.',
      );
    }
    return SourcePoint._(
      pageNumber: pageNumber,
      blockId: blockId,
      readingOrder: readingOrder,
    );
  }

  const SourcePoint._({
    required this.pageNumber,
    required this.blockId,
    required this.readingOrder,
  });

  final int pageNumber;
  final String? blockId;
  final int? readingOrder;

  bool get isBlock => blockId != null;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SourcePoint &&
            pageNumber == other.pageNumber &&
            blockId == other.blockId &&
            readingOrder == other.readingOrder;
  }

  @override
  int get hashCode => Object.hash(pageNumber, blockId, readingOrder);
}

final class SourceRef {
  factory SourceRef.document({
    required String sourceId,
    String? displayLabel,
  }) {
    return SourceRef._(
      sourceId: _validateOpaqueIdentifier(sourceId),
      displayLabel: _validateDisplayLabel(displayLabel),
      start: null,
      end: null,
    );
  }

  factory SourceRef.at({
    required String sourceId,
    String? displayLabel,
    required SourcePoint point,
  }) {
    return SourceRef._(
      sourceId: _validateOpaqueIdentifier(sourceId),
      displayLabel: _validateDisplayLabel(displayLabel),
      start: point,
      end: point,
    );
  }

  factory SourceRef.range({
    required String sourceId,
    String? displayLabel,
    required SourcePoint start,
    required SourcePoint end,
  }) {
    if (!start.isBlock || !end.isBlock) {
      throw const FormatException(
        'Source ranges require block-level endpoints.',
      );
    }
    if (_comparePoints(start, end) >= 0) {
      throw const FormatException(
        'Source range start must precede its end.',
      );
    }
    return SourceRef._(
      sourceId: _validateOpaqueIdentifier(sourceId),
      displayLabel: _validateDisplayLabel(displayLabel),
      start: start,
      end: end,
    );
  }

  const SourceRef._({
    required this.sourceId,
    required this.displayLabel,
    required this.start,
    required this.end,
  });

  final String sourceId;
  final String? displayLabel;
  final SourcePoint? start;
  final SourcePoint? end;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SourceRef &&
            sourceId == other.sourceId &&
            displayLabel == other.displayLabel &&
            start == other.start &&
            end == other.end;
  }

  @override
  int get hashCode => Object.hash(sourceId, displayLabel, start, end);
}

String _validateOpaqueIdentifier(String value) {
  if (!_opaqueIdentifierPattern.hasMatch(value)) {
    throw const FormatException(
      'Domain identifiers must use the bounded opaque token format.',
    );
  }
  return value;
}

String? _validateDisplayLabel(String? value) {
  if (value == null) return null;
  if (value.isEmpty ||
      value.length > 160 ||
      value != value.trim() ||
      value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains(r'\') ||
      _displayLabelControlPattern.hasMatch(value) ||
      _displayLabelSchemePattern.hasMatch(value)) {
    throw const FormatException(
      'Source display labels must be safe bounded basenames.',
    );
  }
  return value;
}

void _validatePageNumber(int pageNumber) {
  if (pageNumber <= 0) {
    throw const FormatException(
      'Source page numbers are one-based positive integers.',
    );
  }
}

int _comparePoints(SourcePoint left, SourcePoint right) {
  final pageComparison = left.pageNumber.compareTo(right.pageNumber);
  if (pageComparison != 0) return pageComparison;
  return left.readingOrder!.compareTo(right.readingOrder!);
}
