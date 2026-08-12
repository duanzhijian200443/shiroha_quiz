import '../assets/asset_ref.dart';
import '../content/rich_content_codec.dart';
import '../import/import_issue.dart';
import 'source_document.dart';
import 'source_part.dart';
import 'source_ref.dart';

/// Strict versioned codec for [SourceDocument].
///
/// Decoding routes every value through the existing domain constructors so the
/// frozen domain invariants (member identity, range ordering, asset metadata
/// consistency, privacy admission) remain the final authority.
final class SourceDocumentCodec {
  const SourceDocumentCodec();

  static const int schemaVersion = 1;
  static const RichContentCodec _richContentCodec = RichContentCodec();

  Map<String, Object?> encode(SourceDocument document) {
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'sourceId': document.documentRef.sourceId,
      'displayLabel': document.documentRef.displayLabel,
      'parts': document.parts.map(_encodePart).toList(),
      'issues': document.issues.map(_encodeIssue).toList(),
    };
  }

  SourceDocument decode(Object? json) {
    final root = _expectObject(
      json,
      expectedKeys: _rootKeys,
      label: 'SourceDocument root',
    );
    final version = root['schemaVersion'];
    if (version is! int) {
      throw const FormatException(
        'SourceDocument schemaVersion must be an integer.',
      );
    }
    if (version != schemaVersion) {
      throw UnsupportedError(
        'Unsupported SourceDocument schemaVersion: $version.',
      );
    }
    return SourceDocument(
      sourceId: _expectString(root['sourceId'], 'sourceId'),
      displayLabel: _expectNullableString(
        root['displayLabel'],
        'displayLabel',
      ),
      parts: _decodeList(root['parts'], _decodePart, 'parts'),
      issues: _decodeList(root['issues'], _decodeIssue, 'issues'),
    );
  }

  Map<String, Object?> _encodePart(SourcePart part) {
    return switch (part) {
      SourceContentPart(:final sourceRef, :final content, :final role) =>
        <String, Object?>{
          'type': 'content',
          'sourceRef': _encodeSourceRef(sourceRef),
          'content': _richContentCodec.encode(content),
          'role': _encodeContentRole(role),
        },
      SourceTablePart(:final sourceRef, :final rows) => <String, Object?>{
          'type': 'table',
          'sourceRef': _encodeSourceRef(sourceRef),
          'rows': rows
              .map((row) => row.map(_richContentCodec.encode).toList())
              .toList(),
        },
      SourceAssetPart(:final sourceRef, :final asset, :final alternativeText) =>
        <String, Object?>{
          'type': 'asset',
          'sourceRef': _encodeSourceRef(sourceRef),
          'asset': _encodeAssetRef(asset),
          'alternativeText': alternativeText == null
              ? null
              : _richContentCodec.encode(alternativeText),
        },
      UnsupportedSourcePart(
        :final sourceRef,
        :final kindCode,
        :final fallbackContent
      ) =>
        <String, Object?>{
          'type': 'unsupported',
          'sourceRef': _encodeSourceRef(sourceRef),
          'kindCode': kindCode,
          'fallbackContent': _richContentCodec.encode(fallbackContent),
        },
    };
  }

  SourcePart _decodePart(Object? json) {
    final part = _expectUntypedObject(json, 'Source part');
    final type = _expectString(part['type'], 'source part type');
    return switch (type) {
      'content' => _decodeContentPart(part),
      'table' => _decodeTablePart(part),
      'asset' => _decodeAssetPart(part),
      'unsupported' => _decodeUnsupportedPart(part),
      _ => throw const FormatException('Source part type is unsupported.'),
    };
  }

  SourceContentPart _decodeContentPart(Map<String, Object?> part) {
    _requireExactKeys(part, _contentPartKeys, 'Content source part');
    return SourceContentPart(
      sourceRef: _decodeSourceRef(part['sourceRef']),
      content: _richContentCodec.decode(part['content']),
      role: _decodeContentRole(part['role']),
    );
  }

  SourceTablePart _decodeTablePart(Map<String, Object?> part) {
    _requireExactKeys(part, _tablePartKeys, 'Table source part');
    final rawRows = part['rows'];
    if (rawRows is! List) {
      throw const FormatException('Table rows must be a JSON array.');
    }
    final rows = rawRows.map((rawRow) {
      if (rawRow is! List) {
        throw const FormatException('Table rows must contain JSON arrays.');
      }
      return rawRow.map((cell) => _richContentCodec.decode(cell)).toList();
    }).toList();
    return SourceTablePart(
      sourceRef: _decodeSourceRef(part['sourceRef']),
      rows: rows,
    );
  }

  SourceAssetPart _decodeAssetPart(Map<String, Object?> part) {
    _requireExactKeys(part, _assetPartKeys, 'Asset source part');
    return SourceAssetPart(
      sourceRef: _decodeSourceRef(part['sourceRef']),
      asset: _decodeAssetRef(part['asset']),
      alternativeText: part['alternativeText'] == null
          ? null
          : _richContentCodec.decode(part['alternativeText']),
    );
  }

  UnsupportedSourcePart _decodeUnsupportedPart(
    Map<String, Object?> part,
  ) {
    _requireExactKeys(
      part,
      _unsupportedPartKeys,
      'Unsupported source part',
    );
    return UnsupportedSourcePart(
      sourceRef: _decodeSourceRef(part['sourceRef']),
      kindCode: _expectString(part['kindCode'], 'kindCode'),
      fallbackContent: _richContentCodec.decode(part['fallbackContent']),
    );
  }

  Map<String, Object?> _encodeSourceRef(SourceRef sourceRef) {
    final start = sourceRef.start;
    if (start == null) {
      return <String, Object?>{
        'type': 'document',
        'sourceId': sourceRef.sourceId,
        'displayLabel': sourceRef.displayLabel,
      };
    }
    if (start == sourceRef.end) {
      return <String, Object?>{
        'type': 'point',
        'sourceId': sourceRef.sourceId,
        'displayLabel': sourceRef.displayLabel,
        'point': _encodeSourcePoint(start),
      };
    }
    return <String, Object?>{
      'type': 'range',
      'sourceId': sourceRef.sourceId,
      'displayLabel': sourceRef.displayLabel,
      'start': _encodeSourcePoint(start),
      'end': _encodeSourcePoint(sourceRef.end!),
    };
  }

  SourceRef _decodeSourceRef(Object? json) {
    final sourceRef = _expectUntypedObject(json, 'Source reference');
    final type = _expectString(sourceRef['type'], 'source reference type');
    return switch (type) {
      'document' => _decodeDocumentSourceRef(sourceRef),
      'point' => _decodePointSourceRef(sourceRef),
      'range' => _decodeRangeSourceRef(sourceRef),
      _ => throw const FormatException(
          'Source reference type is unsupported.',
        ),
    };
  }

  SourceRef _decodeDocumentSourceRef(Map<String, Object?> sourceRef) {
    _requireExactKeys(sourceRef, _documentSourceKeys, 'Document source');
    return SourceRef.document(
      sourceId: _expectString(sourceRef['sourceId'], 'sourceId'),
      displayLabel: _expectNullableString(
        sourceRef['displayLabel'],
        'displayLabel',
      ),
    );
  }

  SourceRef _decodePointSourceRef(Map<String, Object?> sourceRef) {
    _requireExactKeys(sourceRef, _pointSourceKeys, 'Point source');
    return SourceRef.at(
      sourceId: _expectString(sourceRef['sourceId'], 'sourceId'),
      displayLabel: _expectNullableString(
        sourceRef['displayLabel'],
        'displayLabel',
      ),
      point: _decodeSourcePoint(sourceRef['point']),
    );
  }

  SourceRef _decodeRangeSourceRef(Map<String, Object?> sourceRef) {
    _requireExactKeys(sourceRef, _rangeSourceKeys, 'Range source');
    return SourceRef.range(
      sourceId: _expectString(sourceRef['sourceId'], 'sourceId'),
      displayLabel: _expectNullableString(
        sourceRef['displayLabel'],
        'displayLabel',
      ),
      start: _decodeSourcePoint(sourceRef['start']),
      end: _decodeSourcePoint(sourceRef['end']),
    );
  }

  Map<String, Object?> _encodeSourcePoint(SourcePoint point) {
    if (!point.isBlock) {
      return <String, Object?>{
        'type': 'page',
        'pageNumber': point.pageNumber,
      };
    }
    return <String, Object?>{
      'type': 'block',
      'pageNumber': point.pageNumber,
      'blockId': point.blockId,
      'readingOrder': point.readingOrder,
    };
  }

  SourcePoint _decodeSourcePoint(Object? json) {
    final point = _expectUntypedObject(json, 'Source point');
    final type = _expectString(point['type'], 'source point type');
    return switch (type) {
      'page' => _decodePagePoint(point),
      'block' => _decodeBlockPoint(point),
      _ => throw const FormatException('Source point type is unsupported.'),
    };
  }

  SourcePoint _decodePagePoint(Map<String, Object?> point) {
    _requireExactKeys(point, _pagePointKeys, 'Page source point');
    return SourcePoint.page(
      pageNumber: _expectInt(point['pageNumber'], 'pageNumber'),
    );
  }

  SourcePoint _decodeBlockPoint(Map<String, Object?> point) {
    _requireExactKeys(point, _blockPointKeys, 'Block source point');
    return SourcePoint.block(
      pageNumber: _expectInt(point['pageNumber'], 'pageNumber'),
      blockId: _expectString(point['blockId'], 'blockId'),
      readingOrder: _expectInt(point['readingOrder'], 'readingOrder'),
    );
  }

  Map<String, Object?> _encodeAssetRef(AssetRef asset) {
    return <String, Object?>{
      'assetId': asset.assetId,
      'kind': _encodeAssetKind(asset.kind),
      'mimeType': asset.mimeType,
      'pixelWidth': asset.pixelWidth,
      'pixelHeight': asset.pixelHeight,
    };
  }

  AssetRef _decodeAssetRef(Object? json) {
    final asset = _expectObject(
      json,
      expectedKeys: _assetKeys,
      label: 'Asset reference',
    );
    return AssetRef(
      assetId: _expectString(asset['assetId'], 'assetId'),
      kind: _decodeAssetKind(asset['kind']),
      mimeType: _expectNullableString(asset['mimeType'], 'mimeType'),
      pixelWidth: _expectNullableInt(asset['pixelWidth'], 'pixelWidth'),
      pixelHeight: _expectNullableInt(asset['pixelHeight'], 'pixelHeight'),
    );
  }

  Map<String, Object?> _encodeIssue(ImportIssue issue) {
    return <String, Object?>{
      'code': issue.code,
      'severity': _encodeIssueSeverity(issue.severity),
      'field': issue.field == null ? null : _encodeIssueField(issue.field!),
      'sourceRef':
          issue.sourceRef == null ? null : _encodeSourceRef(issue.sourceRef!),
    };
  }

  ImportIssue _decodeIssue(Object? json) {
    final issue = _expectObject(
      json,
      expectedKeys: _issueKeys,
      label: 'Import issue',
    );
    return ImportIssue(
      code: _expectString(issue['code'], 'issue code'),
      severity: _decodeIssueSeverity(issue['severity']),
      field: issue['field'] == null ? null : _decodeIssueField(issue['field']),
      sourceRef: issue['sourceRef'] == null
          ? null
          : _decodeSourceRef(issue['sourceRef']),
    );
  }

  String _encodeContentRole(SourceContentRole role) {
    return switch (role) {
      SourceContentRole.unknown => 'unknown',
      SourceContentRole.paragraph => 'paragraph',
      SourceContentRole.heading => 'heading',
      SourceContentRole.formula => 'formula',
      SourceContentRole.answerLike => 'answer_like',
    };
  }

  SourceContentRole _decodeContentRole(Object? value) {
    return switch (value) {
      'unknown' => SourceContentRole.unknown,
      'paragraph' => SourceContentRole.paragraph,
      'heading' => SourceContentRole.heading,
      'formula' => SourceContentRole.formula,
      'answer_like' => SourceContentRole.answerLike,
      _ => throw const FormatException(
          'Source content role is unsupported.',
        ),
    };
  }

  String _encodeAssetKind(AssetKind kind) {
    return switch (kind) {
      AssetKind.image => 'image',
    };
  }

  AssetKind _decodeAssetKind(Object? value) {
    return switch (value) {
      'image' => AssetKind.image,
      _ => throw const FormatException('Asset kind is unsupported.'),
    };
  }

  String _encodeIssueSeverity(ImportIssueSeverity severity) {
    return switch (severity) {
      ImportIssueSeverity.error => 'error',
      ImportIssueSeverity.warning => 'warning',
      ImportIssueSeverity.info => 'info',
    };
  }

  ImportIssueSeverity _decodeIssueSeverity(Object? value) {
    return switch (value) {
      'error' => ImportIssueSeverity.error,
      'warning' => ImportIssueSeverity.warning,
      'info' => ImportIssueSeverity.info,
      _ => throw const FormatException(
          'Import issue severity is unsupported.',
        ),
    };
  }

  String _encodeIssueField(ImportIssueField field) {
    return switch (field) {
      ImportIssueField.stem => 'stem',
      ImportIssueField.options => 'options',
      ImportIssueField.answer => 'answer',
      ImportIssueField.explanation => 'explanation',
      ImportIssueField.asset => 'asset',
      ImportIssueField.source => 'source',
      ImportIssueField.question => 'question',
    };
  }

  ImportIssueField _decodeIssueField(Object? value) {
    return switch (value) {
      'stem' => ImportIssueField.stem,
      'options' => ImportIssueField.options,
      'answer' => ImportIssueField.answer,
      'explanation' => ImportIssueField.explanation,
      'asset' => ImportIssueField.asset,
      'source' => ImportIssueField.source,
      'question' => ImportIssueField.question,
      _ => throw const FormatException('Import issue field is unsupported.'),
    };
  }
}

const _rootKeys = <String>{
  'schemaVersion',
  'sourceId',
  'displayLabel',
  'parts',
  'issues',
};
const _contentPartKeys = <String>{'type', 'sourceRef', 'content', 'role'};
const _tablePartKeys = <String>{'type', 'sourceRef', 'rows'};
const _assetPartKeys = <String>{
  'type',
  'sourceRef',
  'asset',
  'alternativeText',
};
const _unsupportedPartKeys = <String>{
  'type',
  'sourceRef',
  'kindCode',
  'fallbackContent',
};
const _documentSourceKeys = <String>{'type', 'sourceId', 'displayLabel'};
const _pointSourceKeys = <String>{
  'type',
  'sourceId',
  'displayLabel',
  'point',
};
const _rangeSourceKeys = <String>{
  'type',
  'sourceId',
  'displayLabel',
  'start',
  'end',
};
const _pagePointKeys = <String>{'type', 'pageNumber'};
const _blockPointKeys = <String>{
  'type',
  'pageNumber',
  'blockId',
  'readingOrder',
};
const _assetKeys = <String>{
  'assetId',
  'kind',
  'mimeType',
  'pixelWidth',
  'pixelHeight',
};
const _issueKeys = <String>{'code', 'severity', 'field', 'sourceRef'};

Map<String, Object?> _expectObject(
  Object? value, {
  required Set<String> expectedKeys,
  required String label,
}) {
  final object = _expectUntypedObject(value, label);
  _requireExactKeys(object, expectedKeys, label);
  return object;
}

Map<String, Object?> _expectUntypedObject(Object? value, String label) {
  if (value is! Map) {
    throw FormatException('$label must be a JSON object.');
  }
  final object = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException('JSON object keys must be strings.');
    }
    object[key] = entry.value;
  }
  return object;
}

void _requireExactKeys(
  Map<String, Object?> object,
  Set<String> expectedKeys,
  String label,
) {
  if (object.length != expectedKeys.length ||
      !expectedKeys.every(object.containsKey)) {
    throw FormatException('$label must contain exactly the schema fields.');
  }
}

List<T> _decodeList<T>(
  Object? value,
  T Function(Object? value) decodeItem,
  String label,
) {
  if (value is! List) {
    throw FormatException('$label must be a JSON array.');
  }
  return value.map(decodeItem).toList();
}

String _expectString(Object? value, String label) {
  if (value is! String) {
    throw FormatException('$label must be a string.');
  }
  return value;
}

String? _expectNullableString(Object? value, String label) {
  if (value == null) return null;
  return _expectString(value, label);
}

int _expectInt(Object? value, String label) {
  if (value is! int) {
    throw FormatException('$label must be an integer.');
  }
  return value;
}

int? _expectNullableInt(Object? value, String label) {
  if (value == null) return null;
  return _expectInt(value, label);
}
