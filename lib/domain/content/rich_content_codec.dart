import 'dart:collection';

import 'content_node.dart';
import 'rich_content.dart';
import 'rich_content_limits.dart';

final class RichContentCodec {
  const RichContentCodec();

  static const int schemaVersion = 1;

  Map<String, Object?> encode(RichContent content) {
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'nodes': content.nodes.map(_encodeNode).toList(),
    };
  }

  RichContent decode(Object? json) {
    return _decodeContent(
      json,
      budget: _RichContentDecodeBudget(),
      depth: 0,
      context: _DecodeContext.root,
    );
  }

  RichContent _decodeContent(
    Object? json, {
    required _RichContentDecodeBudget budget,
    required int depth,
    required _DecodeContext context,
  }) {
    budget.checkDepth(depth);
    if (json is! Map) {
      throw const FormatException(
        'RichContent root must be a JSON object.',
      );
    }
    if (json.length != 2) {
      throw const FormatException(
        'RichContent root contains unsupported fields.',
      );
    }
    final root = _stringKeyedMap(json);
    if (!root.containsKey('schemaVersion')) {
      throw const FormatException(
        'RichContent schemaVersion is required.',
      );
    }
    if (!root.containsKey('nodes')) {
      throw const FormatException(
        'RichContent nodes are required.',
      );
    }
    final version = root['schemaVersion'];
    if (version is! int) {
      throw const FormatException(
        'RichContent schemaVersion must be an integer.',
      );
    }
    if (version != schemaVersion) {
      throw UnsupportedError(
        'Unsupported RichContent schemaVersion: $version.',
      );
    }

    final rawNodes = root['nodes'];
    if (rawNodes is! List) {
      throw const FormatException(
        'RichContent nodes must be a JSON array.',
      );
    }
    if (rawNodes.length > RichContentLimits.maxNodes) {
      throw const FormatException('RichContent node limit exceeded.');
    }

    final nodes = <ContentNode>[];
    for (final rawNode in rawNodes) {
      if (rawNode is! Map) {
        throw const FormatException(
          'RichContent nodes must be JSON objects.',
        );
      }
      if (rawNode.length > RichContentLimits.maxRawCollectionEntries) {
        throw const FormatException('RichContent fallback bound exceeded.');
      }
      budget.claimNode();
      final node = _stringKeyedMap(rawNode);
      final type = node['type'];
      if (type is! String || type.trim().isEmpty) {
        throw const FormatException(
          'RichContent node type must be a non-empty string.',
        );
      }
      _validateContext(type, context);
      nodes.add(
        _decodeNode(
          node,
          budget: budget,
          depth: depth,
        ),
      );
    }
    return RichContent(nodes: nodes);
  }

  Map<String, Object?> _encodeNode(ContentNode node) {
    return switch (node) {
      TextNode(:final text) => <String, Object?>{
          'type': 'text',
          'text': text,
        },
      InlineMathNode(:final latex) => <String, Object?>{
          'type': 'inline_math',
          'latex': latex,
        },
      BlockMathNode(:final latex) => <String, Object?>{
          'type': 'block_math',
          'latex': latex,
        },
      ImageNode(
        :final sourceId,
        :final localAssetId,
        :final alternativeText,
      ) =>
        <String, Object?>{
          'type': 'image',
          'sourceId': sourceId,
          'assetId': localAssetId,
          'alternativeText':
              alternativeText == null ? null : encode(alternativeText),
        },
      TableNode(:final structure) => <String, Object?>{
          'type': 'table',
          'rows': structure.rows.map(_encodeTableRow).toList(),
        },
      RawFallbackNode(:final rawJson) => _copyJsonMap(rawJson),
    };
  }

  ContentNode _decodeNode(
    Map<String, Object?> node, {
    required _RichContentDecodeBudget budget,
    required int depth,
  }) {
    final type = node['type'];

    return switch (type) {
      'text' => _decodeTextNode(node, budget: budget, depth: depth),
      'inline_math' =>
        _decodeInlineMathNode(node, budget: budget, depth: depth),
      'block_math' => _decodeBlockMathNode(node, budget: budget, depth: depth),
      'image' => _decodeImageNode(node, budget: budget, depth: depth),
      'table' => _decodeTableNode(node, budget: budget, depth: depth),
      'raw_fallback' => _decodeRawFallbackNode(
          node,
          budget: budget,
          depth: depth,
        ),
      _ => _decodeUnknownNode(node, budget: budget, depth: depth),
    };
  }

  ContentNode _decodeTextNode(
    Map<String, Object?> node, {
    required _RichContentDecodeBudget budget,
    required int depth,
  }) {
    final text = node['text'];
    if (text is! String) {
      throw const FormatException(
        'Text nodes require a string text field.',
      );
    }
    if (!_hasExactKeys(node, const <String>{'type', 'text'})) {
      budget.preflightRawValue(node, depth: depth + 1);
      return RawFallbackNode(node);
    }
    budget.claimScalar(text);
    return TextNode(text);
  }

  ContentNode _decodeInlineMathNode(
    Map<String, Object?> node, {
    required _RichContentDecodeBudget budget,
    required int depth,
  }) {
    final latex = node['latex'];
    if (latex is! String) {
      throw const FormatException(
        'Inline math nodes require a string latex field.',
      );
    }
    if (!_hasExactKeys(node, const <String>{'type', 'latex'})) {
      budget.preflightRawValue(node, depth: depth + 1);
      return RawFallbackNode(node);
    }
    budget.claimScalar(latex);
    return InlineMathNode(latex);
  }

  ContentNode _decodeBlockMathNode(
    Map<String, Object?> node, {
    required _RichContentDecodeBudget budget,
    required int depth,
  }) {
    final latex = node['latex'];
    if (latex is! String) {
      throw const FormatException(
        'Block math nodes require a string latex field.',
      );
    }
    if (!_hasExactKeys(node, const <String>{'type', 'latex'})) {
      budget.preflightRawValue(node, depth: depth + 1);
      return RawFallbackNode(node);
    }
    budget.claimScalar(latex);
    return BlockMathNode(latex);
  }

  ContentNode _decodeImageNode(
    Map<String, Object?> node, {
    required _RichContentDecodeBudget budget,
    required int depth,
  }) {
    final sourceId = node['sourceId'];
    if (sourceId is! String) {
      throw const FormatException(
        'Image nodes require a string sourceId field.',
      );
    }
    final assetId = node['assetId'];
    if (assetId is! String) {
      throw const FormatException(
        'Image nodes require a string assetId field.',
      );
    }
    if (!node.containsKey('alternativeText')) {
      throw const FormatException(
        'Image nodes require an alternativeText field.',
      );
    }
    final rawAlternativeText = node['alternativeText'];
    final exact = _hasExactKeys(
      node,
      const <String>{'type', 'sourceId', 'assetId', 'alternativeText'},
    );
    budget.claimImage();
    budget.claimScalar(sourceId);
    budget.claimScalar(assetId);
    if (!exact) {
      budget.preflightRawValue(
        node,
        depth: depth + 1,
        skipMapValueKeys: const <String>{
          'sourceId',
          'assetId',
          'alternativeText',
        },
      );
      if (rawAlternativeText != null) {
        budget.preflightRawValue(
          rawAlternativeText,
          depth: depth + 1,
          countScalars: false,
        );
      }
    }
    final alternativeText = rawAlternativeText == null
        ? null
        : _decodeContent(
            rawAlternativeText,
            budget: budget,
            depth: depth + 1,
            context: _DecodeContext.imageAlternative,
          );
    final image = ImageNode(
      sourceId: sourceId,
      localAssetId: assetId,
      alternativeText: alternativeText,
    );
    return exact ? image : RawFallbackNode(node);
  }

  ContentNode _decodeTableNode(
    Map<String, Object?> node, {
    required _RichContentDecodeBudget budget,
    required int depth,
  }) {
    final rawRows = node['rows'];
    if (rawRows is! List) {
      throw const FormatException('Table nodes require a rows array.');
    }
    if (rawRows.isEmpty) {
      throw const FormatException('Tables require at least one row.');
    }
    if (rawRows.length > RichContentLimits.maxTableRows) {
      throw const FormatException('Table row limit exceeded.');
    }
    final exact = _hasExactKeys(node, const <String>{'type', 'rows'});
    if (!exact) {
      budget.preflightRawValue(
        node,
        depth: depth + 1,
        skipMapValueKeys: const <String>{'rows'},
      );
      budget.preflightRawValue(
        rawRows,
        depth: depth + 1,
        countScalars: false,
      );
    }
    if (rawRows.length * RichContentLimits.maxTableColumns >
        RichContentLimits.maxTableExpandedCells) {
      throw const FormatException('Table expanded cell limit exceeded.');
    }
    final rows = <TableRow>[];
    var tableLogicalCellCount = 0;
    for (var rowIndex = 0; rowIndex < rawRows.length; rowIndex++) {
      final rawRow = rawRows[rowIndex];
      if (rawRow is Map && rawRow.length != 1) {
        throw const FormatException('Table row contains unsupported fields.');
      }
      final row = _expectUntypedObject(rawRow, 'Table row');
      _requireExactKeys(row, const <String>{'cells'}, 'Table row');
      final rawCells = row['cells'];
      if (rawCells is! List) {
        throw const FormatException('Table row cells must be an array.');
      }
      tableLogicalCellCount += rawCells.length;
      if (tableLogicalCellCount > RichContentLimits.maxTableLogicalCells) {
        throw const FormatException('Table logical cell limit exceeded.');
      }
      final cells = <TableCell>[];
      var rowColumnSpan = 0;
      for (final rawCell in rawCells) {
        if (rawCell is Map && rawCell.length != 3) {
          throw const FormatException(
            'Table cell contains unsupported fields.',
          );
        }
        final cell = _expectUntypedObject(rawCell, 'Table cell');
        _requireExactKeys(
          cell,
          const <String>{'content', 'rowSpan', 'columnSpan'},
          'Table cell',
        );
        final rowSpan = cell['rowSpan'];
        final columnSpan = cell['columnSpan'];
        if (rowSpan is! int || columnSpan is! int) {
          throw const FormatException(
            'Table cell spans must be integers.',
          );
        }
        if (rowSpan < 1 || columnSpan < 1) {
          throw const FormatException(
            'Table cell spans must be positive integers.',
          );
        }
        if (rowSpan > rawRows.length - rowIndex) {
          throw const FormatException(
            'Table row span exceeds table bounds.',
          );
        }
        if (columnSpan > RichContentLimits.maxTableColumns) {
          throw const FormatException(
            'Table column span exceeds the limit.',
          );
        }
        rowColumnSpan += columnSpan;
        if (rowColumnSpan > RichContentLimits.maxTableColumns) {
          throw const FormatException('Table column limit exceeded.');
        }
        cells.add(
          TableCell(
            content: _decodeContent(
              cell['content'],
              budget: budget,
              depth: depth + 1,
              context: _DecodeContext.tableCell,
            ),
            rowSpan: rowSpan,
            columnSpan: columnSpan,
          ),
        );
      }
      rows.add(TableRow(cells: cells));
    }
    final table = TableNode(structure: TableStructure(rows: rows));
    if (table.structure.expandedCellCount >
        RichContentLimits.maxTableExpandedCells) {
      throw const FormatException('Table expanded cell limit exceeded.');
    }
    return exact ? table : RawFallbackNode(node);
  }

  Map<String, Object?> _encodeTableRow(TableRow row) {
    return <String, Object?>{
      'cells': row.cells.map(_encodeTableCell).toList(),
    };
  }

  Map<String, Object?> _encodeTableCell(TableCell cell) {
    return <String, Object?>{
      'content': encode(cell.content),
      'rowSpan': cell.rowSpan,
      'columnSpan': cell.columnSpan,
    };
  }

  ContentNode _decodeRawFallbackNode(
    Map<String, Object?> node, {
    required _RichContentDecodeBudget budget,
    required int depth,
  }) {
    if (!node.containsKey('payload')) {
      throw const FormatException(
        'Raw fallback nodes require a payload field.',
      );
    }
    budget.preflightRawValue(node, depth: depth + 1);
    return RawFallbackNode(node);
  }

  ContentNode _decodeUnknownNode(
    Map<String, Object?> node, {
    required _RichContentDecodeBudget budget,
    required int depth,
  }) {
    budget.preflightRawValue(node, depth: depth + 1);
    return RawFallbackNode(node);
  }
}

enum _DecodeContext { root, imageAlternative, tableCell }

void _validateContext(String type, _DecodeContext context) {
  switch (context) {
    case _DecodeContext.root:
      return;
    case _DecodeContext.imageAlternative:
      if (type == 'text' || type == 'inline_math' || type == 'block_math') {
        return;
      }
      throw const FormatException(
        'Image alternative text may contain only text or math nodes.',
      );
    case _DecodeContext.tableCell:
      if (type == 'text' ||
          type == 'inline_math' ||
          type == 'block_math' ||
          type == 'image') {
        return;
      }
      throw const FormatException(
        'Table cells may not contain nested tables or raw fallback nodes.',
      );
  }
}

final class _RichContentDecodeBudget {
  int nodeCount = 0;
  int scalarCount = 0;
  int imageCount = 0;
  int rawCollectionEntries = 0;

  void checkDepth(int depth) {
    if (depth > RichContentLimits.maxDepth) {
      throw const FormatException('RichContent recursion limit exceeded.');
    }
  }

  void claimNode() {
    nodeCount++;
    if (nodeCount > RichContentLimits.maxNodes) {
      throw const FormatException('RichContent node limit exceeded.');
    }
  }

  void claimScalar(String value) {
    final length = value.runes.length;
    if (length > RichContentLimits.maxNodeScalars) {
      throw const FormatException('RichContent node scalar limit exceeded.');
    }
    scalarCount += length;
    if (scalarCount > RichContentLimits.maxScalars) {
      throw const FormatException('RichContent scalar limit exceeded.');
    }
  }

  void claimImage() {
    imageCount++;
    if (imageCount > RichContentLimits.maxImages) {
      throw const FormatException('RichContent image limit exceeded.');
    }
  }

  void preflightRawValue(
    Object? value, {
    required int depth,
    bool countScalars = true,
    Set<String> skipMapValueKeys = const <String>{},
  }) {
    _preflightRawValue(
      value,
      depth: depth,
      ancestors: HashSet<Object>.identity(),
      countScalars: countScalars,
      skipMapValueKeys: skipMapValueKeys,
    );
  }

  void _preflightRawValue(
    Object? value, {
    required int depth,
    required Set<Object> ancestors,
    required bool countScalars,
    Set<String> skipMapValueKeys = const <String>{},
  }) {
    checkDepth(depth);
    if (value is Map) {
      if (!ancestors.add(value)) {
        throw const FormatException(
          'Raw fallback nodes contain a cyclic collection.',
        );
      }
      try {
        claimRawEntries(value.length);
        for (final entry in value.entries) {
          final key = entry.key;
          if (key is! String) {
            throw const FormatException(
              'Raw fallback node object keys must be strings.',
            );
          }
          if (countScalars) claimScalar(key);
          if (!skipMapValueKeys.contains(key)) {
            _preflightRawValue(
              entry.value,
              depth: depth + 1,
              ancestors: ancestors,
              countScalars: countScalars,
            );
          }
        }
      } finally {
        ancestors.remove(value);
      }
      return;
    }
    if (value is List) {
      if (!ancestors.add(value)) {
        throw const FormatException(
          'Raw fallback nodes contain a cyclic collection.',
        );
      }
      try {
        claimRawEntries(value.length);
        for (final item in value) {
          _preflightRawValue(
            item,
            depth: depth + 1,
            ancestors: ancestors,
            countScalars: countScalars,
          );
        }
      } finally {
        ancestors.remove(value);
      }
      return;
    }
    if (value is String) {
      if (countScalars) claimScalar(value);
      return;
    }
    if (value is double && !value.isFinite) {
      throw const FormatException(
        'Raw fallback nodes contain a non-JSON number.',
      );
    }
    if (value == null || value is bool || value is num) return;
    throw const FormatException(
      'Raw fallback nodes contain a non-JSON value.',
    );
  }

  void claimRawEntries(int count) {
    rawCollectionEntries += count;
    if (rawCollectionEntries > RichContentLimits.maxRawCollectionEntries) {
      throw const FormatException('RichContent fallback bound exceeded.');
    }
  }
}

Map<String, Object?> _stringKeyedMap(Map<Object?, Object?> source) {
  final copy = <String, Object?>{};
  for (final entry in source.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException(
        'JSON object keys must be strings.',
      );
    }
    copy[key] = entry.value;
  }
  return copy;
}

Map<String, Object?> _expectUntypedObject(Object? value, String label) {
  if (value is! Map) {
    throw FormatException('$label must be a JSON object.');
  }
  return _stringKeyedMap(value);
}

bool _hasExactKeys(
  Map<String, Object?> source,
  Set<String> expected,
) {
  if (source.length != expected.length) return false;
  return expected.every(source.containsKey);
}

void _requireExactKeys(
  Map<String, Object?> source,
  Set<String> expected,
  String label,
) {
  if (!_hasExactKeys(source, expected)) {
    throw FormatException('$label contains unsupported fields.');
  }
}

Map<String, Object?> _copyJsonMap(Map<String, Object?> source) {
  return <String, Object?>{
    for (final entry in source.entries) entry.key: _copyJsonValue(entry.value),
  };
}

Object? _copyJsonValue(Object? value) {
  if (value is Map<String, Object?>) {
    return _copyJsonMap(value);
  }
  if (value is List<Object?>) {
    return value.map(_copyJsonValue).toList();
  }
  return value;
}
