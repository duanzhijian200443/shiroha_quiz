/// Spaced-repetition tracking record for a single [Question].
///
/// Implements the SM-2 algorithm parameters:
/// - [repetition]: consecutive correct answers count (0–N)
/// - [intervalDays]: days until the next scheduled review
/// - [easeFactor]: multiplier for interval calculation (≥ 1.3)
/// - [isWrong]: 1 if the most recent answer was wrong, 0 otherwise
///
/// [masteryLevel] ranges from 0 (new) to 5 (mastered), derived from [repetition].
/// [nextReviewAt] is the Unix epoch ms at which the question is due again.
class UserReview {
  final int? id;
  final int questionId;
  final int reviewCount;
  final int? lastReviewedAt; // Unix epoch ms
  final int? nextReviewAt; // Unix epoch ms
  final int masteryLevel;
  final int repetition; // SM-2 consecutive correct count
  final int intervalDays; // SM-2 interval in days
  final double easeFactor; // SM-2 ease factor (≥ 1.3)
  final int isWrong; // 1 = last answer was wrong, 0 = correct
  final int createdAt; // Unix epoch ms
  final int updatedAt; // Unix epoch ms

  const UserReview({
    this.id,
    required this.questionId,
    this.reviewCount = 0,
    this.lastReviewedAt,
    this.nextReviewAt,
    this.masteryLevel = 0,
    this.repetition = 0,
    this.intervalDays = 0,
    this.easeFactor = 2.5,
    this.isWrong = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory UserReview.fromMap(Map<String, dynamic> map) {
    return UserReview(
      id: map['id'] as int?,
      questionId: map['question_id'] as int,
      reviewCount: map['review_count'] as int,
      lastReviewedAt: map['last_reviewed_at'] as int?,
      nextReviewAt: map['next_review_at'] as int?,
      masteryLevel: map['mastery_level'] as int,
      repetition: (map['repetition'] as int?) ?? 0,
      intervalDays: (map['interval_days'] as int?) ?? 0,
      easeFactor: (map['ease_factor'] as num?)?.toDouble() ?? 2.5,
      isWrong: (map['is_wrong'] as int?) ?? 0,
      createdAt: map['created_at'] as int,
      updatedAt: map['updated_at'] as int,
    );
  }

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'question_id': questionId,
      'review_count': reviewCount,
      'mastery_level': masteryLevel,
      'repetition': repetition,
      'interval_days': intervalDays,
      'ease_factor': easeFactor,
      'is_wrong': isWrong,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
    if (id != null) map['id'] = id;
    map['last_reviewed_at'] = lastReviewedAt;
    map['next_review_at'] = nextReviewAt;
    return map;
  }

  UserReview copyWith({
    int? id,
    int? questionId,
    int? reviewCount,
    int? lastReviewedAt,
    int? nextReviewAt,
    int? masteryLevel,
    int? repetition,
    int? intervalDays,
    double? easeFactor,
    int? isWrong,
    int? createdAt,
    int? updatedAt,
  }) {
    return UserReview(
      id: id ?? this.id,
      questionId: questionId ?? this.questionId,
      reviewCount: reviewCount ?? this.reviewCount,
      lastReviewedAt: lastReviewedAt ?? this.lastReviewedAt,
      nextReviewAt: nextReviewAt ?? this.nextReviewAt,
      masteryLevel: masteryLevel ?? this.masteryLevel,
      repetition: repetition ?? this.repetition,
      intervalDays: intervalDays ?? this.intervalDays,
      easeFactor: easeFactor ?? this.easeFactor,
      isWrong: isWrong ?? this.isWrong,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
