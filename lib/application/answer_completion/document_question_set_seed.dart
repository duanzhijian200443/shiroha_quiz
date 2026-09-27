import 'dart:convert';

import 'package:shiroha_quiz/domain/answer_completion/imported_question_set.dart';

/// Reserved import-task diagnostics key carrying the strict QuestionSet
/// capture seed.
///
/// The key is declared once for every reader and writer. Presence is decided
/// by key existence alone, so a stored `null` stays a present-but-invalid seed
/// and can never be mistaken for a historical task without a seed.
const String questionSetCaptureMetadataKey = '_questionSetCaptureV1';

/// Task-owned document entry provenance, independent of parse/retention mode.
const String documentImportEntryMarkerKey = '_importEntry';

/// Historical document marker; never silently upgraded or assigned a seed.
const String documentImportEntryMarkerValue = 'document_v3';

/// Set-aware document entry; the v3 marker remains a compatibility value.
const String documentQuestionSetImportEntryMarkerValue = 'document_v4';

/// Validates capture intent without upgrading historical tasks.
DocumentQuestionSetSeed? readDocumentQuestionSetSeed(
  Map<String, Object?> diagnostics,
) {
  final present = diagnostics.containsKey(questionSetCaptureMetadataKey);
  final entry = diagnostics[documentImportEntryMarkerKey];
  if (!present && entry != documentQuestionSetImportEntryMarkerValue) {
    return null;
  }
  if (!present || entry != documentQuestionSetImportEntryMarkerValue) {
    throw const DocumentQuestionSetSeedException(
      DocumentQuestionSetSeedFailure.invalidEnvelope,
    );
  }
  return const DocumentQuestionSetSeedCodec().decode(
    diagnostics[questionSetCaptureMetadataKey],
  );
}

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
/// path separator, control character, or unpaired surrogate half. Sanitizing a
/// raw file path into a display name is not part of this contract; callers
/// pass a value that already satisfies
/// [isValidImportedQuestionSetDisplayName]. [sourceFileId] is an optional
/// bounded `LibraryFile.fileId` token, never a path; `null` means no
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
/// `displayName` is bounded to 1–256 Unicode scalars without path separators,
/// control characters, or unpaired surrogate halves, and `sourceFileId` is
/// `null` or a bounded `LibraryFile.fileId` token, never a path. Together with
/// the 4096-byte compact cap those bounds fail closed on missing, extra, or
/// unknown keys, wrong types, unsupported versions, and oversized payloads.
///
/// [decode] verifies persisted authority and never repairs it: it does not
/// trim, fill defaults, coerce types, drop unknown keys, or turn an empty
/// `sourceFileId` into `null`.
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
    // Defensive inbound bound. The compact byte length is independent of key
    // order, so this check on the received envelope is already the canonical
    // compact representation check; running it before field classification
    // keeps an oversized hostile or corrupt payload failing closed as
    // `oversize` instead of as an incidental field failure. Field contracts
    // keep every valid envelope far below the cap.
    _requireWithinByteCap(envelope);

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

    return DocumentQuestionSetSeed(
      displayName: displayName,
      sourceFileId: sourceFileId,
    );
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
  if (value != null && !isValidImportedQuestionSetSourceFileId(value)) {
    throw const DocumentQuestionSetSeedException(
      DocumentQuestionSetSeedFailure.invalidEnvelope,
    );
  }
  return value;
}
