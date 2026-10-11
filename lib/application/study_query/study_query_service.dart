/// T0 read-only application query layer.
///
/// [StudyQueryService] implements the six frozen read semantics
/// (list question banks, get study overview, get due review summary, search
/// questions, get question detail, get weak questions) as reusable
/// application services. Presentation adapters (Flutter UI, the built-in
/// Agent, and the future MCP adapter) consume only safe DTOs through this
/// service; no adapter reaches repositories, SQL, or persistence directly.
///
/// The service is strictly READ_ONLY: it never grades, mutates sessions,
/// mutates answers, or performs formal writes.
library;

import 'dart:convert';

import 'study_query_clock.dart';
import 'study_query_dtos.dart';
import 'study_query_error.dart';
import 'study_query_ports.dart';
import 'study_question_projection.dart';
import 'study_query_stem_preview.dart';
import 'study_query_time_zone.dart';

final class StudyQueryService {
  StudyQueryService({
    required StudyQuestionQueryPort questionQuery,
    required StudyMetricsQueryPort metricsQuery,
    StudyClock? clock,
    StudyQueryTimeZone? timeZone,
    String defaultTimeZone = 'UTC',
  })  : _questionQuery = questionQuery,
        _metricsQuery = metricsQuery,
        _clock = clock ?? const SystemStudyClock(),
        _timeZone = timeZone ?? const EmbeddedIanaTimeZoneResolver(),
        _defaultTimeZone = defaultTimeZone;

  final StudyQuestionQueryPort _questionQuery;
  final StudyMetricsQueryPort _metricsQuery;
  final StudyClock _clock;
  final StudyQueryTimeZone _timeZone;
  final String _defaultTimeZone;
  static const _projection = StudyQuestionProjection();
  static const StemPreviewNormalizer _preview = StemPreviewNormalizer();

  static const int _maxBankLimit = 100;
  static const int _maxSearchLimit = 50;
  static const int _maxQueryLength = 200;
  static const String _bankCursorKind = 'bank';
  static const String _searchCursorKind = 'search';
  static const String _weakCursorKind = 'weak';

  /// 1. list question banks.
  Future<BankListPage> listQuestionBanks({
    OpaqueCursor? cursor,
    int limit = 50,
  }) async {
    _requireLimit(limit, _maxBankLimit);
    String? afterBankName;
    if (cursor != null) {
      final parts = _decodeCursorFor(cursor, _bankCursorKind);
      if (parts == null || parts.length != 1 || parts[0] is! String) {
        throw const StudyQueryException(StudyQueryFailure.invalidRequest);
      }
      afterBankName = parts[0] as String;
    }
    final page = await _guard(
      () => _questionQuery.listStudyQuestionBanks(
        nowUnixSeconds: _nowUnixSeconds(),
        limit: limit,
        afterBankName: afterBankName,
      ),
    );
    final nextCursor = page.hasMore && page.items.isNotEmpty
        ? _encodeCursor(_bankCursorKind, <Object>[page.items.last.bankName])
        : null;
    return BankListPage(items: page.items, nextCursor: nextCursor);
  }

  /// 2. get study overview (global or bank scoped).
  Future<StudyOverview> getStudyOverview({
    String? bankName,
    required String timezone,
  }) async {
    final trimmedBank = _optionalBankName(bankName);
    final tz = _requireTimeZone(timezone);
    final now = _clock.nowUtc();
    final today = _timeZone.localDateOf(now, tz);
    final todayStart = _timeZone.utcInstantOfLocalMidnight(today, tz);
    final counts = await _guard(
      () => _metricsQuery.getStudyOverviewCounts(
        bankName: trimmedBank,
        nowUnixSeconds: now.millisecondsSinceEpoch ~/ 1000,
        todayStartUnixSeconds: todayStart.millisecondsSinceEpoch ~/ 1000,
      ),
    );
    return StudyOverview(
      questionCount: counts.questionCount,
      masteredCount: counts.masteredCount,
      dueCount: counts.dueCount,
      todayPracticeCount: counts.todayPracticeCount,
      wrongQuestionCount: counts.wrongQuestionCount,
    );
  }

  /// 3. get due review summary with local-date buckets.
  Future<DueReviewSummary> getDueReviewSummary({
    String? bankName,
    String? timezone,
    required DateTime from,
    required DateTime to,
  }) async {
    final trimmedBank = _optionalBankName(bankName);
    final tz = _requireTimeZone(timezone ?? _defaultTimeZone);
    if (!from.isBefore(to)) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    if (to.difference(from) > const Duration(days: 90)) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    // Validate the zone before issuing repository reads.
    _timeZone.localDateOf(from, tz);

    final now = _clock.nowUtc();
    final dueNow = await _guard(
      () => _metricsQuery.countStudyDueNow(
        bankName: trimmedBank,
        nowUnixSeconds: now.millisecondsSinceEpoch ~/ 1000,
      ),
    );
    final timestamps = await _guard(
      () => _metricsQuery.getStudyScheduledReviewTimestamps(
        bankName: trimmedBank,
        fromUnixSeconds: from.millisecondsSinceEpoch ~/ 1000,
        toUnixSeconds: to.millisecondsSinceEpoch ~/ 1000,
      ),
    );
    final bucketCounts = <StudyLocalDate, int>{};
    for (final timestamp in timestamps) {
      final instant =
          DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true);
      final date = _timeZone.localDateOf(instant, tz);
      bucketCounts[date] = (bucketCounts[date] ?? 0) + 1;
    }
    final buckets = <DueBucket>[
      for (final entry in bucketCounts.entries)
        DueBucket(date: entry.key, count: entry.value),
    ]..sort((left, right) => left.date.compareTo(right.date));
    return DueReviewSummary(
      dueNow: dueNow,
      scheduledCount: timestamps.length,
      buckets: buckets,
    );
  }

  /// 4. search questions (keyset pagination, opaque cursor).
  Future<QuestionSearchPage> searchQuestions({
    required String bankName,
    required String query,
    OpaqueCursor? cursor,
    int limit = 50,
  }) async {
    final trimmedBank = _requireBankName(bankName);
    final trimmedQuery = _requireQuery(query);
    _requireLimit(limit, _maxSearchLimit);
    int? afterCreatedAt;
    String? afterId;
    if (cursor != null) {
      final parts = _decodeCursorFor(cursor, _searchCursorKind);
      if (parts == null ||
          parts.length != 2 ||
          parts[0] is! int ||
          parts[1] is! String) {
        throw const StudyQueryException(StudyQueryFailure.invalidRequest);
      }
      afterCreatedAt = parts[0] as int;
      afterId = parts[1] as String;
    }
    final page = await _guard(
      () => _questionQuery.searchStudyQuestions(
        bankName: trimmedBank,
        query: trimmedQuery,
        nowUnixSeconds: _nowUnixSeconds(),
        limit: limit,
        afterCreatedAt: afterCreatedAt,
        afterId: afterId,
      ),
    );
    final nextCursor = page.hasMore && page.items.isNotEmpty
        ? _encodeCursor(_searchCursorKind, <Object>[
            page.items.last.createdAt,
            page.items.last.questionId,
          ])
        : null;
    return QuestionSearchPage(
      items: <QuestionSearchItem>[
        for (final read in page.items) _projection.searchItem(read),
      ],
      nextCursor: nextCursor,
    );
  }

  /// 5. get question detail through the typed-aware repository seam.
  Future<QuestionDetail> getQuestionDetail(String questionId) async {
    final trimmedId = questionId.trim();
    if (trimmedId.isEmpty) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    final read = await _guard(
      () => _questionQuery.getStudyQuestionDetail(
        trimmedId,
        nowUnixSeconds: _nowUnixSeconds(),
      ),
    );
    if (read == null) {
      throw const StudyQueryException(StudyQueryFailure.notFound);
    }
    return _projection.detail(read);
  }

  /// 6. get weak questions (analysis only).
  Future<WeakQuestionPage> getWeakQuestions({
    String? bankName,
    OpaqueCursor? cursor,
    int limit = 50,
  }) async {
    final trimmedBank = _optionalBankName(bankName);
    _requireLimit(limit, _maxSearchLimit);
    int? afterLastLapseTime;
    String? afterId;
    if (cursor != null) {
      final parts = _decodeCursorFor(cursor, _weakCursorKind);
      if (parts == null ||
          parts.length != 2 ||
          parts[0] is! int ||
          parts[1] is! String) {
        throw const StudyQueryException(StudyQueryFailure.invalidRequest);
      }
      afterLastLapseTime = parts[0] as int;
      afterId = parts[1] as String;
    }
    final page = await _guard(
      () => _questionQuery.listStudyWeakQuestions(
        nowUnixSeconds: _nowUnixSeconds(),
        limit: limit,
        bankName: trimmedBank,
        afterLastLapseTime: afterLastLapseTime,
        afterId: afterId,
      ),
    );
    final nextCursor = page.hasMore && page.items.isNotEmpty
        ? _encodeCursor(_weakCursorKind, <Object>[
            page.items.last.review.lastLapseTime ?? 0,
            page.items.last.questionId,
          ])
        : null;
    return WeakQuestionPage(
      items: <WeakQuestionItem>[
        for (final read in page.items) _weakItem(read),
      ],
      nextCursor: nextCursor,
    );
  }

  // ---------------------------------------------------------------------------
  // DTO projection
  // ---------------------------------------------------------------------------

  WeakQuestionItem _weakItem(StudyQuestionRead read) {
    return switch (read) {
      TypedStudyQuestionRead(
        :final questionId,
        :final bankName,
        :final draft,
        :final review,
      ) =>
        WeakQuestionItem(
          questionId: questionId,
          bankName: bankName,
          stemPreview: _preview.fromRichContent(draft.stem),
          lapseCount: review.lapseCount,
          difficulty: review.difficulty,
          lastLapseAt: _lastLapseAt(review),
        ),
      LegacyStudyQuestionRead(
        :final questionId,
        :final bankName,
        :final stemText,
        :final review,
      ) =>
        WeakQuestionItem(
          questionId: questionId,
          bankName: bankName,
          stemPreview: _preview.normalizeText(stemText),
          lapseCount: review.lapseCount,
          difficulty: review.difficulty,
          lastLapseAt: _lastLapseAt(review),
        ),
    };
  }

  DateTime? _lastLapseAt(StudyQuestionReviewState review) {
    final seconds = review.lastLapseTime;
    if (seconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }

  // ---------------------------------------------------------------------------
  // Validation and error mapping
  // ---------------------------------------------------------------------------

  String _requireBankName(String bankName) {
    final trimmed = bankName.trim();
    if (trimmed.isEmpty) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    return trimmed;
  }

  String? _optionalBankName(String? bankName) {
    if (bankName == null) return null;
    return _requireBankName(bankName);
  }

  String _requireQuery(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty || trimmed.length > _maxQueryLength) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    return trimmed;
  }

  String _requireTimeZone(String timezone) {
    final trimmed = timezone.trim();
    if (trimmed.isEmpty || trimmed.length > 64) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    // Name shape and supported-zone membership are validated by the
    // timezone resolver, which raises invalid_request for unknown zones.
    return trimmed;
  }

  void _requireLimit(int limit, int maxLimit) {
    if (limit < 1 || limit > maxLimit) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on StudyQueryException {
      rethrow;
    } on StudyQueryRepositoryException catch (error) {
      throw switch (error.failure) {
        StudyQueryRepositoryFailure.corruptPayload =>
          const StudyQueryException(StudyQueryFailure.dataCorrupt),
        StudyQueryRepositoryFailure.unavailable =>
          const StudyQueryException(StudyQueryFailure.temporarilyUnavailable),
      };
    } catch (_) {
      throw const StudyQueryException(StudyQueryFailure.internalError);
    }
  }

  int _nowUnixSeconds() => _clock.nowUtc().millisecondsSinceEpoch ~/ 1000;

  // ---------------------------------------------------------------------------
  // Opaque cursor codec
  // ---------------------------------------------------------------------------

  OpaqueCursor _encodeCursor(String kind, List<Object> parts) {
    final encoded = base64UrlEncode(
      utf8.encode(jsonEncode(<Object>['v1', kind, ...parts])),
    ).replaceAll('=', '');
    try {
      return OpaqueCursor.fromEncoded(encoded);
    } on ArgumentError {
      // A bounded opaque cursor cannot represent this payload (for example
      // an oversized bank name). Keep the fixed error-code set: the raw
      // ArgumentError must never escape the application boundary.
      throw const StudyQueryException(StudyQueryFailure.internalError);
    }
  }

  /// Returns the decoded cursor parts, or null when the token is malformed,
  /// uses an unknown kind, or fails to decode.
  List<Object?>? _decodeCursorFor(OpaqueCursor cursor, String kind) {
    try {
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(cursor.value))),
      );
      if (decoded is! List ||
          decoded.length < 3 ||
          decoded[0] != 'v1' ||
          decoded[1] != kind) {
        return null;
      }
      return decoded.sublist(2);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}
