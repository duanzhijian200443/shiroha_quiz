import 'dart:convert';

/// Session kind for an answer attempt.
enum AnswerAttemptSessionKind {
  normal,
  focused,
  exam;

  String get dbValue => name;

  static AnswerAttemptSessionKind fromDbValue(String value) {
    return switch (value) {
      'normal' => AnswerAttemptSessionKind.normal,
      'focused' => AnswerAttemptSessionKind.focused,
      'exam' => AnswerAttemptSessionKind.exam,
      _ => throw ArgumentError('Unknown AnswerAttemptSessionKind: $value'),
    };
  }
}

/// Interaction modality for an answer attempt.
enum AnswerAttemptModality {
  choice,
  text;

  String get dbValue => name;

  static AnswerAttemptModality fromDbValue(String value) {
    return switch (value) {
      'choice' => AnswerAttemptModality.choice,
      'text' => AnswerAttemptModality.text,
      _ => throw ArgumentError('Unknown AnswerAttemptModality: $value'),
    };
  }
}

/// Helper for structural, versioned, validated answer payloads.
final class AnswerAttemptPayload {
  AnswerAttemptPayload._();

  static const int currentVersion = 1;

  /// Creates a validated JSON payload for a typed choice selection.
  static String choice({required List<String> optionIds}) {
    if (optionIds.isEmpty) {
      throw ArgumentError('optionIds must not be empty');
    }
    for (final id in optionIds) {
      if (id.trim().isEmpty) {
        throw ArgumentError('optionId must not be blank');
      }
    }
    return jsonEncode(<String, Object?>{
      'version': currentVersion,
      'kind': 'choice',
      'option_ids': optionIds,
    });
  }

  /// Creates a validated JSON payload for a legacy choice selection.
  static String legacyChoice({required List<String> labels}) {
    if (labels.isEmpty) {
      throw ArgumentError('labels must not be empty');
    }
    for (final label in labels) {
      if (label.trim().isEmpty) {
        throw ArgumentError('label must not be blank');
      }
    }
    return jsonEncode(<String, Object?>{
      'version': currentVersion,
      'kind': 'legacy_choice',
      'labels': labels,
    });
  }

  /// Creates a validated JSON payload for a subjective text answer.
  static String text({required String text}) {
    if (text.trim().isEmpty) {
      throw ArgumentError('text must not be empty');
    }
    return jsonEncode(<String, Object?>{
      'version': currentVersion,
      'kind': 'text',
      'text': text,
    });
  }

  /// Validates that [jsonStr] matches [modality] and is a valid version 1 payload.
  static void validateForModality(
    AnswerAttemptModality modality,
    String jsonStr,
  ) {
    if (jsonStr.trim().isEmpty) {
      throw const FormatException('Payload JSON must not be empty');
    }
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Payload JSON must be a Map');
    }
    final version = decoded['version'];
    if (version is! int || version != currentVersion) {
      throw FormatException(
          'Payload version must be exactly $currentVersion, but was $version');
    }
    final kind = decoded['kind'];
    if (kind is! String) {
      throw const FormatException('Payload kind must be a String');
    }

    switch (modality) {
      case AnswerAttemptModality.choice:
        if (kind != 'choice' && kind != 'legacy_choice') {
          throw FormatException(
              'choice modality requires kind "choice" or "legacy_choice", but got "$kind"');
        }
        if (kind == 'choice') {
          final optionIds = decoded['option_ids'];
          if (optionIds is! List || optionIds.isEmpty) {
            throw const FormatException(
                'choice payload must have non-empty option_ids');
          }
          for (final item in optionIds) {
            if (item is! String || item.trim().isEmpty) {
              throw const FormatException(
                  'option_ids must contain non-empty Strings');
            }
          }
        } else {
          final labels = decoded['labels'];
          if (labels is! List || labels.isEmpty) {
            throw const FormatException(
                'legacy_choice payload must have non-empty labels');
          }
          for (final item in labels) {
            if (item is! String || item.trim().isEmpty) {
              throw const FormatException(
                  'labels must contain non-empty Strings');
            }
          }
        }
      case AnswerAttemptModality.text:
        if (kind != 'text') {
          throw FormatException(
              'text modality requires kind "text", but got "$kind"');
        }
        final text = decoded['text'];
        if (text is! String || text.trim().isEmpty) {
          throw const FormatException('text payload must have non-empty text');
        }
    }
  }

  /// Validates that [jsonStr] is a valid structural answer attempt payload.
  static void validatePayloadJson(
    String jsonStr, {
    AnswerAttemptModality? modality,
  }) {
    if (modality != null) {
      validateForModality(modality, jsonStr);
      return;
    }
    if (jsonStr.trim().isEmpty) {
      throw const FormatException('Payload JSON must not be empty');
    }
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Payload JSON must be a Map');
    }
    final version = decoded['version'];
    if (version is! int || version != currentVersion) {
      throw FormatException(
          'Payload version must be exactly $currentVersion, but was $version');
    }
    final kind = decoded['kind'];
    if (kind is! String) {
      throw const FormatException('Payload kind must be a String');
    }
    switch (kind) {
      case 'choice':
        validateForModality(AnswerAttemptModality.choice, jsonStr);
      case 'legacy_choice':
        validateForModality(AnswerAttemptModality.choice, jsonStr);
      case 'text':
        validateForModality(AnswerAttemptModality.text, jsonStr);
      default:
        throw FormatException('Unsupported payload kind: $kind');
    }
  }
}

/// Immutable entity representing one append-only historical answer attempt fact.
///
/// An [AnswerAttempt] records what the user answered and what the correctness
/// outcome was. It is strictly separate from [ReviewState] (the FSRS scheduling
/// state) and [ReviewLog] (the FSRS review history log).
final class AnswerAttempt {
  const AnswerAttempt({
    required this.attemptId,
    required this.questionId,
    required this.sessionKind,
    required this.modality,
    required this.answerPayloadJson,
    required this.correctness,
    required this.answeredAt,
    this.durationMs,
  });

  final String attemptId;
  final String questionId;
  final AnswerAttemptSessionKind sessionKind;
  final AnswerAttemptModality modality;
  final String answerPayloadJson;
  final bool? correctness;
  final int answeredAt;
  final int? durationMs;

  Map<String, Object?> toMap() => <String, Object?>{
        'attempt_id': attemptId,
        'question_id': questionId,
        'session_kind': sessionKind.dbValue,
        'modality': modality.dbValue,
        'answer_payload_json': answerPayloadJson,
        'correctness': correctness == null ? null : (correctness! ? 1 : 0),
        'answered_at': answeredAt,
        'duration_ms': durationMs,
      };

  factory AnswerAttempt.fromMap(Map<String, Object?> map) {
    final rawCorrectness = map['correctness'];
    final bool? correctness = switch (rawCorrectness) {
      1 || true => true,
      0 || false => false,
      _ => null,
    };
    return AnswerAttempt(
      attemptId: map['attempt_id']! as String,
      questionId: map['question_id']! as String,
      sessionKind: AnswerAttemptSessionKind.fromDbValue(
        map['session_kind']! as String,
      ),
      modality: AnswerAttemptModality.fromDbValue(
        map['modality']! as String,
      ),
      answerPayloadJson: map['answer_payload_json']! as String,
      correctness: correctness,
      answeredAt: (map['answered_at']! as num).toInt(),
      durationMs: (map['duration_ms'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnswerAttempt &&
          runtimeType == other.runtimeType &&
          attemptId == other.attemptId &&
          questionId == other.questionId &&
          sessionKind == other.sessionKind &&
          modality == other.modality &&
          answerPayloadJson == other.answerPayloadJson &&
          correctness == other.correctness &&
          answeredAt == other.answeredAt &&
          durationMs == other.durationMs;

  @override
  int get hashCode => Object.hash(
        attemptId,
        questionId,
        sessionKind,
        modality,
        answerPayloadJson,
        correctness,
        answeredAt,
        durationMs,
      );

  @override
  String toString() =>
      'AnswerAttempt(attemptId: $attemptId, questionId: $questionId, '
      'sessionKind: ${sessionKind.name}, modality: ${modality.name}, '
      'correctness: $correctness, answeredAt: $answeredAt, durationMs: $durationMs)';
}
