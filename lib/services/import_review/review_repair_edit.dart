import 'dart:convert';

import '../../application/import_review/latex_fragment_repair.dart';
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
      digests: Map<ReviewRepairField, String>.unmodifiable(
        Map<ReviewRepairField, String>.from(digests),
      ),
      fragment: null,
    );
  }

  const ReviewRepairEdit._({required this.digests, required this.fragment});

  static const int schemaVersion = 1;
  static const int fragmentSchemaVersion = 2;
  static final RegExp _digestPattern = RegExp(r'^[0-9a-f]{64}$');

  final Map<ReviewRepairField, String> digests;
  final LatexFragmentRepairMarker? fragment;

  bool get isEmpty => digests.isEmpty;
  bool get isNotEmpty => digests.isNotEmpty;
  bool get isLatexFragment => fragment != null;

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

  factory ReviewRepairEdit.latexFragment({
    required QuestionDraft before,
    required QuestionDraft after,
    required LatexFragmentTarget target,
    required String replacementLatex,
  }) {
    final field = switch (target.field) {
      LatexFragmentField.stem => ReviewRepairField.content,
      LatexFragmentField.options => ReviewRepairField.options,
      LatexFragmentField.contentAnswer => ReviewRepairField.standardAnswer,
      LatexFragmentField.explanation => ReviewRepairField.explanation,
    };
    final originalSource = digestSourceFor(field, before);
    final resultSource = digestSourceFor(field, after);
    if (target.originalFieldDigest != fieldDigest(originalSource) ||
        target.originalLatexDigest != fieldDigest(target.originalLatex) ||
        replacementLatex.trim().isEmpty ||
        originalSource == resultSource) {
      throw const FormatException('invalid LaTeX fragment repair marker');
    }
    final resultDigest = fieldDigest(resultSource);
    final marker = LatexFragmentRepairMarker(
      field: field,
      optionId: target.optionId,
      nodeIndex: target.nodeIndex,
      nodeKind: target.nodeKind,
      originalFieldDigest: target.originalFieldDigest,
      resultFieldDigest: resultDigest,
      originalLatexDigest: target.originalLatexDigest,
      replacementLatexDigest: fieldDigest(replacementLatex),
    );
    return ReviewRepairEdit._(
      digests: Map<ReviewRepairField, String>.unmodifiable(
        <ReviewRepairField, String>{field: resultDigest},
      ),
      fragment: marker,
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
    if (value['schemaVersion'] == fragmentSchemaVersion) {
      return _fragmentFromMap(value);
    }
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
    return ReviewRepairEdit._(
      digests: Map<ReviewRepairField, String>.unmodifiable(digests),
      fragment: null,
    );
  }

  static ReviewRepairEdit? _fragmentFromMap(Map<dynamic, dynamic> value) {
    final field = ReviewRepairField.fromWireKey(value['field']);
    final nodeKind = LatexFragmentNodeKind.fromWireName(value['nodeKind']);
    final optionId = value['optionId'];
    final expectedKeys = <String>{
      'schemaVersion',
      'kind',
      'field',
      'nodeIndex',
      'nodeKind',
      'originalFieldDigest',
      'resultFieldDigest',
      'originalLatexDigest',
      'replacementLatexDigest',
      if (field == ReviewRepairField.options) 'optionId',
    };
    if (value.keys.any((key) => key is! String) ||
        value.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(value.keys.toSet()).isNotEmpty ||
        value['kind'] != 'latex_fragment' ||
        field == null ||
        nodeKind == null ||
        value['nodeIndex'] is! int ||
        (value['nodeIndex'] as int) < 0 ||
        (field == ReviewRepairField.options
            ? optionId is! String || optionId.isEmpty
            : optionId != null)) {
      return null;
    }
    final originalFieldDigest = value['originalFieldDigest'];
    final resultFieldDigest = value['resultFieldDigest'];
    final originalLatexDigest = value['originalLatexDigest'];
    final replacementLatexDigest = value['replacementLatexDigest'];
    if (originalFieldDigest is! String ||
        resultFieldDigest is! String ||
        originalLatexDigest is! String ||
        replacementLatexDigest is! String ||
        !_digestPattern.hasMatch(originalFieldDigest) ||
        !_digestPattern.hasMatch(resultFieldDigest) ||
        !_digestPattern.hasMatch(originalLatexDigest) ||
        !_digestPattern.hasMatch(replacementLatexDigest)) {
      return null;
    }
    final marker = LatexFragmentRepairMarker(
      field: field,
      optionId: optionId as String?,
      nodeIndex: value['nodeIndex'] as int,
      nodeKind: nodeKind,
      originalFieldDigest: originalFieldDigest,
      resultFieldDigest: resultFieldDigest,
      originalLatexDigest: originalLatexDigest,
      replacementLatexDigest: replacementLatexDigest,
    );
    return ReviewRepairEdit._(
      digests: Map<ReviewRepairField, String>.unmodifiable(
        <ReviewRepairField, String>{field: resultFieldDigest},
      ),
      fragment: marker,
    );
  }

  Map<String, Object?> toMap() {
    final fragment = this.fragment;
    if (fragment != null) {
      return <String, Object?>{
        'schemaVersion': fragmentSchemaVersion,
        'kind': 'latex_fragment',
        'field': fragment.field.wireKey,
        if (fragment.optionId != null) 'optionId': fragment.optionId,
        'nodeIndex': fragment.nodeIndex,
        'nodeKind': fragment.nodeKind.wireName,
        'originalFieldDigest': fragment.originalFieldDigest,
        'resultFieldDigest': fragment.resultFieldDigest,
        'originalLatexDigest': fragment.originalLatexDigest,
        'replacementLatexDigest': fragment.replacementLatexDigest,
      };
    }
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'fields': <String, String>{
        for (final entry in digests.entries) entry.key.wireKey: entry.value,
      },
    };
  }
}

final class LatexFragmentRepairMarker {
  const LatexFragmentRepairMarker({
    required this.field,
    required this.optionId,
    required this.nodeIndex,
    required this.nodeKind,
    required this.originalFieldDigest,
    required this.resultFieldDigest,
    required this.originalLatexDigest,
    required this.replacementLatexDigest,
  });

  final ReviewRepairField field;
  final String? optionId;
  final int nodeIndex;
  final LatexFragmentNodeKind nodeKind;
  final String originalFieldDigest;
  final String resultFieldDigest;
  final String originalLatexDigest;
  final String replacementLatexDigest;
}

/// Lowercase hex SHA-256 of [value].
///
/// Both the apply path and the typed commit path call this exact function, so a
/// marker can only ever be satisfied by the bytes it was created from.
String fieldDigest(String value) => sha256Hex(utf8.encode(value));
