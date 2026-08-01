import '../assets/asset_ref.dart';
import '../assets/sourced_asset_ref.dart';
import '../content/rich_content_codec.dart';
import '../import/import_issue.dart';
import '../source/source_ref.dart';
import 'question_draft_v2.dart';

final class QuestionDraftV2Codec {
  const QuestionDraftV2Codec();

  static const int schemaVersion = 2;
  static const RichContentCodec _richContentCodec = RichContentCodec();

  Map<String, Object?> encode(QuestionDraftV2 draft) {
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'questionId': draft.questionId,
      'questionNumber': draft.questionNumber,
      'kind': _encodeQuestionKind(draft.kind),
      'stem': _richContentCodec.encode(draft.stem),
      'options': draft.options.map(_encodeOption).toList(),
      'answer': draft.answer == null ? null : _encodeAnswer(draft.answer!),
      'explanation': draft.explanation == null
          ? null
          : _richContentCodec.encode(draft.explanation!),
      'sourceRefs': draft.sourceRefs.map(_encodeSourceRef).toList(),
      'assetRefs': draft.assetRefs.map(_encodeAssetRef).toList(),
      'issues': draft.issues.map(_encodeIssue).toList(),
    };
  }

  QuestionDraftV2 decode(Object? json) {
    final root = _expectObject(
      json,
      expectedKeys: _rootKeys,
      label: 'QuestionDraftV2 root',
    );

    final version = root['schemaVersion'];
    if (version is! int) {
      throw const FormatException(
        'QuestionDraftV2 schemaVersion must be an integer.',
      );
    }
    if (version != schemaVersion) {
      throw UnsupportedError(
        'Unsupported QuestionDraftV2 schemaVersion: $version.',
      );
    }

    final rawQuestionNumber = root['questionNumber'];
    if (rawQuestionNumber != null && rawQuestionNumber is! int) {
      throw const FormatException(
        'QuestionDraftV2 questionNumber must be an integer or null.',
      );
    }

    return QuestionDraftV2(
      questionId: _expectString(root['questionId'], 'questionId'),
      questionNumber: rawQuestionNumber as int?,
      kind: _decodeQuestionKind(root['kind']),
      stem: _richContentCodec.decode(root['stem']),
      options: _decodeList(root['options'], _decodeOption, 'options'),
      answer: _decodeAnswer(root['answer']),
      explanation: root['explanation'] == null
          ? null
          : _richContentCodec.decode(root['explanation']),
      sourceRefs: _decodeList(
        root['sourceRefs'],
        _decodeSourceRef,
        'sourceRefs',
      ),
      assetRefs: _decodeList(
        root['assetRefs'],
        _decodeAssetRef,
        'assetRefs',
      ),
      issues: _decodeList(root['issues'], _decodeIssue, 'issues'),
    );
  }

  Map<String, Object?> _encodeOption(QuestionOption option) {
    return <String, Object?>{
      'optionId': option.optionId,
      'label': option.label,
      'content': _richContentCodec.encode(option.content),
      'sourceRef':
          option.sourceRef == null ? null : _encodeSourceRef(option.sourceRef!),
    };
  }

  QuestionOption _decodeOption(Object? json) {
    final option = _expectObject(
      json,
      expectedKeys: _optionKeys,
      label: 'Question option',
    );
    return QuestionOption(
      optionId: _expectString(option['optionId'], 'optionId'),
      label: _expectString(option['label'], 'label'),
      content: _richContentCodec.decode(option['content']),
      sourceRef: option['sourceRef'] == null
          ? null
          : _decodeSourceRef(option['sourceRef']),
    );
  }

  Map<String, Object?> _encodeAnswer(QuestionAnswer answer) {
    return switch (answer) {
      ChoiceAnswer(:final optionIds) => <String, Object?>{
          'type': 'choice',
          'optionIds': optionIds.toList(),
        },
      ContentAnswer(:final content) => <String, Object?>{
          'type': 'content',
          'content': _richContentCodec.encode(content),
        },
    };
  }

  QuestionAnswer? _decodeAnswer(Object? json) {
    if (json == null) return null;
    final answer = _expectUntypedObject(json, 'Question answer');
    final type = _expectString(answer['type'], 'answer type');
    return switch (type) {
      'choice' => _decodeChoiceAnswer(answer),
      'content' => _decodeContentAnswer(answer),
      _ => throw const FormatException(
          'Question answer type is unsupported.',
        ),
    };
  }

  ChoiceAnswer _decodeChoiceAnswer(Map<String, Object?> answer) {
    _requireExactKeys(answer, _choiceAnswerKeys, 'Choice answer');
    final optionIds = _decodeList(
      answer['optionIds'],
      (value) => _expectString(value, 'answer optionId'),
      'answer optionIds',
    );
    return ChoiceAnswer(optionIds: optionIds);
  }

  ContentAnswer _decodeContentAnswer(Map<String, Object?> answer) {
    _requireExactKeys(answer, _contentAnswerKeys, 'Content answer');
    return ContentAnswer(
      content: _richContentCodec.decode(answer['content']),
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
      _ => throw const FormatException(
          'Source point type is unsupported.',
        ),
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

  Map<String, Object?> _encodeAssetRef(SourcedAssetRef assetRef) {
    final local = assetRef.asset;
    return <String, Object?>{
      'sourceId': assetRef.sourceId,
      'assetId': local.assetId,
      'kind': _encodeAssetKind(local.kind),
      'mimeType': local.mimeType,
      'pixelWidth': local.pixelWidth,
      'pixelHeight': local.pixelHeight,
    };
  }

  SourcedAssetRef _decodeAssetRef(Object? json) {
    final assetRef = _expectObject(
      json,
      expectedKeys: _assetKeys,
      label: 'Asset reference',
    );
    return SourcedAssetRef(
      sourceId: _expectString(assetRef['sourceId'], 'asset sourceId'),
      asset: AssetRef(
        assetId: _expectString(assetRef['assetId'], 'assetId'),
        kind: _decodeAssetKind(assetRef['kind']),
        mimeType: _expectNullableString(assetRef['mimeType'], 'mimeType'),
        pixelWidth: _expectNullableInt(assetRef['pixelWidth'], 'pixelWidth'),
        pixelHeight: _expectNullableInt(
          assetRef['pixelHeight'],
          'pixelHeight',
        ),
      ),
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
}

const _rootKeys = <String>{
  'schemaVersion',
  'questionId',
  'questionNumber',
  'kind',
  'stem',
  'options',
  'answer',
  'explanation',
  'sourceRefs',
  'assetRefs',
  'issues',
};
const _optionKeys = <String>{'optionId', 'label', 'content', 'sourceRef'};
const _choiceAnswerKeys = <String>{'type', 'optionIds'};
const _contentAnswerKeys = <String>{'type', 'content'};
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
  'sourceId',
  'assetId',
  'kind',
  'mimeType',
  'pixelWidth',
  'pixelHeight',
};
const _issueKeys = <String>{'code', 'severity', 'field', 'sourceRef'};

String _encodeQuestionKind(QuestionKind kind) {
  return switch (kind) {
    QuestionKind.singleChoice => 'single_choice',
    QuestionKind.fillBlank => 'fill_blank',
    QuestionKind.shortAnswer => 'short_answer',
  };
}

QuestionKind _decodeQuestionKind(Object? value) {
  return switch (value) {
    'single_choice' => QuestionKind.singleChoice,
    'fill_blank' => QuestionKind.fillBlank,
    'short_answer' => QuestionKind.shortAnswer,
    _ => throw const FormatException('Question kind is unsupported.'),
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
    _ => throw const FormatException('Import issue severity is unsupported.'),
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
