import 'content_node.dart';
import 'rich_content.dart';

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
    if (json is! Map) {
      throw const FormatException(
        'RichContent root must be a JSON object.',
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
    if (root.length != 2) {
      throw const FormatException(
        'RichContent root contains unsupported fields.',
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

    final nodes = <ContentNode>[];
    for (final rawNode in rawNodes) {
      nodes.add(_decodeNode(rawNode));
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

  ContentNode _decodeNode(Object? rawNode) {
    if (rawNode is! Map) {
      throw const FormatException(
        'RichContent nodes must be JSON objects.',
      );
    }
    final node = _stringKeyedMap(rawNode);
    final type = node['type'];
    if (type is! String || type.trim().isEmpty) {
      throw const FormatException(
        'RichContent node type must be a non-empty string.',
      );
    }

    return switch (type) {
      'text' => _decodeTextNode(node),
      'inline_math' => _decodeInlineMathNode(node),
      'block_math' => _decodeBlockMathNode(node),
      'image' => _decodeImageNode(node),
      'table' => _decodeTableNode(node),
      'raw_fallback' => _decodeRawFallbackNode(node),
      _ => RawFallbackNode(node),
    };
  }

  ContentNode _decodeTextNode(Map<String, Object?> node) {
    final text = node['text'];
    if (text is! String) {
      throw const FormatException(
        'Text nodes require a string text field.',
      );
    }
    if (!_hasExactKeys(node, const <String>{'type', 'text'})) {
      return RawFallbackNode(node);
    }
    return TextNode(text);
  }

  ContentNode _decodeInlineMathNode(Map<String, Object?> node) {
    final latex = node['latex'];
    if (latex is! String) {
      throw const FormatException(
        'Inline math nodes require a string latex field.',
      );
    }
    if (!_hasExactKeys(node, const <String>{'type', 'latex'})) {
      return RawFallbackNode(node);
    }
    return InlineMathNode(latex);
  }

  ContentNode _decodeBlockMathNode(Map<String, Object?> node) {
    final latex = node['latex'];
    if (latex is! String) {
      throw const FormatException(
        'Block math nodes require a string latex field.',
      );
    }
    if (!_hasExactKeys(node, const <String>{'type', 'latex'})) {
      return RawFallbackNode(node);
    }
    return BlockMathNode(latex);
  }

  ContentNode _decodeImageNode(Map<String, Object?> node) {
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
    final alternativeText =
        rawAlternativeText == null ? null : decode(rawAlternativeText);
    final image = ImageNode(
      sourceId: sourceId,
      localAssetId: assetId,
      alternativeText: alternativeText,
    );
    if (!_hasExactKeys(
      node,
      const <String>{'type', 'sourceId', 'assetId', 'alternativeText'},
    )) {
      return RawFallbackNode(node);
    }
    return image;
  }

  ContentNode _decodeTableNode(Map<String, Object?> node) {
    final rawRows = node['rows'];
    if (rawRows is! List) {
      throw const FormatException('Table nodes require a rows array.');
    }
    final rows = <TableRow>[];
    for (final rawRow in rawRows) {
      final row = _expectUntypedObject(rawRow, 'Table row');
      _requireExactKeys(row, const <String>{'cells'}, 'Table row');
      final rawCells = row['cells'];
      if (rawCells is! List) {
        throw const FormatException('Table row cells must be an array.');
      }
      final cells = <TableCell>[];
      for (final rawCell in rawCells) {
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
        cells.add(
          TableCell(
            content: decode(cell['content']),
            rowSpan: rowSpan,
            columnSpan: columnSpan,
          ),
        );
      }
      rows.add(TableRow(cells: cells));
    }
    final table = TableNode(structure: TableStructure(rows: rows));
    if (!_hasExactKeys(node, const <String>{'type', 'rows'})) {
      return RawFallbackNode(node);
    }
    return table;
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

  ContentNode _decodeRawFallbackNode(Map<String, Object?> node) {
    if (!node.containsKey('payload')) {
      throw const FormatException(
        'Raw fallback nodes require a payload field.',
      );
    }
    return RawFallbackNode(node);
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
