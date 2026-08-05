import '../../domain/question/question_draft_v2.dart';
import 'question.dart';

/// Explicit database representation of one questions row at the repository
/// boundary: either a legacy V1 row or a V2 typed sidecar row.
sealed class PersistedQuestion {
  const PersistedQuestion();

  String get storageId;
  String get bankName;
  int get createdAt;
}

final class TypedPersistedQuestion extends PersistedQuestion {
  const TypedPersistedQuestion({
    required this.storageId,
    required this.bankName,
    required this.createdAt,
    required this.draft,
  });

  @override
  final String storageId;
  @override
  final String bankName;
  @override
  final int createdAt;

  final QuestionDraftV2 draft;
}

final class LegacyPersistedQuestion extends PersistedQuestion {
  const LegacyPersistedQuestion({required this.question});

  final Question question;

  @override
  String get storageId => question.id ?? '';

  @override
  String get bankName => question.bankName;

  @override
  int get createdAt => question.createdAt;
}
