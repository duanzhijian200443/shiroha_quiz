import 'content_node.dart';
import 'rich_content.dart';
import 'rich_content_limits.dart';

final class RichContentPrivacyAdmission {
  const RichContentPrivacyAdmission();

  void validate(RichContent content) {
    _visitContent(
      content,
      state: _AdmissionState(),
      depth: 0,
      context: _ContentContext.root,
    );
  }
}

enum _ContentContext { root, imageAlternative, tableCell }

final class _AdmissionState {
  int nodeCount = 0;
  int scalarCount = 0;
  int imageCount = 0;
  int rawEntryCount = 0;
}

void _visitContent(
  RichContent content, {
  required _AdmissionState state,
  required int depth,
  required _ContentContext context,
}) {
  _checkDepth(depth);
  for (final node in content.nodes) {
    state.nodeCount++;
    if (state.nodeCount > RichContentLimits.maxNodes) {
      throw const FormatException('RichContent node limit exceeded.');
    }

    switch (node) {
      case TextNode(:final text):
        _countScalarText(text, state);
      case InlineMathNode(:final latex):
        _countScalarText(latex, state);
      case BlockMathNode(:final latex):
        _countScalarText(latex, state);
      case ImageNode(
          :final sourceId,
          :final localAssetId,
          :final alternativeText,
        ):
        if (context == _ContentContext.imageAlternative) {
          throw const FormatException(
            'Image alternative text may not contain images.',
          );
        }
        _countScalarText(sourceId, state);
        _countScalarText(localAssetId, state);
        state.imageCount++;
        if (state.imageCount > RichContentLimits.maxImages) {
          throw const FormatException('RichContent image limit exceeded.');
        }
        if (alternativeText != null) {
          _visitContent(
            alternativeText,
            state: state,
            depth: depth + 1,
            context: _ContentContext.imageAlternative,
          );
        }
      case TableNode(:final structure):
        if (context != _ContentContext.root) {
          throw const FormatException(
            'Tables may not be nested in constrained RichContent.',
          );
        }
        _visitTable(structure, state: state, depth: depth);
      case RawFallbackNode(:final rawJson):
        if (context != _ContentContext.root) {
          throw const FormatException(
            'Raw fallback nodes are not allowed in constrained RichContent.',
          );
        }
        _validateFallbackValue(rawJson, state: state, depth: depth + 1);
    }
  }
}

void _visitTable(
  TableStructure structure, {
  required _AdmissionState state,
  required int depth,
}) {
  if (structure.rows.isEmpty ||
      structure.rows.length > RichContentLimits.maxTableRows) {
    throw const FormatException('Table row limit exceeded.');
  }
  if (structure.columnCount <= 0 ||
      structure.columnCount > RichContentLimits.maxTableColumns) {
    throw const FormatException('Table column limit exceeded.');
  }
  if (structure.rows.fold<int>(0, (sum, row) => sum + row.cells.length) >
      RichContentLimits.maxTableLogicalCells) {
    throw const FormatException('Table logical cell limit exceeded.');
  }
  if (structure.expandedCellCount > RichContentLimits.maxTableExpandedCells) {
    throw const FormatException('Table expanded cell limit exceeded.');
  }

  for (final row in structure.rows) {
    for (final cell in row.cells) {
      _visitContent(
        cell.content,
        state: state,
        depth: depth + 1,
        context: _ContentContext.tableCell,
      );
    }
  }
}

void _checkDepth(int depth) {
  if (depth > RichContentLimits.maxDepth) {
    throw const FormatException('RichContent recursion limit exceeded.');
  }
}

void _countScalarText(String value, _AdmissionState state) {
  final length = value.runes.length;
  if (length > RichContentLimits.maxNodeScalars) {
    throw const FormatException('RichContent node scalar limit exceeded.');
  }
  state.scalarCount += length;
  if (state.scalarCount > RichContentLimits.maxScalars) {
    throw const FormatException('RichContent scalar limit exceeded.');
  }
}

final _fallbackKeySeparatorPattern = RegExp(r'[^a-z0-9]');
final _forbiddenFallbackStringPattern = RegExp(
  r'^(?:(?:file|https?)://|data:[^,]*;base64,|[a-z]:[\\/]|\\\\|/)',
  caseSensitive: false,
);

const _forbiddenFallbackKeys = <String>{
  'path',
  'absolutepath',
  'originalpath',
  'resolvedpath',
  'extractedpath',
  'cachepath',
  'temporarypath',
  'relativepath',
  'directorypath',
  'filepath',
  'localpath',
  'sourcepath',
  'assetpath',
  'uri',
  'url',
  'base64',
  'bytes',
  'rawtext',
  'fullcontent',
  'providertext',
  'rawresponse',
  'providerrequest',
  'providerresponse',
  'providerbody',
  'requestbody',
  'responsebody',
  'diagnostic',
  'diagnostics',
  'preview',
  'exception',
  'exceptionmessage',
  'stacktrace',
  'credential',
  'credentials',
  'apikey',
  'accesstoken',
  'refreshtoken',
  'authtoken',
  'bearertoken',
  'authorization',
  'password',
  'secret',
  'clientsecret',
  'relationshipid',
};

void _validateFallbackValue(
  Object? value, {
  required _AdmissionState state,
  required int depth,
}) {
  _checkDepth(depth);
  if (value is Map) {
    state.rawEntryCount += value.length;
    if (state.rawEntryCount > RichContentLimits.maxRawCollectionEntries) {
      throw const FormatException('RichContent fallback bound exceeded.');
    }
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String && _isForbiddenFallbackKey(key)) {
        throw const FormatException(
          'Source fallback content contains prohibited side-channel metadata.',
        );
      }
      _countScalarText(key is String ? key : '', state);
      _validateFallbackValue(
        entry.value,
        state: state,
        depth: depth + 1,
      );
    }
    return;
  }
  if (value is Iterable) {
    final length = value.length;
    state.rawEntryCount += length;
    if (state.rawEntryCount > RichContentLimits.maxRawCollectionEntries) {
      throw const FormatException('RichContent fallback bound exceeded.');
    }
    for (final item in value) {
      _validateFallbackValue(item, state: state, depth: depth + 1);
    }
    return;
  }
  if (value is String) {
    _countScalarText(value, state);
    if (_forbiddenFallbackStringPattern.hasMatch(value.trimLeft())) {
      throw const FormatException(
        'Source fallback content contains a prohibited locator value.',
      );
    }
    return;
  }
  if (value == null || value is bool || value is num) return;
  throw const FormatException(
      'RichContent fallback contains an invalid value.');
}

bool _isForbiddenFallbackKey(String key) {
  final normalized =
      key.toLowerCase().replaceAll(_fallbackKeySeparatorPattern, '');
  return _forbiddenFallbackKeys.contains(normalized) ||
      normalized.endsWith('url') ||
      normalized.endsWith('uri') ||
      normalized.endsWith('base64') ||
      normalized.endsWith('bytes') ||
      normalized.endsWith('credential') ||
      normalized.endsWith('credentials') ||
      normalized.endsWith('apikey') ||
      (normalized.contains('provider') &&
          (normalized.contains('request') ||
              normalized.contains('response') ||
              normalized.contains('body')));
}
