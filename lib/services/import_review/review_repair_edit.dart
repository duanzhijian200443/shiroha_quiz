import 'dart:convert';

import '../../data/models/question_draft.dart';
import '../backup/sha256.dart';

/// One review field that an AI repair is allowed to rewrite.
///
/// Wire keys are the frozen safe field names already used by
/// `ImportReviewMetadata.latexInvalidFields`; they are never renamed.
enum ReviewRepairField {
  content('content'),
  options('options'),
  standardAnswer('standard_answer'),
  explanation('explanation');

  const ReviewRepairField(this.wireKey);

  final String wireKey;

  static ReviewRepairField? fromWireKey(Object? value) {
    final key = value?.toString().trim();
    for (final field in ReviewRepairField.values) {
      if (field.wireKey == key) return field;
    }
    return null;
  }
}

/// Bounded, sanitized record of which review fields currently hold text that an
/// accepted AI repair produced and that local validation accepted.
///
/// Only a digest of the exact validated text is recorded. At typed commit time
/// the structural representation is rebuilt from the current field text only
/// while that text still matches the recorded digest, so a later unrelated edit
/// is never reinterpreted as markup. Manual edits therefore keep the frozen
/// literal-text semantics; only the exact repaired text is represented
/// structurally.
final class ReviewRepairEdit {
  factory ReviewRepairEdit({required Map<ReviewRepairField, String> digests}) {
    if (digests.isEmpty) {
      throw const FormatException('review repair edit requires a field');
    }
    for (final entry in digests.entries) {
      if (!_digestPattern.hasMatch(entry.value)) {
        throw const FormatException('invalid review repair digest');
      }
    }
    return ReviewRepairEdit._(
      Map<ReviewRepairField, String>.unmodifiable(
        Map<ReviewRepairField, String>.from(digests),
      ),
    );
  }

  const ReviewRepairEdit._(this.digests);

  static const int schemaVersion = 1;
  static final RegExp _digestPattern = RegExp(r'^[0-9a-f]{64}$');

  final Map<ReviewRepairField, String> digests;

  bool get isEmpty => digests.isEmpty;
  bool get isNotEmpty => digests.isNotEmpty;

  /// Builds the marker for the fields that changed in [after] relative to
  /// [before]. Digests are taken from [after], which must already hold the
  /// value that is about to be applied and persisted.
  factory ReviewRepairEdit.applied({
    required QuestionDraft before,
    required QuestionDraft after,
    Iterable<ReviewRepairField>? fields,
  }) {
    final changed = fields ??
        ReviewRepairField.values.where(
          (field) =>
              digestSourceFor(field, before) != digestSourceFor(field, after),
        );
    return ReviewRepairEdit(
      digests: <ReviewRepairField, String>{
        for (final field in changed)
          field: fieldDigest(digestSourceFor(field, after)),
      },
    );
  }

  /// The exact text this marker is computed from for [field].
  ///
  /// The option list is joined with a separator that cannot appear inside a
  /// persisted option body, so option boundaries stay significant.
  static String digestSourceFor(ReviewRepairField field, QuestionDraft draft) {
    return switch (field) {
      ReviewRepairField.content => draft.content,
      ReviewRepairField.options => draft.options.join('\u0000'),
      ReviewRepairField.standardAnswer => draft.standardAnswer,
      ReviewRepairField.explanation => draft.explanation,
    };
  }

  /// Whether the recorded digest still describes [value] for [field].
  bool isSatisfiedBy(ReviewRepairField field, String value) {
    final digest = digests[field];
    return digest != null && digest == fieldDigest(value);
  }

  /// Whether the recorded digest still describes [field] inside [draft].
  bool isSatisfiedByDraft(ReviewRepairField field, QuestionDraft draft) {
    return isSatisfiedBy(field, digestSourceFor(field, draft));
  }

  /// Strict decode of the persisted marker map. Any anomaly yields `null`, so
  /// an unrecognized or corrupt marker never grants structural treatment.
  static ReviewRepairEdit? fromMap(Object? value) {
    if (value is! Map) return null;
    if (value['schemaVersion'] != schemaVersion) return null;
    final rawFields = value['fields'];
    if (rawFields is! Map || rawFields.isEmpty) return null;
    final digests = <ReviewRepairField, String>{};
    for (final entry in rawFields.entries) {
      final field = ReviewRepairField.fromWireKey(entry.key);
      if (field == null) return null;
      final digest = entry.value?.toString();
      if (digest == null || !_digestPattern.hasMatch(digest)) return null;
      digests[field] = digest;
    }
    if (digests.isEmpty) return null;
    return ReviewRepairEdit._(digests);
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'fields': <String, String>{
        for (final entry in digests.entries) entry.key.wireKey: entry.value,
      },
    };
  }
}

/// Lowercase hex SHA-256 of [value].
///
/// Both the apply path and the typed commit path call this exact function, so a
/// marker can only ever be satisfied by the bytes it was created from.
String fieldDigest(String value) => sha256Hex(utf8.encode(value));
