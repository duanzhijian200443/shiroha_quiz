import 'dart:convert';

import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/content/rich_content_privacy_admission.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../domain/question/question_draft_v2_codec.dart';
import '../../utils/storage_content_normalizer.dart';
import '../models/persisted_question.dart';
import '../models/question.dart';

/// Failure taxonomy of the V2 persistence boundary. The mapper never falls
/// back from a corrupt sidecar to the legacy row.
enum QuestionV2PayloadFailure {
  malformedJson,
  unsupportedSchema,
  schemaMismatch,
  invalidPayload,
  unsafePayload,
}

/// Raised when a V2 sidecar row cannot be decoded safely. The exception
/// carries no raw cause and its text never leaks payload content.
final class QuestionV2PayloadException implements Exception {
  const QuestionV2PayloadException(this.failure) : _redactStorageId = false;

  /// Fixed private construction for an invalid typed storage identity. The
  /// caller can never supply text.
  const QuestionV2PayloadException._invalidStorage()
      : failure = QuestionV2PayloadFailure.invalidPayload,
        _redactStorageId = true;

  final QuestionV2PayloadFailure failure;

  /// Selects the fixed redacted storage-identity diagnostic only.
  final bool _redactStorageId;

  @override
  String toString() {
    final detail = switch (failure) {
      QuestionV2PayloadFailure.malformedJson =>
        'The V2 sidecar payload is not valid JSON.',
      QuestionV2PayloadFailure.unsupportedSchema =>
        'The V2 payload schema is not supported.',
      QuestionV2PayloadFailure.schemaMismatch =>
        'The V2 sidecar schema version and payload root disagree.',
      QuestionV2PayloadFailure.invalidPayload => _redactStorageId
          ? 'The typed question storage identity is invalid: '
              'redacted_storage_id.'
          : 'The V2 payload cannot be read safely.',
      QuestionV2PayloadFailure.unsafePayload =>
        'The V2 payload contains unsafe content.',
    };
    return 'QuestionV2PayloadException(${failure.name}): $detail';
  }
}

/// Raised when a V2 persistence write is blocked because the storage
/// identity or parent metadata cannot be written as a typed row.
final class QuestionV2LegacyMutationBlockedException implements Exception {
  const QuestionV2LegacyMutationBlockedException()
      : _kind = _MutationBlockedKind.generic;

  const QuestionV2LegacyMutationBlockedException._invalidStorageId()
      : _kind = _MutationBlockedKind.invalidStorageId;

  const QuestionV2LegacyMutationBlockedException._invalidBankMetadata()
      : _kind = _MutationBlockedKind.invalidBankMetadata;

  final _MutationBlockedKind _kind;

  @override
  String toString() {
    final detail = switch (_kind) {
      _MutationBlockedKind.generic =>
        'V2 persistence requires a canonical storage identity.',
      _MutationBlockedKind.invalidStorageId =>
        'V2 persistence requires a canonical storage identity '
            '(redacted_storage_id).',
      _MutationBlockedKind.invalidBankMetadata =>
        'V2 persistence requires a non-empty bank name.',
    };
    return 'QuestionV2LegacyMutationBlockedException: $detail';
  }
}

enum _MutationBlockedKind { generic, invalidStorageId, invalidBankMetadata }

/// Immutable write package containing the V1 compatibility row and the V2
/// sidecar payload row produced by [QuestionV2PersistenceMapper.freezeForWrite].
final class FrozenQuestionV2Write {
  FrozenQuestionV2Write({
    required Map<String, Object?> questionRow,
    required Map<String, Object?> payloadRow,
  })  : questionRow = Map<String, Object?>.unmodifiable(questionRow),
        payloadRow = Map<String, Object?>.unmodifiable(payloadRow);

  final Map<String, Object?> questionRow;
  final Map<String, Object?> payloadRow;
}

final class QuestionV2PersistenceMapper {
  const QuestionV2PersistenceMapper();

  /// Joined-row aliases for the V2 sidecar columns.
  static const String payloadSchemaVersionAlias = 'v2_payload_schema_version';
  static const String payloadJsonAlias = 'v2_payload_json';

  static final RegExp _canonicalUuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
    r'[0-9a-f]{12}$',
  );

  /// Validates the V2 write metadata, privacy, and encoding, then freezes an
  /// unmodifiable V1 compatibility row plus the V2 sidecar payload row.
  FrozenQuestionV2Write freezeForWrite({
    required String storageId,
    required String bankName,
    required int createdAt,
    required QuestionDraftV2 draft,
  }) {
    if (!_canonicalUuidV4Pattern.hasMatch(storageId)) {
      throw const QuestionV2LegacyMutationBlockedException._invalidStorageId();
    }
    final trimmedBankName = bankName.trim();
    if (trimmedBankName.isEmpty) {
      throw const QuestionV2LegacyMutationBlockedException
          ._invalidBankMetadata();
    }
    try {
      _validatePrivacy(draft);
    } on FormatException {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.unsafePayload,
      );
    }

    // The full V2 payload is encoded directly and never passes through the
    // legacy storage normalizer.
    final payloadJson = jsonEncode(const QuestionDraftV2Codec().encode(draft));

    final projectedStem = _projectContent(draft.stem);
    final content =
        projectedStem.trim().isEmpty ? _emptyStemPlaceholder : projectedStem;
    final options = <String>[
      for (final option in draft.options)
        '${option.label}. ${_projectContent(option.content)}',
    ];
    final answer =
        _projectAnswer(draft.answer, draft.options).replaceAll('|||', '｜｜｜');
    final explanation =
        draft.explanation == null ? '' : _projectContent(draft.explanation!);

    // Every stored V1 textual projection is normalized exactly once; the
    // composed standard_answer reuses already-normalized parts.
    final normalizedContent =
        StorageContentNormalizer.normalizeLegacyProjection(content);
    final normalizedOptions = <String>[
      for (final option in options)
        StorageContentNormalizer.normalizeLegacyProjection(option),
    ];
    final normalizedAnswer =
        StorageContentNormalizer.normalizeLegacyProjection(answer);
    final normalizedExplanation =
        StorageContentNormalizer.normalizeLegacyProjection(explanation);

    final questionRow = <String, Object?>{
      'id': storageId,
      'type': _legacyTypeCode(draft.kind),
      'content': normalizedContent,
      'options': jsonEncode(normalizedOptions),
      'standard_answer': '$normalizedAnswer|||$normalizedExplanation',
      'created_at': createdAt,
      'bank_name': trimmedBankName,
      'explanation': normalizedExplanation,
      'raw_explanation': null,
    };
    final payloadRow = <String, Object?>{
      'question_id': storageId,
      'payload_schema_version': QuestionDraftV2Codec.schemaVersion,
      'payload_json': payloadJson,
    };
    return FrozenQuestionV2Write(
      questionRow: questionRow,
      payloadRow: payloadRow,
    );
  }

  /// Decodes one joined V1/V2 row in the frozen strict order. A wholly
  /// absent sidecar is legacy; any corrupt or unsafe sidecar fails instead of
  /// falling back to the V1 row.
  PersistedQuestion decodeJoinedRow(Map<String, Object?> row) {
    final versionValue = row[payloadSchemaVersionAlias];
    final jsonValue = row[payloadJsonAlias];

    if (versionValue == null && jsonValue == null) {
      return LegacyPersistedQuestion(
        question: Question.fromMap(
          <String, dynamic>{
            for (final entry in row.entries) entry.key: entry.value,
          },
        ),
      );
    }
    if (versionValue == null || jsonValue == null) {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.invalidPayload,
      );
    }

    final storageId = _requireTypedStorageId(row);
    final bankName = _requireTypedBankName(row);
    final createdAt = _requireTypedCreatedAt(row);

    final version = versionValue;
    if (version is! int || version <= 0) {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.invalidPayload,
      );
    }

    final payloadText = jsonValue;
    if (payloadText is! String) {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.invalidPayload,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(payloadText);
    } on FormatException {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.malformedJson,
      );
    }

    final root = _requireStringKeyedObject(decoded);
    final rootVersion = root['schemaVersion'];
    if (rootVersion is! int) {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.invalidPayload,
      );
    }
    if (rootVersion != version) {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.schemaMismatch,
      );
    }
    if (rootVersion != QuestionDraftV2Codec.schemaVersion) {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.unsupportedSchema,
      );
    }

    final QuestionDraftV2 draft;
    try {
      draft = const QuestionDraftV2Codec().decode(root);
    } on FormatException {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.invalidPayload,
      );
    } on UnsupportedError {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.invalidPayload,
      );
    }

    try {
      _validatePrivacy(draft);
    } on FormatException {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.unsafePayload,
      );
    }

    return TypedPersistedQuestion(
      storageId: storageId,
      bankName: bankName,
      createdAt: createdAt,
      draft: draft,
    );
  }

  String _requireTypedStorageId(Map<String, Object?> row) {
    final value = row['id'];
    if (value is String && _canonicalUuidV4Pattern.hasMatch(value)) {
      return value;
    }
    throw const QuestionV2PayloadException._invalidStorage();
  }

  String _requireTypedBankName(Map<String, Object?> row) {
    final value = row['bank_name'];
    if (value is String && value.trim().isNotEmpty) {
      return value;
    }
    throw const QuestionV2PayloadException(
      QuestionV2PayloadFailure.invalidPayload,
    );
  }

  int _requireTypedCreatedAt(Map<String, Object?> row) {
    final value = row['created_at'];
    if (value is int) {
      return value;
    }
    throw const QuestionV2PayloadException(
      QuestionV2PayloadFailure.invalidPayload,
    );
  }

  Map<String, Object?> _requireStringKeyedObject(Object? value) {
    if (value is! Map) {
      throw const QuestionV2PayloadException(
        QuestionV2PayloadFailure.invalidPayload,
      );
    }
    final root = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const QuestionV2PayloadException(
          QuestionV2PayloadFailure.invalidPayload,
        );
      }
      root[key] = entry.value;
    }
    return root;
  }
}

void _validatePrivacy(QuestionDraftV2 draft) {
  const admission = RichContentPrivacyAdmission();
  admission.validate(draft.stem);
  for (final option in draft.options) {
    admission.validate(option.content);
  }
  if (draft.answer case ContentAnswer(:final content)) {
    admission.validate(content);
  }
  if (draft.explanation != null) {
    admission.validate(draft.explanation!);
  }
}

const String _emptyStemPlaceholder = '无题干';
const String _unsupportedContentPlaceholder = '[Unsupported content]';

int _legacyTypeCode(QuestionKind kind) {
  return switch (kind) {
    QuestionKind.singleChoice => 0,
    QuestionKind.fillBlank => 2,
    QuestionKind.shortAnswer => 3,
  };
}

String _projectContent(RichContent content) {
  final buffer = StringBuffer();
  for (final node in content.nodes) {
    switch (node) {
      case TextNode(:final text):
        buffer.write(text);
      case InlineMathNode(:final latex):
        buffer.write(r'\(');
        buffer.write(latex);
        buffer.write(r'\)');
      case BlockMathNode(:final latex):
        buffer.write(r'\[');
        buffer.write(latex);
        buffer.write(r'\]');
      case RawFallbackNode():
        buffer.write(_unsupportedContentPlaceholder);
    }
  }
  return buffer.toString();
}

String _projectAnswer(
  QuestionAnswer? answer,
  List<QuestionOption> options,
) {
  return switch (answer) {
    null => '',
    ContentAnswer(:final content) => _projectContent(content),
    ChoiceAnswer(:final optionIds) => optionIds
        .map((optionId) => _optionLabelOrIdentity(optionId, options))
        .join(','),
  };
}

String _optionLabelOrIdentity(String optionId, List<QuestionOption> options) {
  for (final option in options) {
    if (option.optionId == optionId) {
      return option.label;
    }
  }
  return optionId;
}
