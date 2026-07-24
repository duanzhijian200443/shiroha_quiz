import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

typedef OcrSmokeReportFileWriter = Future<void> Function(
  File file,
  String contents,
);

const _traceKeys = <String>[
  'number',
  'pageIndex',
  'sectionIndex',
  'blockOrder',
  'markerKind',
  'decision',
  'reason',
  'previousAcceptedNumber',
];

const _markerProbeKeys = <String>[
  'pageIndex',
  'blockOrder',
  'sectionIndex',
  'startsAtBlockStart',
  'startsAtLineBoundary',
  'markerShape',
  'parsedNumber',
  'followerClass',
  'probeReason',
];

const _launcherKeys = <String>[
  'stage',
  'status',
  'causeType',
  'durationMs',
  'buildCacheHit',
  'exitCode',
];

String createOcrSmokeRunId(DateTime now, String shortId) {
  final utc = now.toUtc();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  final timestamp = '${utc.year.toString().padLeft(4, '0')}'
      '${twoDigits(utc.month)}'
      '${twoDigits(utc.day)}-'
      '${twoDigits(utc.hour)}'
      '${twoDigits(utc.minute)}'
      '${twoDigits(utc.second)}';
  final safeShortId = shortId
      .toLowerCase()
      .replaceAll(RegExp('[^a-f0-9]'), '')
      .padRight(8, '0')
      .substring(0, 8);
  return 'ocr-run-$timestamp-$safeShortId';
}

String _randomShortId() {
  final random = Random.secure();
  return List.generate(
    8,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
}

class OcrSmokeReportWriteResult {
  const OcrSmokeReportWriteResult._({
    required this.succeeded,
    required this.runId,
    required this.relativeDirectory,
    required this.summary,
    this.causeType,
  });

  factory OcrSmokeReportWriteResult.success({
    required String runId,
    required String relativeDirectory,
    required Map<String, dynamic> summary,
  }) {
    return OcrSmokeReportWriteResult._(
      succeeded: true,
      runId: runId,
      relativeDirectory: relativeDirectory,
      summary: summary,
    );
  }

  factory OcrSmokeReportWriteResult.failure({
    required String runId,
    required String relativeDirectory,
    required String causeType,
  }) {
    return OcrSmokeReportWriteResult._(
      succeeded: false,
      runId: runId,
      relativeDirectory: relativeDirectory,
      summary: const {},
      causeType: causeType,
    );
  }

  final bool succeeded;
  final String runId;
  final String relativeDirectory;
  final Map<String, dynamic> summary;
  final String? causeType;

  Map<String, dynamic> get failureEvent => {
        'stage': 'report',
        'status': 'report_write_failed',
        'causeType': causeType ?? 'ReportWriteException',
      };

  Map<String, dynamic> get terminalEvent => {
        'stage': 'report',
        'status': 'success',
        'ocrStage': summary['stage'],
        'ocrStatus': summary['status'],
        'traceId': summary['traceId'],
        'durationMs': summary['durationMs'],
        'ocrBlockCount': summary['ocrBlockCount'],
        'questionCandidateCount': summary['questionCandidateCount'],
        'acceptedNumbers': summary['acceptedNumbers'],
        'rejectedCandidateCount': summary['rejectedCandidateCount'],
        'duplicateNumbers': summary['duplicateNumbers'],
        'missingNumbers': summary['missingNumbers'],
        'firstAnomaly': summary['firstAnomaly'],
        'reportDirectory': relativeDirectory,
      };
}

class OcrSmokeReportWriter {
  OcrSmokeReportWriter({
    required this.repositoryRoot,
    String? runId,
    String Function()? traceIdFactory,
    OcrSmokeReportFileWriter? fileWriter,
  })  : runId = _validRunId(runId)
            ? runId!
            : createOcrSmokeRunId(DateTime.now().toUtc(), _randomShortId()),
        _traceIdFactory = traceIdFactory ?? _defaultTraceId,
        _fileWriter = fileWriter ?? _writeFile;

  final String repositoryRoot;
  final String runId;
  final String Function() _traceIdFactory;
  final OcrSmokeReportFileWriter _fileWriter;

  String get relativeDirectory => 'scratch/ocr_reports/$runId';

  Future<OcrSmokeReportWriteResult> write({
    required List<Map<String, dynamic>> events,
    required int exitCode,
    required bool? buildCacheHit,
  }) async {
    final trace = _collectTrace(events);
    final markerProbeTrace = _collectMarkerProbeTrace(events);
    final parseEvents = events
        .where((event) => event['stage'] == 'independent_parse')
        .toList(growable: false);
    final outcome = _selectOutcome(events);
    final acceptedNumbers = _collectIntegerList(
      parseEvents,
      'acceptedNumbers',
    );
    final duplicateNumbers = _collectDuplicates(parseEvents, acceptedNumbers);
    final missingNumbers = _collectMissingNumbers(parseEvents);
    final rejected = trace
        .where((entry) => entry['decision'] == 'rejected')
        .toList(growable: false);
    final firstAnomaly = rejected.isEmpty
        ? null
        : <String, dynamic>{
            'number': rejected.first['number'],
            'decision': rejected.first['decision'],
            'reason': rejected.first['reason'],
          };

    final summary = <String, dynamic>{
      'schemaVersion': 1,
      'runId': runId,
      'traceId': _traceIdFactory(),
      'stage': outcome?['stage'],
      'status': outcome?['status'],
      'durationMs': _sumReliableIntegers(parseEvents, 'durationMs') ??
          _safeInteger(outcome?['durationMs']),
      'ocrBlockCount': _sumReliableIntegers(parseEvents, 'blockCount'),
      'questionCandidateCount':
          _traceIsReliable(parseEvents) ? trace.length : null,
      'acceptedNumbers': acceptedNumbers,
      'rejectedCandidateCount':
          _traceIsReliable(parseEvents) ? rejected.length : null,
      'regionCount': _sumReliableIntegers(parseEvents, 'regionCount'),
      'assembledQuestionCount':
          _sumReliableIntegers(parseEvents, 'assembledQuestionCount'),
      'finalQuestionCount':
          _sumReliableIntegers(parseEvents, 'finalQuestionCount'),
      'duplicateNumbers': duplicateNumbers,
      'missingNumbers': missingNumbers,
      'referenceSectionDetected':
          _combineReliableBooleans(parseEvents, 'referenceSectionDetected'),
      'referenceSectionCandidateCount': _sumReliableIntegers(
        parseEvents,
        'referenceSectionCandidateCount',
      ),
      'questionCandidateTraceTruncated': _combineReliableBooleans(
        parseEvents,
        'questionCandidateTraceTruncated',
      ),
      'markerProbeCount': _markerProbeTraceIsReliable(parseEvents)
          ? markerProbeTrace.length
          : null,
      'markerProbeTraceTruncated': _combineReliableBooleans(
        parseEvents,
        'markerProbeTraceTruncated',
      ),
      'firstAnomaly': firstAnomaly,
    };
    final launcherEvents = _buildLauncherEvents(
      events,
      outcome: outcome,
      exitCode: exitCode,
      buildCacheHit: buildCacheHit,
    );

    try {
      final directory = Directory(
        p.join(repositoryRoot, 'scratch', 'ocr_reports', runId),
      );
      await directory.create(recursive: true);
      const encoder = JsonEncoder.withIndent('  ');
      await _fileWriter(
        File(p.join(directory.path, 'summary.json')),
        '${encoder.convert(summary)}\n',
      );
      await _fileWriter(
        File(p.join(directory.path, 'candidate_trace.json')),
        '${encoder.convert(trace)}\n',
      );
      await _fileWriter(
        File(p.join(directory.path, 'rejected_candidates.json')),
        '${encoder.convert(rejected)}\n',
      );
      await _fileWriter(
        File(p.join(directory.path, 'marker_probe_trace.json')),
        '${encoder.convert(markerProbeTrace)}\n',
      );
      await _fileWriter(
        File(p.join(directory.path, 'launcher.log')),
        '${encoder.convert(launcherEvents)}\n',
      );
      return OcrSmokeReportWriteResult.success(
        runId: runId,
        relativeDirectory: relativeDirectory,
        summary: summary,
      );
    } catch (error) {
      return OcrSmokeReportWriteResult.failure(
        runId: runId,
        relativeDirectory: relativeDirectory,
        causeType: error.runtimeType.toString(),
      );
    }
  }

  static bool _validRunId(String? value) {
    if (value == null) return false;
    return RegExp(r'^ocr-run-\d{8}-\d{6}-[a-f0-9]{8}$').hasMatch(value);
  }

  static String _defaultTraceId() {
    return 'trace-${createOcrSmokeRunId(
      DateTime.now().toUtc(),
      _randomShortId(),
    ).substring(8)}';
  }

  static Future<void> _writeFile(File file, String contents) {
    return file.writeAsString(contents, flush: true);
  }
}

List<Map<String, dynamic>> _collectTrace(
  List<Map<String, dynamic>> events,
) {
  final trace = <Map<String, dynamic>>[];
  for (final event in events) {
    final candidates = event['questionCandidateTrace'];
    if (candidates is! List) continue;
    for (final candidate in candidates) {
      if (candidate is! Map) continue;
      trace.add({
        for (final key in _traceKeys) key: _safeTraceValue(key, candidate[key]),
      });
    }
  }
  trace.sort((left, right) {
    final pageComparison =
        _sortableInteger(left['pageIndex']).compareTo(_sortableInteger(
      right['pageIndex'],
    ));
    if (pageComparison != 0) return pageComparison;
    return _sortableInteger(left['blockOrder']).compareTo(
      _sortableInteger(right['blockOrder']),
    );
  });
  return trace;
}

List<Map<String, dynamic>> _collectMarkerProbeTrace(
  List<Map<String, dynamic>> events,
) {
  final trace = <Map<String, dynamic>>[];
  for (final event in events) {
    final probes = event['markerProbeTrace'];
    if (probes is! List) continue;
    for (final probe in probes) {
      if (probe is! Map) continue;
      trace.add({
        for (final key in _markerProbeKeys)
          key: _safeMarkerProbeValue(key, probe[key]),
      });
    }
  }
  trace.sort((left, right) {
    final pageComparison =
        _sortableInteger(left['pageIndex']).compareTo(_sortableInteger(
      right['pageIndex'],
    ));
    if (pageComparison != 0) return pageComparison;
    return _sortableInteger(left['blockOrder']).compareTo(
      _sortableInteger(right['blockOrder']),
    );
  });
  return trace;
}

Object? _safeTraceValue(String key, Object? value) {
  return switch (key) {
    'number' ||
    'pageIndex' ||
    'sectionIndex' ||
    'blockOrder' ||
    'previousAcceptedNumber' =>
      _safeInteger(value),
    'markerKind' || 'decision' || 'reason' => value is String ? value : null,
    _ => null,
  };
}

Object? _safeMarkerProbeValue(String key, Object? value) {
  return switch (key) {
    'pageIndex' ||
    'blockOrder' ||
    'sectionIndex' ||
    'parsedNumber' =>
      _safeInteger(value),
    'startsAtBlockStart' ||
    'startsAtLineBoundary' =>
      value is bool ? value : null,
    'markerShape' ||
    'followerClass' ||
    'probeReason' =>
      value is String ? value : null,
    _ => null,
  };
}

int _sortableInteger(Object? value) => _safeInteger(value) ?? 0x7fffffff;

int? _safeInteger(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  return null;
}

Map<String, dynamic>? _selectOutcome(
  List<Map<String, dynamic>> events,
) {
  for (final event in events.reversed) {
    if (event['stage'] == 'completed' && event['status'] != null) {
      return event;
    }
  }
  for (final event in events.reversed) {
    if (event['status'] != null) return event;
  }
  return events.isEmpty ? null : events.last;
}

bool _traceIsReliable(List<Map<String, dynamic>> parseEvents) {
  return parseEvents.isNotEmpty &&
      parseEvents.every((event) => event['questionCandidateTrace'] is List);
}

bool _markerProbeTraceIsReliable(List<Map<String, dynamic>> parseEvents) {
  return parseEvents.isNotEmpty &&
      parseEvents.every((event) => event['markerProbeTrace'] is List);
}

int? _sumReliableIntegers(
  List<Map<String, dynamic>> events,
  String key,
) {
  if (events.isEmpty) return null;
  var total = 0;
  for (final event in events) {
    final value = _safeInteger(event[key]);
    if (value == null) return null;
    total += value;
  }
  return total;
}

List<int>? _collectIntegerList(
  List<Map<String, dynamic>> events,
  String key,
) {
  if (events.isEmpty) return null;
  final values = <int>[];
  for (final event in events) {
    final rawValues = event[key];
    if (rawValues is! List) return null;
    for (final value in rawValues) {
      final number = _safeInteger(value);
      if (number != null) values.add(number);
    }
  }
  return values;
}

List<int>? _collectDuplicates(
  List<Map<String, dynamic>> events,
  List<int>? acceptedNumbers,
) {
  final explicit = _collectIntegerList(events, 'duplicateNumbers');
  if (explicit != null) return explicit.toSet().toList()..sort();
  if (acceptedNumbers == null) return null;
  final counts = <int, int>{};
  for (final number in acceptedNumbers) {
    counts[number] = (counts[number] ?? 0) + 1;
  }
  return counts.entries
      .where((entry) => entry.value > 1)
      .map((entry) => entry.key)
      .toList()
    ..sort();
}

List<int>? _collectMissingNumbers(
  List<Map<String, dynamic>> events,
) {
  if (events.isEmpty) return null;
  final values = <int>{};
  for (final event in events) {
    final missing = event['missingNumbers'];
    final tailMissing = event['tailMissingNumbers'];
    if (missing is! List && tailMissing is! List) return null;
    for (final collection in [missing, tailMissing]) {
      if (collection is! List) continue;
      for (final value in collection) {
        final number = _safeInteger(value);
        if (number != null) values.add(number);
      }
    }
  }
  return values.toList()..sort();
}

bool? _combineReliableBooleans(
  List<Map<String, dynamic>> events,
  String key,
) {
  if (events.isEmpty) return null;
  var result = false;
  for (final event in events) {
    final value = event[key];
    if (value is! bool) return null;
    result = result || value;
  }
  return result;
}

List<Map<String, dynamic>> _buildLauncherEvents(
  List<Map<String, dynamic>> events, {
  required Map<String, dynamic>? outcome,
  required int exitCode,
  required bool? buildCacheHit,
}) {
  final launcherEvents = <Map<String, dynamic>>[];
  for (final event in events) {
    final safeEvent = <String, dynamic>{
      for (final key in _launcherKeys)
        if (event.containsKey(key)) key: _safeLauncherValue(key, event[key]),
    };
    if (safeEvent.isNotEmpty) launcherEvents.add(safeEvent);
  }
  launcherEvents.add({
    'stage': outcome?['stage'],
    'status': outcome?['status'],
    'buildCacheHit': buildCacheHit,
    'exitCode': exitCode,
  });
  return launcherEvents;
}

Object? _safeLauncherValue(String key, Object? value) {
  return switch (key) {
    'durationMs' || 'exitCode' => _safeInteger(value),
    'buildCacheHit' => value is bool ? value : null,
    'stage' || 'status' || 'causeType' => value is String ? value : null,
    _ => null,
  };
}
