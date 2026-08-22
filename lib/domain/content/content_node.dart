import 'dart:collection';

import 'rich_content.dart';
import 'rich_content_limits.dart';

sealed class ContentNode {
  const ContentNode();
}

final class TextNode extends ContentNode {
  const TextNode(this.text);

  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TextNode && text == other.text;

  @override
  int get hashCode => Object.hash('text', text);
}

final class InlineMathNode extends ContentNode {
  const InlineMathNode(this.latex);

  final String latex;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is InlineMathNode && latex == other.latex;

  @override
  int get hashCode => Object.hash('inline_math', latex);
}

final class BlockMathNode extends ContentNode {
  const BlockMathNode(this.latex);

  final String latex;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is BlockMathNode && latex == other.latex;

  @override
  int get hashCode => Object.hash('block_math', latex);
}

final class ImageNode extends ContentNode {
  factory ImageNode({
    required String sourceId,
    required String localAssetId,
    RichContent? alternativeText,
  }) {
    _validateOpaqueIdentity(sourceId, 'Image sourceId');
    _validateOpaqueIdentity(localAssetId, 'Image assetId');
    if (alternativeText != null) {
      _validateImageAlternativeText(alternativeText);
    }
    return ImageNode._(
      sourceId: sourceId,
      localAssetId: localAssetId,
      alternativeText: alternativeText,
    );
  }

  const ImageNode._({
    required this.sourceId,
    required this.localAssetId,
    required this.alternativeText,
  });

  final String sourceId;
  final String localAssetId;
  final RichContent? alternativeText;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ImageNode &&
            sourceId == other.sourceId &&
            localAssetId == other.localAssetId &&
            alternativeText == other.alternativeText;
  }

  @override
  int get hashCode => Object.hash(
        'image',
        sourceId,
        localAssetId,
        alternativeText,
      );
}

final class TableCell {
  factory TableCell({
    required RichContent content,
    int rowSpan = 1,
    int columnSpan = 1,
  }) {
    _validateSpan(rowSpan, 'rowSpan');
    _validateSpan(columnSpan, 'columnSpan');
    _validateTableCellContent(content);
    return TableCell._(
      content: content,
      rowSpan: rowSpan,
      columnSpan: columnSpan,
    );
  }

  const TableCell._({
    required this.content,
    required this.rowSpan,
    required this.columnSpan,
  });

  final RichContent content;
  final int rowSpan;
  final int columnSpan;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TableCell &&
            content == other.content &&
            rowSpan == other.rowSpan &&
            columnSpan == other.columnSpan;
  }

  @override
  int get hashCode => Object.hash(content, rowSpan, columnSpan);
}

final class TableRow {
  factory TableRow({required Iterable<TableCell> cells}) {
    final copiedCells = <TableCell>[];
    for (final cell in cells) {
      if (copiedCells.length >= RichContentLimits.maxTableLogicalCells) {
        throw const FormatException('Table logical cell limit exceeded.');
      }
      copiedCells.add(cell);
    }
    return TableRow._(
      cells: List<TableCell>.unmodifiable(copiedCells),
    );
  }

  const TableRow._({required this.cells});

  final List<TableCell> cells;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TableRow && _orderedEquals(cells, other.cells);
  }

  @override
  int get hashCode => Object.hashAll(cells);
}

final class TableStructure {
  factory TableStructure({required Iterable<TableRow> rows}) {
    final copiedRows = <TableRow>[];
    var logicalCellCount = 0;
    for (final row in rows) {
      if (copiedRows.length >= RichContentLimits.maxTableRows) {
        throw const FormatException('Table row limit exceeded.');
      }
      logicalCellCount += row.cells.length;
      if (logicalCellCount > RichContentLimits.maxTableLogicalCells) {
        throw const FormatException('Table logical cell limit exceeded.');
      }
      copiedRows.add(row);
    }
    final geometry = _buildTableGeometry(copiedRows);
    return TableStructure._(
      rows: List<TableRow>.unmodifiable(copiedRows),
      expandedCells: geometry.cells,
      columnCount: geometry.columnCount,
    );
  }

  const TableStructure._({
    required this.rows,
    required List<List<TableCell?>> expandedCells,
    required this.columnCount,
  }) : _expandedCells = expandedCells;

  final List<TableRow> rows;
  final int columnCount;
  final List<List<TableCell?>> _expandedCells;

  int get expandedCellCount => columnCount * rows.length;

  /// Returns the validated rectangular geometry. An anchor cell is present at
  /// its top-left coordinate; coordinates covered by a span are null.
  List<List<TableCell?>> get expandedCells => _expandedCells;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TableStructure && _orderedEquals(rows, other.rows);
  }

  @override
  int get hashCode => Object.hashAll(rows);
}

final class TableNode extends ContentNode {
  const TableNode({required this.structure});

  final TableStructure structure;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TableNode && structure == other.structure;

  @override
  int get hashCode => Object.hash('table', structure);
}

/// Yields every image reachable through formal RichContent nesting edges.
/// This is structural traversal only; inventory membership is validated by
/// the owning draft/source context.
Iterable<ImageNode> reachableImageNodes(RichContent content) sync* {
  for (final node in content.nodes) {
    switch (node) {
      case ImageNode(:final alternativeText):
        yield node;
        if (alternativeText != null) {
          yield* reachableImageNodes(alternativeText);
        }
      case TableNode(:final structure):
        for (final row in structure.rows) {
          for (final cell in row.cells) {
            yield* reachableImageNodes(cell.content);
          }
        }
      case TextNode():
      case InlineMathNode():
      case BlockMathNode():
      case RawFallbackNode():
        break;
    }
  }
}

final class RawFallbackNode extends ContentNode {
  RawFallbackNode(Map<Object?, Object?> rawJson)
      : rawJson = _freezeRawJson(rawJson);

  final Map<String, Object?> rawJson;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RawFallbackNode && _jsonValueEquals(rawJson, other.rawJson);

  @override
  int get hashCode => Object.hash('raw_fallback', _jsonValueHash(rawJson));
}

void _validateOpaqueIdentity(String value, String label) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
    throw FormatException('$label must use a bounded opaque identity.');
  }
}

void _validateImageAlternativeText(RichContent content) {
  for (final node in content.nodes) {
    if (node is! TextNode &&
        node is! InlineMathNode &&
        node is! BlockMathNode) {
      throw const FormatException(
        'Image alternative text may contain only text or math nodes.',
      );
    }
  }
}

void _validateTableCellContent(RichContent content) {
  for (final node in content.nodes) {
    if (node is TableNode || node is RawFallbackNode) {
      throw const FormatException(
        'Table cells may not contain nested tables or raw fallback nodes.',
      );
    }
  }
}

void _validateSpan(int value, String label) {
  if (value < 1) {
    throw FormatException('$label must be at least one.');
  }
}

_TableGeometry _buildTableGeometry(List<TableRow> rows) {
  if (rows.isEmpty) {
    throw const FormatException('Tables require at least one row.');
  }

  final occupancy = <List<_TableCoordinate?>>[
    for (var index = 0; index < rows.length; index++) <_TableCoordinate?>[],
  ];

  void occupy(
    int rowIndex,
    int columnIndex,
    TableCell cell, {
    required bool anchor,
  }) {
    final row = occupancy[rowIndex];
    if (columnIndex >= RichContentLimits.maxTableColumns) {
      throw const FormatException('Table column limit exceeded.');
    }
    while (row.length <= columnIndex) {
      row.add(null);
    }
    if (row[columnIndex] != null) {
      throw const FormatException('Table spans overlap.');
    }
    row[columnIndex] = _TableCoordinate(cell: cell, anchor: anchor);
  }

  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    var cursor = 0;
    for (final cell in rows[rowIndex].cells) {
      if (cell.rowSpan > rows.length - rowIndex) {
        throw const FormatException('Table row span exceeds table bounds.');
      }
      if (cell.columnSpan > RichContentLimits.maxTableColumns) {
        throw const FormatException('Table column span exceeds the limit.');
      }

      var start = cursor;
      while (start < occupancy[rowIndex].length &&
          occupancy[rowIndex][start] != null) {
        start++;
      }
      for (var column = start; column < start + cell.columnSpan; column++) {
        occupy(
          rowIndex,
          column,
          cell,
          anchor: column == start,
        );
        for (var coveredRow = rowIndex + 1;
            coveredRow < rowIndex + cell.rowSpan;
            coveredRow++) {
          occupy(coveredRow, column, cell, anchor: false);
        }
      }
      cursor = start + cell.columnSpan;
    }
  }

  var columnCount = 0;
  for (final row in occupancy) {
    if (row.length > columnCount) columnCount = row.length;
  }
  if (columnCount == 0 || columnCount > RichContentLimits.maxTableColumns) {
    throw const FormatException('Table geometry has no valid columns.');
  }
  final expandedCellCount = columnCount * rows.length;
  if (expandedCellCount > RichContentLimits.maxTableExpandedCells) {
    throw const FormatException('Table expanded cell limit exceeded.');
  }

  final rectangular = <List<TableCell?>>[];
  for (final row in occupancy) {
    final expanded = List<TableCell?>.filled(columnCount, null);
    for (var column = 0; column < row.length; column++) {
      final coordinate = row[column];
      if (coordinate == null) continue;
      if (coordinate.anchor) expanded[column] = coordinate.cell;
    }
    if (row.length != columnCount ||
        row.any((coordinate) => coordinate == null)) {
      throw const FormatException(
        'Table geometry contains an unresolved implicit hole.',
      );
    }
    rectangular.add(List<TableCell?>.unmodifiable(expanded));
  }
  return _TableGeometry(
    cells: List<List<TableCell?>>.unmodifiable(rectangular),
    columnCount: columnCount,
  );
}

final class _TableCoordinate {
  const _TableCoordinate({required this.cell, required this.anchor});

  final TableCell cell;
  final bool anchor;
}

final class _TableGeometry {
  const _TableGeometry({required this.cells, required this.columnCount});

  final List<List<TableCell?>> cells;
  final int columnCount;
}

bool _orderedEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Map<String, Object?> _freezeRawJson(Map<Object?, Object?> rawJson) {
  final frozen = _freezeJsonValue(
    rawJson,
    HashSet<Object>.identity(),
  ) as Map<String, Object?>;
  final type = frozen['type'];
  if (type is! String || type.trim().isEmpty) {
    throw const FormatException(
      'Raw fallback nodes require a non-empty string type.',
    );
  }
  _validateFallbackShape(frozen, type);
  return frozen;
}

void _validateFallbackShape(
  Map<String, Object?> rawJson,
  String type,
) {
  switch (type) {
    case 'text':
      _requireExtendedKnownFallback(rawJson, 'text');
    case 'inline_math':
    case 'block_math':
      _requireExtendedKnownFallback(rawJson, 'latex');
    case 'image':
      if (rawJson['sourceId'] is! String ||
          rawJson['assetId'] is! String ||
          !rawJson.containsKey('alternativeText')) {
        throw const FormatException(
          'Known image fallback nodes require their canonical fields.',
        );
      }
      if (rawJson.length == 4) {
        throw const FormatException(
          'Canonical known nodes cannot be represented as raw fallback nodes.',
        );
      }
    case 'table':
      if (rawJson['rows'] is! List) {
        throw const FormatException(
          'Known table fallback nodes require a rows field.',
        );
      }
      if (rawJson.length == 2) {
        throw const FormatException(
          'Canonical known nodes cannot be represented as raw fallback nodes.',
        );
      }
    case 'raw_fallback':
      if (!rawJson.containsKey('payload')) {
        throw const FormatException(
          'Raw fallback nodes require a payload field.',
        );
      }
  }
}

void _requireExtendedKnownFallback(
  Map<String, Object?> rawJson,
  String contentKey,
) {
  if (rawJson[contentKey] is! String) {
    throw const FormatException(
      'Known fallback nodes require their canonical string field.',
    );
  }
  if (rawJson.length == 2) {
    throw const FormatException(
      'Canonical known nodes cannot be represented as raw fallback nodes.',
    );
  }
}

Object? _freezeJsonValue(
  Object? value,
  Set<Object> ancestors,
) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException(
        'Raw fallback nodes contain a non-JSON number.',
      );
    }
    return value;
  }
  if (value is List) {
    if (!ancestors.add(value)) {
      throw const FormatException(
        'Raw fallback nodes contain a cyclic collection.',
      );
    }
    try {
      return List<Object?>.unmodifiable(
        value.map((item) => _freezeJsonValue(item, ancestors)),
      );
    } finally {
      ancestors.remove(value);
    }
  }
  if (value is Map) {
    if (!ancestors.add(value)) {
      throw const FormatException(
        'Raw fallback nodes contain a cyclic collection.',
      );
    }
    try {
      final copy = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw const FormatException(
            'Raw fallback node object keys must be strings.',
          );
        }
        copy[key] = _freezeJsonValue(entry.value, ancestors);
      }
      return Map<String, Object?>.unmodifiable(copy);
    } finally {
      ancestors.remove(value);
    }
  }

  throw const FormatException(
    'Raw fallback nodes contain a non-JSON value.',
  );
}

bool _jsonValueEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_jsonValueEquals(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_jsonValueEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List || right is List || left is Map || right is Map) {
    return false;
  }
  return left.runtimeType == right.runtimeType && left == right;
}

int _jsonValueHash(Object? value) {
  if (value is List) {
    return Object.hash(
      'json_list',
      Object.hashAll(value.map(_jsonValueHash)),
    );
  }
  if (value is Map) {
    return Object.hash(
      'json_map',
      Object.hashAllUnordered(
        value.entries.map(
          (entry) => Object.hash(entry.key, _jsonValueHash(entry.value)),
        ),
      ),
    );
  }
  return Object.hash(value.runtimeType, value);
}
