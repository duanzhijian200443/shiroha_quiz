import 'dart:convert';

import 'package:shiroha_quiz/domain/answer_completion/imported_question_set.dart';

/// Reserved import-task diagnostics key carrying the strict QuestionSet
/// capture seed.
///
/// The key is declared once for every reader and writer. Presence is decided
/// by key existence alone, so a stored `null` stays a present-but-invalid seed
/// and can never be mistaken for a historical task without a seed.
const String questionSetCaptureMetadataKey = '_questionSetCaptureV1';

/// Fixed failure classification for QuestionSet capture seed handling.
enum DocumentQuestionSetSeedFailure {
  /// The envelope is malformed: wrong root, wrong types, non-string keys,
  /// missing or extra fields, invalid `capture`, or invalid field values.
  invalidEnvelope,

  /// The envelope declares an integer schema version other than
  /// [DocumentQuestionSetSeedCodec.schemaVersion].
  unsupportedSchema,

  /// The compact UTF-8 envelope exceeds
  /// [DocumentQuestionSetSeedCodec.maxEnvelopeBytes].
  oversize,
}

/// Safe fixed exception for QuestionSet capture seed failures.
///
/// Carries only the failure classification. [toString] returns fixed text and
/// never includes display names, source IDs, raw JSON, paths, document
/// content, provider payloads, or causes.
final class DocumentQuestionSetSeedException implements Exception {
  const DocumentQuestionSetSeedException(this.failure);

  final DocumentQuestionSetSeedFailure failure;

  @override
  String toString() {
    return switch (failure) {
      DocumentQuestionSetSeedFailure.invalidEnvelope =>
        'QuestionSet capture seed envelope is invalid.',
      DocumentQuestionSetSeedFailure.unsupportedSchema =>
        'QuestionSet capture seed schema version is unsupported.',
      DocumentQuestionSetSeedFailure.oversize =>
        'QuestionSet capture seed payload is oversized.',
    };
  }
}

/// Immutable QuestionSet capture intent carried by one document import task.
///
/// [displayName] must already be canonical-safe: 1–256 Unicode scalars with no
/// path separator and no control character. Sanitizing a raw file path into a
/// display name is not part of this contract; callers pass a value that
/// already satisfies [isValidImportedQuestionSetDisplayName]. [sourceFileId]
/// is an optional opaque LibraryFile reference, never a path; `null` means no
/// provenance and is not "file deleted".
///
/// `schemaVersion` and `capture` are protocol constants and are deliberately
/// not constructible here.
final class DocumentQuestionSetSeed {
  DocumentQuestionSetSeed({
    required String displayName,
    String? sourceFileId,
  })  : displayName = _requireDisplayName(displayName),
        sourceFileId = _requireSourceFileId(sourceFileId);

  final String displayName;
  final String? sourceFileId;
}

/// Strict non-normalizing codec for the document QuestionSet capture seed.
///
/// The only legal envelope is exactly four keys:
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "capture": true,
///   "displayName": "2021数学一真题.pdf",
///   "sourceFileId": null
/// }
/// ```
///
/// [decode] verifies persisted authority and never repairs it: it does not
/// trim, fill defaults, coerce types, drop unknown keys, or turn an empty
/// `sourceFileId` into `null`. A missing, extra, or unknown key, an
/// unsupported version, or an oversized payload fails closed.
final class DocumentQuestionSetSeedCodec {
  const DocumentQuestionSetSeedCodec();

  static const int schemaVersion = 1;
  static const int maxEnvelopeBytes = 4096;

  static const Set<String> _envelopeKeys = <String>{
    'schemaVersion',
    'capture',
    'displayName',
    'sourceFileId',
  };

  /// Encodes [seed] into the canonical compact envelope.
  ///
  /// Throws [DocumentQuestionSetSeedException] with
  /// [DocumentQuestionSetSeedFailure.oversize] when the compact UTF-8
  /// representation would exceed [maxEnvelopeBytes].
  Map<String, Object?> encode(DocumentQuestionSetSeed seed) {
    final envelope = _canonicalEnvelope(
      displayName: seed.displayName,
      sourceFileId: seed.sourceFileId,
    );
    _requireWithinByteCap(envelope);
    return envelope;
  }

  /// Strictly decodes a persisted seed envelope.
  ///
  /// Throws [DocumentQuestionSetSeedException] with
  /// [DocumentQuestionSetSeedFailure.unsupportedSchema] for an integer
  /// version other than [schemaVersion], and
  /// [DocumentQuestionSetSeedFailure.invalidEnvelope] for every other
  /// malformed envelope.
  DocumentQuestionSetSeed decode(Object? value) {
    final envelope = _requireEnvelope(value);

    final version = envelope['schemaVersion'];
    if (version is! int) {
      throw const DocumentQuestionSetSeedException(
        DocumentQuestionSetSeedFailure.invalidEnvelope,
      );
    }
    if (version != schemaVersion) {
      throw const DocumentQuestionSetSeedException(
        DocumentQuestionSetSeedFailure.unsupportedSchema,
      );
    }

    if (envelope['capture'] != true) {
      throw const DocumentQuestionSetSeedException(
        DocumentQuestionSetSeedFailure.invalidEnvelope,
      );
    }

    final displayName = switch (envelope['displayName']) {
      final String value => value,
      _ => throw const DocumentQuestionSetSeedException(
          DocumentQuestionSetSeedFailure.invalidEnvelope,
        ),
    };

    final sourceFileId = switch (envelope['sourceFileId']) {
      null => null,
      final String value => value,
      _ => throw const DocumentQuestionSetSeedException(
          DocumentQuestionSetSeedFailure.invalidEnvelope,
        ),
    };

    final seed = DocumentQuestionSetSeed(
      displayName: displayName,
      sourceFileId: sourceFileId,
    );
    _requireWithinByteCap(
      _canonicalEnvelope(
        displayName: seed.displayName,
        sourceFileId: seed.sourceFileId,
      ),
    );
    return seed;
  }

  /// Whether [diagnostics] carries the reserved seed key.
  ///
  /// Presence is decided by key existence only, so a present `null` returns
  /// `true` and must be treated as an invalid seed rather than an absent one.
  bool containsSeedKey(Object? diagnostics) {
    return diagnostics is Map &&
        diagnostics.containsKey(questionSetCaptureMetadataKey);
  }

  Map<String, Object?> _requireEnvelope(Object? value) {
    if (value is! Map) {
      throw const DocumentQuestionSetSeedException(
        DocumentQuestionSetSeedFailure.invalidEnvelope,
      );
    }
    final envelope = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const DocumentQuestionSetSeedException(
          DocumentQuestionSetSeedFailure.invalidEnvelope,
        );
      }
      envelope[key] = entry.value;
    }
    if (envelope.length != _envelopeKeys.length ||
        !_envelopeKeys.every(envelope.containsKey)) {
      throw const DocumentQuestionSetSeedException(
        DocumentQuestionSetSeedFailure.invalidEnvelope,
      );
    }
    return envelope;
  }

  void _requireWithinByteCap(Map<String, Object?> envelope) {
    if (utf8.encode(jsonEncode(envelope)).length > maxEnvelopeBytes) {
      throw const DocumentQuestionSetSeedException(
        DocumentQuestionSetSeedFailure.oversize,
      );
    }
  }

  Map<String, Object?> _canonicalEnvelope({
    required String displayName,
    required String? sourceFileId,
  }) {
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'capture': true,
      'displayName': displayName,
      'sourceFileId': sourceFileId,
    };
  }
}

String _requireDisplayName(String value) {
  if (!isValidImportedQuestionSetDisplayName(value)) {
    throw const DocumentQuestionSetSeedException(
      DocumentQuestionSetSeedFailure.invalidEnvelope,
    );
  }
  return value;
}

String? _requireSourceFileId(String? value) {
  if (value != null && value.isEmpty) {
    throw const DocumentQuestionSetSeedException(
      DocumentQuestionSetSeedFailure.invalidEnvelope,
    );
  }
  return value;
}
