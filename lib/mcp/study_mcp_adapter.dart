/// mcp.study.v0 read-only MCP transport adapter.
///
/// Owns protocol argument parsing (shape, types, basic bounds), converts
/// protocol arguments into T0 application DTOs, and projects T0 results back
/// into the frozen v0 envelopes. Every read goes through
/// [StudyQueryService]; this file defines no persistence access and no
/// business semantics beyond the frozen protocol surface.
library;

import 'package:shiroha_quiz/application/study_query/study_query_clock.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_error.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';

/// Frozen schema version of every mcp.study.v0 response envelope.
const String studyMcpSchemaVersion = 'mcp.study.v0';

/// Strict lexical form of an offset-bearing RFC 3339 instant:
/// `YYYY-MM-DDTHH:mm:ss[.fraction](Z|±HH:mm)`.
final RegExp _rfc3339OffsetInstant = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
);

/// One tool response: the frozen v0 envelope plus the MCP error flag.
final class StudyMcpToolResult {
  const StudyMcpToolResult({required this.envelope, required this.isError});

  /// Success envelope (`data` or `items`/`next_cursor`) or the exact
  /// section-5 error envelope. The two shapes are mutually exclusive.
  final Map<String, Object?> envelope;

  /// True when [envelope] is the frozen error envelope.
  final bool isError;
}

/// mcp.study.v0 read-only tool adapter over the T0 study query service.
final class StudyMcpAdapter {
  StudyMcpAdapter({required StudyQueryService service, StudyClock? clock})
      : _service = service,
        _clock = clock ?? const SystemStudyClock();

  final StudyQueryService _service;
  final StudyClock _clock;

  /// The exactly-six frozen READ_ONLY tool names.
  static const List<String> toolNames = <String>[
    'list_question_banks',
    'get_study_overview',
    'get_due_review_summary',
    'search_questions',
    'get_question_detail',
    'get_weak_questions',
  ];

  /// Handles one frozen v0 tool call and returns the exact response envelope.
  Future<StudyMcpToolResult> callTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final generatedAt = _wholeSecondUtc(_clock.nowUtc());
    try {
      final Map<String, Object?> body = switch (toolName) {
        'list_question_banks' => await _listQuestionBanks(arguments),
        'get_study_overview' => await _getStudyOverview(arguments),
        'get_due_review_summary' => await _getDueReviewSummary(arguments),
        'search_questions' => await _searchQuestions(arguments),
        'get_question_detail' => await _getQuestionDetail(arguments),
        'get_weak_questions' => await _getWeakQuestions(arguments),
        _ => throw const StudyQueryException(StudyQueryFailure.invalidRequest),
      };
      return StudyMcpToolResult(
        envelope: <String, Object?>{
          'schema_version': studyMcpSchemaVersion,
          'generated_at': generatedAt,
          ...body,
        },
        isError: false,
      );
    } on StudyQueryException catch (error) {
      return StudyMcpToolResult(
        envelope: _errorEnvelope(error),
        isError: true,
      );
    } catch (_) {
      return StudyMcpToolResult(
        envelope: _errorEnvelope(
          const StudyQueryException(StudyQueryFailure.internalError),
        ),
        isError: true,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Tool handlers
  // ---------------------------------------------------------------------------

  Future<Map<String, Object?>> _listQuestionBanks(
    Map<String, dynamic> args,
  ) async {
    final page = await _service.listQuestionBanks(
      cursor: _optionalCursor(args),
      limit: _limit(args, fallback: 50),
    );
    return <String, Object?>{
      'items': <Map<String, Object?>>[
        for (final bank in page.items)
          <String, Object?>{
            'bank_name': bank.bankName,
            'folder_name': bank.folderName,
            'question_count': bank.questionCount,
            'due_count': bank.dueCount,
            'mastered_count': bank.masteredCount,
          },
      ],
      'next_cursor': page.nextCursor?.value,
    };
  }

  Future<Map<String, Object?>> _getStudyOverview(
    Map<String, dynamic> args,
  ) async {
    final overview = await _service.getStudyOverview(
      bankName: _optionalString(args, 'bank_name'),
      timezone: _requiredString(args, 'timezone'),
    );
    return <String, Object?>{
      'data': <String, Object?>{
        'question_count': overview.questionCount,
        'mastered_count': overview.masteredCount,
        'due_count': overview.dueCount,
        'today_practice_count': overview.todayPracticeCount,
        'wrong_question_count': overview.wrongQuestionCount,
      },
    };
  }

  Future<Map<String, Object?>> _getDueReviewSummary(
    Map<String, dynamic> args,
  ) async {
    final summary = await _service.getDueReviewSummary(
      bankName: _optionalString(args, 'bank_name'),
      timezone: _optionalString(args, 'timezone'),
      from: _requiredInstant(args, 'from'),
      to: _requiredInstant(args, 'to'),
    );
    return <String, Object?>{
      'data': <String, Object?>{
        'due_now': summary.dueNow,
        'scheduled_count': summary.scheduledCount,
        'buckets': <Map<String, Object?>>[
          for (final bucket in summary.buckets)
            <String, Object?>{
              'date': bucket.date.toString(),
              'count': bucket.count,
            },
        ],
      },
    };
  }

  Future<Map<String, Object?>> _searchQuestions(
    Map<String, dynamic> args,
  ) async {
    final page = await _service.searchQuestions(
      bankName: _requiredString(args, 'bank_name'),
      query: _requiredString(args, 'query'),
      cursor: _optionalCursor(args),
      limit: _limit(args, fallback: 50),
    );
    return <String, Object?>{
      'items': <Map<String, Object?>>[
        for (final item in page.items) _searchItem(item),
      ],
      'next_cursor': page.nextCursor?.value,
    };
  }

  Future<Map<String, Object?>> _getQuestionDetail(
    Map<String, dynamic> args,
  ) async {
    final detail = await _service.getQuestionDetail(
      _requiredString(args, 'question_id'),
    );
    return <String, Object?>{
      'data': <String, Object?>{
        'question_id': detail.questionId,
        'bank_name': detail.bankName,
        'kind': _kindOf(detail.kind),
        'stem': <Map<String, Object?>>[
          for (final node in detail.stem) _nodeOf(node),
        ],
        'options': <Map<String, Object?>>[
          for (final option in detail.options)
            <String, Object?>{
              'label': option.label,
              'content': <Map<String, Object?>>[
                for (final node in option.content) _nodeOf(node),
              ],
            },
        ],
        'answer': detail.answer == null
            ? null
            : <Map<String, Object?>>[
                for (final node in detail.answer!) _nodeOf(node),
              ],
        'explanation': detail.explanation == null
            ? null
            : <Map<String, Object?>>[
                for (final node in detail.explanation!) _nodeOf(node),
              ],
        'due_state': <String, Object?>{'due': detail.due},
        'source_kind': _sourceKindOf(detail.sourceKind),
      },
    };
  }

  Future<Map<String, Object?>> _getWeakQuestions(
    Map<String, dynamic> args,
  ) async {
    final page = await _service.getWeakQuestions(
      bankName: _optionalString(args, 'bank_name'),
      cursor: _optionalCursor(args),
      limit: _limit(args, fallback: 50),
    );
    return <String, Object?>{
      'items': <Map<String, Object?>>[
        for (final item in page.items)
          <String, Object?>{
            'question_id': item.questionId,
            'bank_name': item.bankName,
            'stem_preview': item.stemPreview,
            'lapse_count': item.lapseCount,
            'difficulty': item.difficulty,
            'last_lapse_at': item.lastLapseAt == null
                ? null
                : _wholeSecondUtc(item.lastLapseAt!),
          },
      ],
      'next_cursor': page.nextCursor?.value,
    };
  }

  // ---------------------------------------------------------------------------
  // Protocol argument parsing (shape, types, basic bounds only)
  // ---------------------------------------------------------------------------

  String? _optionalString(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is! String) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    return value;
  }

  String _requiredString(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! String) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    return value;
  }

  OpaqueCursor? _optionalCursor(Map<String, dynamic> args) {
    final raw = _optionalString(args, 'cursor');
    if (raw == null) return null;
    try {
      return OpaqueCursor.fromEncoded(raw);
    } on ArgumentError {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
  }

  int _limit(Map<String, dynamic> args, {required int fallback}) {
    final value = args['limit'];
    if (value == null) return fallback;
    if (value is! int) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    return value;
  }

  /// Offset-bearing RFC 3339 timestamp as a UTC instant.
  DateTime _requiredInstant(Map<String, dynamic> args, String key) {
    final raw = _requiredString(args, key);
    if (!_rfc3339OffsetInstant.hasMatch(raw)) {
      // Reject lax forms DateTime.parse accepts (space separator, colons
      // missing in the offset, lowercase z).
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    final DateTime parsed;
    try {
      parsed = DateTime.parse(raw);
    } on FormatException {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    if (!parsed.isUtc) {
      // Naive timestamps have no offset and are not RFC 3339 offset-bearing.
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    return parsed;
  }

  // ---------------------------------------------------------------------------
  // DTO projection
  // ---------------------------------------------------------------------------

  Map<String, Object?> _searchItem(QuestionSearchItem item) {
    return <String, Object?>{
      'question_id': item.questionId,
      'bank_name': item.bankName,
      'kind': _kindOf(item.kind),
      'stem_preview': item.stemPreview,
      'has_answer': item.hasAnswer,
      'has_explanation': item.hasExplanation,
      'due': item.due,
      'source_kind': _sourceKindOf(item.sourceKind),
    };
  }

  Map<String, Object?> _nodeOf(StudyContentNode node) {
    return switch (node) {
      StudyTextNode(:final text) => <String, Object?>{
          'type': 'text',
          'text': text
        },
      StudyInlineMathNode(:final latex) => <String, Object?>{
          'type': 'inline_math',
          'latex': latex
        },
      StudyBlockMathNode(:final latex) => <String, Object?>{
          'type': 'block_math',
          'latex': latex
        },
      StudyUnsupportedNode() => <String, Object?>{'type': 'unsupported'},
    };
  }

  String _kindOf(StudyQuestionKind kind) {
    return switch (kind) {
      StudyQuestionKind.singleChoice => 'single_choice',
      StudyQuestionKind.fillBlank => 'fill_blank',
      StudyQuestionKind.shortAnswer => 'short_answer',
      StudyQuestionKind.unknown => 'unknown',
    };
  }

  String _sourceKindOf(StudySourceKind kind) {
    return switch (kind) {
      StudySourceKind.typed => 'typed',
      StudySourceKind.legacy => 'legacy',
    };
  }

  // ---------------------------------------------------------------------------
  // Envelopes
  // ---------------------------------------------------------------------------

  Map<String, Object?> _errorEnvelope(StudyQueryException error) {
    return <String, Object?>{
      'schema_version': studyMcpSchemaVersion,
      'error': <String, Object?>{
        'code': _codeOf(error.failure),
        'message': _messageOf(error.failure),
        'retryable': error.retryable,
      },
    };
  }

  String _codeOf(StudyQueryFailure failure) {
    return switch (failure) {
      StudyQueryFailure.invalidRequest => 'invalid_request',
      StudyQueryFailure.notFound => 'not_found',
      StudyQueryFailure.accessDenied => 'access_denied',
      StudyQueryFailure.dataCorrupt => 'data_corrupt',
      StudyQueryFailure.temporarilyUnavailable => 'temporarily_unavailable',
      StudyQueryFailure.internalError => 'internal_error',
    };
  }

  String _messageOf(StudyQueryFailure failure) {
    return switch (failure) {
      StudyQueryFailure.invalidRequest => 'The request is invalid.',
      StudyQueryFailure.notFound => 'The requested object was not found.',
      StudyQueryFailure.accessDenied =>
        'Access to the requested data is denied.',
      StudyQueryFailure.dataCorrupt => 'The stored data cannot be read safely.',
      StudyQueryFailure.temporarilyUnavailable =>
        'The data source is temporarily unavailable.',
      StudyQueryFailure.internalError => 'An internal error occurred.',
    };
  }

  /// Formats a UTC instant as a whole-second RFC 3339 timestamp with `Z`.
  String _wholeSecondUtc(DateTime value) {
    final utc = value.toUtc();
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    final hour = utc.hour.toString().padLeft(2, '0');
    final minute = utc.minute.toString().padLeft(2, '0');
    final second = utc.second.toString().padLeft(2, '0');
    return '${utc.year}-$month-${day}T$hour:$minute:${second}Z';
  }
}
