import 'package:shiroha_quiz/domain/content/rich_content_privacy_admission.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';

/// Task-level storage route for imported review data.
///
/// R7A only defines, parses and preserves this metadata. Deciding which
/// production OCR tasks use a typed route belongs to a later stage.
enum ImportStorageRoute {
  legacyV1,
  typedV2,
}

/// Stable serialized value for [ImportStorageRoute].
String importStorageRouteSerialization(ImportStorageRoute route) {
  return switch (route) {
    ImportStorageRoute.legacyV1 => 'legacyV1',
    ImportStorageRoute.typedV2 => 'typedV2',
  };
}

/// Decodes a task-level storage route scalar.
///
/// Missing declarations are historical tasks and decode as [legacyV1].
/// Unknown route values fail instead of silently falling back.
ImportStorageRoute decodeImportStorageRoute(Object? value) {
  return switch (value) {
    null || 'legacyV1' => ImportStorageRoute.legacyV1,
    'typedV2' => ImportStorageRoute.typedV2,
    _ => throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.invalidEnvelope,
      ),
  };
}

final _lowerSnakeCasePattern = RegExp(r'^[a-z0-9]+(?:_[a-z0-9]+)*$');
const int _maxStorageReasonLength = 64;

/// Whether [value] is a bounded lower_snake_case reason scalar.
bool isValidImportStorageReason(String value) {
  return value.isNotEmpty &&
      value.length <= _maxStorageReasonLength &&
      _lowerSnakeCasePattern.hasMatch(value);
}

/// Normalizes a task-level storage reason scalar.
///
/// Returns `null` for an absent reason and throws a fixed exception for any
/// value that is not a bounded lower_snake_case string.
String? normalizeImportStorageReason(Object? value) {
  if (value == null) return null;
  if (value is String && isValidImportStorageReason(value)) return value;
  throw const TypedReviewSnapshotException(
    TypedReviewSnapshotFailure.invalidEnvelope,
  );
}

final _canonicalUuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Whether [value] is a lowercase canonical UUIDv4.
bool isCanonicalUuidV4(String value) {
  return _canonicalUuidV4Pattern.hasMatch(value);
}

/// Fixed failure classification for typed review snapshots.
enum TypedReviewSnapshotFailure {
  /// The typed envelope key is absent.
  missingPayload,

  /// The envelope schema version is unsupported.
  unsupportedSchema,

  /// The envelope structure, route scalar or baseline is invalid.
  invalidEnvelope,

  /// An identifier is not a canonical UUIDv4 or does not match the draft.
  invalidIdentity,

  /// The envelope route contradicts the typed storage route.
  routeMismatch,

  /// A RichContent field failed privacy admission.
  unsafePayload,
}

/// Safe fixed exception for typed review snapshot failures.
///
/// Carries only the failure classification. [toString] returns fixed text and
/// never includes payloads, question text, answers, explanations, source IDs,
/// paths, URLs, base64, Provider content, tokens, raw JSON or causes.
final class TypedReviewSnapshotException implements Exception {
  const TypedReviewSnapshotException(this.failure);

  final TypedReviewSnapshotFailure failure;

  @override
  String toString() {
    return switch (failure) {
      TypedReviewSnapshotFailure.missingPayload =>
        'Typed review snapshot payload is missing.',
      TypedReviewSnapshotFailure.unsupportedSchema =>
        'Typed review snapshot schema version is unsupported.',
      TypedReviewSnapshotFailure.invalidEnvelope =>
        'Typed review snapshot envelope is invalid.',
      TypedReviewSnapshotFailure.invalidIdentity =>
        'Typed review snapshot identity is invalid.',
      TypedReviewSnapshotFailure.routeMismatch =>
        'Typed review snapshot route does not match.',
      TypedReviewSnapshotFailure.unsafePayload =>
        'Typed review snapshot payload is unsafe.',
    };
  }
}

/// Immutable typed value object for the legacy V1 review baseline.
///
/// Fields are strictly decoded; `options` is a defensive unmodifiable copy.
/// No raw explanations, paths, diagnostics, Provider content or extension
/// fields are representable.
final class LegacyReviewBaseline {
  factory LegacyReviewBaseline({
    required int type,
    required int? questionNumber,
    required String content,
    required List<String> options,
    required String standardAnswer,
    required String explanation,
  }) {
    if (type != 0 && type != 2 && type != 3) {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.invalidEnvelope,
      );
    }
    if (questionNumber != null && questionNumber <= 0) {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.invalidEnvelope,
      );
    }
    return LegacyReviewBaseline._(
      type: type,
      questionNumber: questionNumber,
      content: content,
      options: List<String>.unmodifiable(options),
      standardAnswer: standardAnswer,
      explanation: explanation,
    );
  }

  const LegacyReviewBaseline._({
    required this.type,
    required this.questionNumber,
    required this.content,
    required this.options,
    required this.standardAnswer,
    required this.explanation,
  });

  final int type;
  final int? questionNumber;
  final String content;
  final List<String> options;
  final String standardAnswer;
  final String explanation;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LegacyReviewBaseline &&
            type == other.type &&
            questionNumber == other.questionNumber &&
            content == other.content &&
            _orderedEquals(options, other.options) &&
            standardAnswer == other.standardAnswer &&
            explanation == other.explanation;
  }

  @override
  int get hashCode => Object.hash(
        type,
        questionNumber,
        content,
        Object.hashAll(options),
        standardAnswer,
        explanation,
      );
}

/// Immutable typed review snapshot.
final class TypedReviewSnapshot {
  const TypedReviewSnapshot({
    required this.reviewItemId,
    required this.questionId,
    required this.draft,
    required this.baselineLegacy,
  });

  final String reviewItemId;
  final String questionId;
  final QuestionDraftV2 draft;
  final LegacyReviewBaseline baselineLegacy;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TypedReviewSnapshot &&
            reviewItemId == other.reviewItemId &&
            questionId == other.questionId &&
            draft == other.draft &&
            baselineLegacy == other.baselineLegacy;
  }

  @override
  int get hashCode => Object.hash(
        reviewItemId,
        questionId,
        draft,
        baselineLegacy,
      );
}

/// Strict exact-key codec for the per-question typed review envelope.
///
/// The root object accepts exactly six keys and the draft must be encoded with
/// the existing [QuestionDraftV2Codec]. Privacy admission runs before every
/// encode and after every decode. There is deliberately no lenient `tryDecode`:
/// a present but corrupt payload always throws the fixed exception.
final class TypedReviewSnapshotCodec {
  const TypedReviewSnapshotCodec();

  /// Reserved per-question envelope key. Never renamed or duplicated.
  static const String mapKey = '_typed_review_v1';

  static const int schemaVersion = 1;
  static const String routeValue = 'typedV2';

  static const QuestionDraftV2Codec _draftCodec = QuestionDraftV2Codec();
  static const RichContentPrivacyAdmission _privacyAdmission =
      RichContentPrivacyAdmission();

  /// Whether [questionMap] carries the typed envelope key at all.
  ///
  /// This only distinguishes key presence. When the key is present,
  /// [decodeRequired] must be used; corrupt payloads never decode leniently.
  bool containsEnvelope(Object? questionMap) {
    return questionMap is Map && questionMap.containsKey(mapKey);
  }

  /// Blocks a task whose route is typed when a question lacks a valid typed
  /// envelope. A typed route must never silently fall back to V1.
  void requireTypedEnvelope(ImportStorageRoute route, Object? questionMap) {
    if (route == ImportStorageRoute.typedV2 && !containsEnvelope(questionMap)) {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.routeMismatch,
      );
    }
  }

  Map<String, Object?> encode(TypedReviewSnapshot snapshot) {
    if (!isCanonicalUuidV4(snapshot.reviewItemId) ||
        !isCanonicalUuidV4(snapshot.questionId)) {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.invalidIdentity,
      );
    }
    if (snapshot.questionId != snapshot.draft.questionId) {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.invalidIdentity,
      );
    }
    _admitDraft(snapshot.draft);
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'route': routeValue,
      'reviewItemId': snapshot.reviewItemId,
      'questionId': snapshot.questionId,
      'draft': _draftCodec.encode(snapshot.draft),
      'baselineLegacy': _encodeBaseline(snapshot.baselineLegacy),
    };
  }

  TypedReviewSnapshot decodeRequired(Object? value) {
    if (value == null) {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.missingPayload,
      );
    }
    final root = _expectStringKeyedMap(value);
    _requireExactKeys(
      root,
      _rootKeys,
      TypedReviewSnapshotFailure.invalidEnvelope,
    );

    final version = root['schemaVersion'];
    if (version is! int || version != schemaVersion) {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.unsupportedSchema,
      );
    }

    final route = root['route'];
    if (route is! String) {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.invalidEnvelope,
      );
    }
    switch (route) {
      case 'typedV2':
        break;
      case 'legacyV1':
        throw const TypedReviewSnapshotException(
          TypedReviewSnapshotFailure.routeMismatch,
        );
      default:
        throw const TypedReviewSnapshotException(
          TypedReviewSnapshotFailure.invalidEnvelope,
        );
    }

    final reviewItemId = _expectString(
      root['reviewItemId'],
      TypedReviewSnapshotFailure.invalidEnvelope,
    );
    final questionId = _expectString(
      root['questionId'],
      TypedReviewSnapshotFailure.invalidEnvelope,
    );
    if (!isCanonicalUuidV4(reviewItemId) || !isCanonicalUuidV4(questionId)) {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.invalidIdentity,
      );
    }

    final QuestionDraftV2 draft;
    try {
      draft = _draftCodec.decode(root['draft']);
    } on FormatException {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.invalidEnvelope,
      );
    } on UnsupportedError {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.invalidEnvelope,
      );
    }
    if (draft.questionId != questionId) {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.invalidIdentity,
      );
    }

    final baselineLegacy = _decodeBaseline(root['baselineLegacy']);
    _admitDraft(draft);
    return TypedReviewSnapshot(
      reviewItemId: reviewItemId,
      questionId: questionId,
      draft: draft,
      baselineLegacy: baselineLegacy,
    );
  }

  void _admitDraft(QuestionDraftV2 draft) {
    try {
      _privacyAdmission.validate(draft.stem);
      for (final option in draft.options) {
        _privacyAdmission.validate(option.content);
      }
      if (draft.answer case ContentAnswer(:final content)) {
        _privacyAdmission.validate(content);
      }
      final explanation = draft.explanation;
      if (explanation != null) {
        _privacyAdmission.validate(explanation);
      }
    } on FormatException {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.unsafePayload,
      );
    }
  }

  Map<String, Object?> _encodeBaseline(LegacyReviewBaseline baseline) {
    return <String, Object?>{
      'type': baseline.type,
      'questionNumber': baseline.questionNumber,
      'content': baseline.content,
      'options': List<String>.from(baseline.options),
      'standardAnswer': baseline.standardAnswer,
      'explanation': baseline.explanation,
    };
  }

  LegacyReviewBaseline _decodeBaseline(Object? value) {
    final map = _expectStringKeyedMap(value);
    _requireExactKeys(
      map,
      _baselineKeys,
      TypedReviewSnapshotFailure.invalidEnvelope,
    );
    return LegacyReviewBaseline(
      type: _expectInt(
        map['type'],
        TypedReviewSnapshotFailure.invalidEnvelope,
      ),
      questionNumber: _expectNullablePositiveInt(
        map['questionNumber'],
        TypedReviewSnapshotFailure.invalidEnvelope,
      ),
      content: _expectString(
        map['content'],
        TypedReviewSnapshotFailure.invalidEnvelope,
      ),
      options: _expectStringList(
        map['options'],
        TypedReviewSnapshotFailure.invalidEnvelope,
      ),
      standardAnswer: _expectString(
        map['standardAnswer'],
        TypedReviewSnapshotFailure.invalidEnvelope,
      ),
      explanation: _expectString(
        map['explanation'],
        TypedReviewSnapshotFailure.invalidEnvelope,
      ),
    );
  }
}

const _rootKeys = <String>{
  'schemaVersion',
  'route',
  'reviewItemId',
  'questionId',
  'draft',
  'baselineLegacy',
};

const _baselineKeys = <String>{
  'type',
  'questionNumber',
  'content',
  'options',
  'standardAnswer',
  'explanation',
};

Map<String, Object?> _expectStringKeyedMap(Object? value) {
  if (value is! Map) {
    throw const TypedReviewSnapshotException(
      TypedReviewSnapshotFailure.invalidEnvelope,
    );
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const TypedReviewSnapshotException(
        TypedReviewSnapshotFailure.invalidEnvelope,
      );
    }
    result[key] = entry.value;
  }
  return result;
}

void _requireExactKeys(
  Map<String, Object?> object,
  Set<String> expectedKeys,
  TypedReviewSnapshotFailure failure,
) {
  if (object.length != expectedKeys.length ||
      !expectedKeys.every(object.containsKey)) {
    throw TypedReviewSnapshotException(failure);
  }
}

String _expectString(Object? value, TypedReviewSnapshotFailure failure) {
  if (value is! String) {
    throw TypedReviewSnapshotException(failure);
  }
  return value;
}

int _expectInt(Object? value, TypedReviewSnapshotFailure failure) {
  if (value is! int) {
    throw TypedReviewSnapshotException(failure);
  }
  return value;
}

int? _expectNullablePositiveInt(
  Object? value,
  TypedReviewSnapshotFailure failure,
) {
  if (value == null) return null;
  if (value is int && value > 0) return value;
  throw TypedReviewSnapshotException(failure);
}

List<String> _expectStringList(
  Object? value,
  TypedReviewSnapshotFailure failure,
) {
  if (value is! List) {
    throw TypedReviewSnapshotException(failure);
  }
  final result = <String>[];
  for (final item in value) {
    if (item is! String) {
      throw TypedReviewSnapshotException(failure);
    }
    result.add(item);
  }
  return result;
}

bool _orderedEquals(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
