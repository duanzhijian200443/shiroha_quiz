/// JSON dispatcher for the built-in Agent's read-only study tools.
library;

import 'dart:convert';

import '../study_query/study_query_dtos.dart';
import '../study_query/study_query_error.dart';
import '../study_query/study_query_service.dart';
import 'agent_runtime_limits.dart';
import 'agent_study_tool_catalog.dart';

final RegExp _rfc3339OffsetInstant = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$',
);

class AgentStudyToolDispatcher {
  AgentStudyToolDispatcher({
    required StudyQueryService service,
    AgentRuntimeLimits limits = const AgentRuntimeLimits(),
  })  : _service = service,
        _limits = limits;

  final StudyQueryService _service;
  final AgentRuntimeLimits _limits;

  Future<String> dispatch(String toolName, String argumentsJson) async {
    if (!AgentStudyToolCatalog.toolNames.contains(toolName) ||
        utf8.encode(argumentsJson).length > _limits.maxToolArgumentUtf8Bytes) {
      return _failure(StudyQueryFailure.invalidRequest);
    }

    final Map<String, dynamic> arguments;
    try {
      final decoded = jsonDecode(argumentsJson);
      if (decoded is! Map<String, dynamic>) {
        return _failure(StudyQueryFailure.invalidRequest);
      }
      arguments = decoded;
    } on FormatException {
      return _failure(StudyQueryFailure.invalidRequest);
    }

    try {
      final result = await _dispatch(toolName, arguments);
      final encoded = jsonEncode(<String, Object?>{
        'ok': true,
        'result': result,
      });
      if (utf8.encode(encoded).length > _limits.maxToolResultUtf8Bytes) {
        return _failure(StudyQueryFailure.internalError);
      }
      return encoded;
    } on StudyQueryException catch (error) {
      return _failure(error.failure);
    } on ArgumentError {
      return _failure(StudyQueryFailure.invalidRequest);
    } catch (_) {
      return _failure(StudyQueryFailure.internalError);
    }
  }

  Future<Object?> _dispatch(String toolName, Map<String, dynamic> arguments) {
    return switch (toolName) {
      'list_question_banks' => _listQuestionBanks(arguments),
      'get_study_overview' => _getStudyOverview(arguments),
      'get_due_review_summary' => _getDueReviewSummary(arguments),
      'search_questions' => _searchQuestions(arguments),
      'get_question_detail' => _getQuestionDetail(arguments),
      'get_weak_questions' => _getWeakQuestions(arguments),
      _ => throw const StudyQueryException(StudyQueryFailure.invalidRequest),
    };
  }

  Future<Map<String, Object?>> _listQuestionBanks(
    Map<String, dynamic> arguments,
  ) async {
    final page = await _service.listQuestionBanks(
      cursor: _optionalCursor(arguments),
      limit: _limit(arguments, fallback: 50),
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
    Map<String, dynamic> arguments,
  ) async {
    final overview = await _service.getStudyOverview(
      bankName: _optionalString(arguments, 'bank_name'),
      timezone: _requiredString(arguments, 'timezone'),
    );
    return <String, Object?>{
      'question_count': overview.questionCount,
      'mastered_count': overview.masteredCount,
      'due_count': overview.dueCount,
      'today_practice_count': overview.todayPracticeCount,
      'wrong_question_count': overview.wrongQuestionCount,
    };
  }

  Future<Map<String, Object?>> _getDueReviewSummary(
    Map<String, dynamic> arguments,
  ) async {
    final summary = await _service.getDueReviewSummary(
      bankName: _optionalString(arguments, 'bank_name'),
      timezone: _optionalString(arguments, 'timezone'),
      from: _requiredInstant(arguments, 'from'),
      to: _requiredInstant(arguments, 'to'),
    );
    return <String, Object?>{
      'due_now': summary.dueNow,
      'scheduled_count': summary.scheduledCount,
      'buckets': <Map<String, Object?>>[
        for (final bucket in summary.buckets)
          <String, Object?>{
            'date': bucket.date.toString(),
            'count': bucket.count,
          },
      ],
    };
  }

  Future<Map<String, Object?>> _searchQuestions(
    Map<String, dynamic> arguments,
  ) async {
    final page = await _service.searchQuestions(
      bankName: _requiredString(arguments, 'bank_name'),
      query: _requiredString(arguments, 'query'),
      cursor: _optionalCursor(arguments),
      limit: _limit(arguments, fallback: 50),
    );
    return <String, Object?>{
      'items': <Map<String, Object?>>[
        for (final item in page.items) _searchItem(item),
      ],
      'next_cursor': page.nextCursor?.value,
    };
  }

  Future<Map<String, Object?>> _getQuestionDetail(
    Map<String, dynamic> arguments,
  ) async {
    final detail = await _service.getQuestionDetail(
      _requiredString(arguments, 'question_id'),
    );
    return <String, Object?>{
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
    };
  }

  Future<Map<String, Object?>> _getWeakQuestions(
    Map<String, dynamic> arguments,
  ) async {
    final page = await _service.getWeakQuestions(
      bankName: _optionalString(arguments, 'bank_name'),
      cursor: _optionalCursor(arguments),
      limit: _limit(arguments, fallback: 50),
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

  String? _optionalString(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value == null) return null;
    if (value is! String) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    return value;
  }

  String _requiredString(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is! String) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    return value;
  }

  OpaqueCursor? _optionalCursor(Map<String, dynamic> arguments) {
    final raw = _optionalString(arguments, 'cursor');
    return raw == null ? null : OpaqueCursor.fromEncoded(raw);
  }

  int _limit(Map<String, dynamic> arguments, {required int fallback}) {
    final value = arguments['limit'];
    if (value == null) return fallback;
    if (value is! int) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    return value;
  }

  DateTime _requiredInstant(Map<String, dynamic> arguments, String key) {
    final raw = _requiredString(arguments, key);
    final match = _rfc3339OffsetInstant.firstMatch(raw);
    if (match == null) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    final offset = match.group(7)!;
    final offsetHour = offset == 'Z' ? 0 : int.parse(offset.substring(1, 3));
    final offsetMinute = offset == 'Z' ? 0 : int.parse(offset.substring(4, 6));
    if (!_isValidGregorianDate(
          int.parse(match.group(1)!),
          int.parse(match.group(2)!),
          int.parse(match.group(3)!),
        ) ||
        int.parse(match.group(4)!) > 23 ||
        int.parse(match.group(5)!) > 59 ||
        int.parse(match.group(6)!) > 59 ||
        offsetHour > 23 ||
        offsetMinute > 59) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
    try {
      return DateTime.parse(raw);
    } on FormatException {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
  }

  static const List<int> _daysInMonth = <int>[
    31,
    28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  ];

  static bool _isValidGregorianDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1) return false;
    var maxDay = _daysInMonth[month - 1];
    if (month == 2 && (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))) {
      maxDay = 29;
    }
    return day <= maxDay;
  }

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
          'text': text,
        },
      StudyInlineMathNode(:final latex) => <String, Object?>{
          'type': 'inline_math',
          'latex': latex,
        },
      StudyBlockMathNode(:final latex) => <String, Object?>{
          'type': 'block_math',
          'latex': latex,
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

  String _failure(StudyQueryFailure failure) {
    return jsonEncode(<String, Object?>{
      'ok': false,
      'error': <String, Object?>{
        'code': _codeOf(failure),
        'message': _messageOf(failure),
        'retryable': failure == StudyQueryFailure.temporarilyUnavailable,
      },
    });
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
