part of 'external_read_context.dart';

/// App-only target enumeration. Implementations check READ and at least one
/// relevant category; this metadata query never returns learning progress.
abstract interface class ExternalStudyTargetReadPort {
  Future<ExternalReadSnapshot> queryStudyTargets(ExternalRuntimeAccess access,
      int? expectedRevision, void Function() check);
}

final class ExternalStudyReadAccess {
  ExternalStudyReadAccess._(this._owner, this.runtime, this._context,
      [List<ExternalReadTarget>? selected, _StudyRevision? revision])
      : _revision = revision ?? _StudyRevision(),
        targets = List.unmodifiable(selected ??
            (_context.target == null
                ? _context.snapshot.targets
                : [_context.target!]));
  final _StudyRevision _revision;
  final ExternalReadContextService _owner;
  final ExternalRuntimeAccess runtime;
  final _Handle _context;
  final List<ExternalReadTarget> targets;
  int get revision => _context.snapshot.grant.revision;
  DateTime get expiresAt => _context.expiresAt;
  Set<String> get bankNames => targets.map((t) => t.bankName).toSet();
  void validate() {
    runtime.validate();
    _context.access.validate();
    if (_owner._closed ||
        !_owner._handles.values.contains(_context) ||
        !_owner.admission.trust.clock.now().isBefore(_context.expiresAt) ||
        targets.any((t) => !_context.snapshot.targets.contains(t))) {
      externalReadFail(ExternalReadFailure.denied);
    }
  }

  ExternalQuestionReadAccess questionAccess(ExternalReadTarget target) {
    validate();
    if (!targets.contains(target)) externalReadFail(ExternalReadFailure.denied);
    return ExternalQuestionReadAccess._(_owner, runtime, _context,
        target: target);
  }

  /// The Data owner pins a read-only database revision for this invocation.
  /// Later pages and both output gates must observe the same revision.
  void bindDataRevision(Object owner, int changes, int dataVersion) {
    validate();
    final value = (owner, changes, dataVersion);
    if (_revision.value != null && _revision.value != value) {
      externalReadFail(ExternalReadFailure.stale);
    }
    _revision.value = value;
  }

  ExternalStudyReadAccess _one(ExternalReadTarget target) =>
      ExternalStudyReadAccess._(_owner, runtime, _context, [target], _revision);
}

final class _StudyRevision {
  (Object, int, int)? value;
}

final class ExternalScheduledReview {
  const ExternalScheduledReview(this.time, this.id);
  final int time;
  final String id;
}

/// Safe projection plus invocation-local proof for the Kernel's final gate.
final class ExternalStudyResult {
  ExternalStudyResult._(this._access, Map<String, Object?> value)
      : _value = Map.unmodifiable(value);
  final ExternalStudyReadAccess _access;
  final Map<String, Object?> _value;
  Map<String, Object?> toJson() => _value;
  List<String> get references => [
        for (final item in (_value['items'] as List? ?? const []))
          if (item is Map &&
              (item['targetRef'] ?? item['questionRef']) is String)
            (item['targetRef'] ?? item['questionRef']) as String,
        if (_value['nextCursor'] is String) _value['nextCursor'] as String,
      ];
  Future<void> release(ExternalSession session, String context,
          ExternalCallControl control) =>
      _access._owner.releaseStudyCapabilityOutput(
          session: session,
          context: context,
          references: references,
          control: control,
          dataAccess: _access);
}

final class ExternalWeakCandidate {
  const ExternalWeakCandidate(this.target, this.question, this.lapseCount,
      this.difficulty, this.lastLapseTime);
  final ExternalReadTarget target;
  final ExternalQuestionCandidate question;
  final int lapseCount;
  final double difficulty;
  final int? lastLapseTime;
}

/// Data receives an App-minted, scope-bound proof, never client bank names.
abstract interface class ExternalStudyReadPort {
  Future<StudyOverviewCounts> overview(ExternalStudyReadAccess access,
      int nowSeconds, int todayStartSeconds, void Function() check);
  // Each page uses the existing 128-candidate bound; the owning READ deadline
  // bounds the complete scan and no partial summary is released.
  Future<List<ExternalScheduledReview>> scheduled(
      ExternalStudyReadAccess access,
      int fromSeconds,
      int toSeconds,
      ExternalScheduledReview? after,
      void Function() check);
  Future<void> release(ExternalStudyReadAccess access, void Function() check);
  Future<int> dueNow(
      ExternalStudyReadAccess access, int nowSeconds, void Function() check);
  Future<List<ExternalWeakCandidate>> weak(ExternalStudyReadAccess access,
      int limit, int? afterLapse, String? afterId, void Function() check);
}

extension ExternalStudyContexts on ExternalReadContextService {
  bool get studyQueriesAvailable =>
      _study != null && _targets is ExternalStudyTargetReadPort;
  ExternalStudyTargetReadPort get _studyTargets =>
      _targets is ExternalStudyTargetReadPort
          ? _targets as ExternalStudyTargetReadPort
          : externalReadFail(ExternalReadFailure.unavailable);
  ExternalStudyReadPort get _studyReader =>
      _study ?? externalReadFail(ExternalReadFailure.unavailable);

  Future<ExternalStudyReadAccess> studyCapabilityAccess({
    required ExternalSession session,
    required String context,
  }) =>
      _run(session, null, (runtime, check, allocations) async {
        final parent = _lookup(context, _HandleKind.context, runtime);
        final current = await _studyTargets.queryStudyTargets(
            runtime, parent.snapshot.grant.revision, check);
        if (parent.target == null
            ? !_same(current, parent.snapshot)
            : !current.targets.contains(parent.target)) {
          externalReadFail(ExternalReadFailure.stale);
        }
        final access = ExternalStudyReadAccess._(this, runtime, parent);
        access.validate();
        return access;
      });

  Future<ExternalQuestionReadAccess> capabilityAccessForQuestion({
    required ExternalSession session,
    required String context,
    required String questionRef,
  }) =>
      _run(session, null, (runtime, check, allocations) async {
        final parent = _lookup(context, _HandleKind.context, runtime);
        final question = _lookup(questionRef, _HandleKind.question, runtime);
        if (!identical(question.parentContext, parent)) {
          externalReadFail(ExternalReadFailure.denied);
        }
        final current = await _targets.query(
            runtime, parent.snapshot.grant.revision, check);
        if (!current.targets.contains(question.target)) {
          externalReadFail(ExternalReadFailure.stale);
        }
        final access = ExternalQuestionReadAccess._(this, runtime, parent,
            target: question.target);
        access.validate();
        return access;
      });

  Future<void> releaseStudyCapabilityOutput(
          {required ExternalSession session,
          String? context,
          required List<String> references,
          required ExternalCallControl control,
          ExternalStudyReadAccess? dataAccess}) =>
      _run(
          session,
          control,
          (runtime, check, allocations) => _releaseStudyOutput(runtime, check,
              context: context,
              references: references,
              dataAccess: dataAccess));

  Future<void> _releaseStudyOutput(
      ExternalRuntimeAccess runtime, void Function() check,
      {String? context,
      required List<String> references,
      ExternalStudyReadAccess? dataAccess}) async {
    final parent =
        context == null ? null : _lookup(context, _HandleKind.context, runtime);
    final selected = <_Handle>[];
    for (final token in references) {
      final found = _handles[token];
      if (found == null) externalReadFail(ExternalReadFailure.denied);
      final handle = _lookup(token, found.kind, runtime);
      if (parent != null &&
          !identical(parent, handle) &&
          !identical(handle.parentContext, parent)) {
        externalReadFail(ExternalReadFailure.denied);
      }
      selected.add(handle);
    }
    final snapshot = parent?.snapshot ?? selected.firstOrNull?.snapshot;
    if (snapshot == null) externalReadFail(ExternalReadFailure.denied);
    final current = await _studyTargets.queryStudyTargets(
        runtime, snapshot.grant.revision, check);
    if (parent?.target == null && !_same(current, snapshot)) {
      externalReadFail(ExternalReadFailure.stale);
    }
    for (final handle in [if (parent != null) parent, ...selected]) {
      if (handle.target != null && !current.targets.contains(handle.target)) {
        externalReadFail(ExternalReadFailure.stale);
      }
      if (handle.questionKey != null) {
        final access = ExternalQuestionReadAccess._(
            this, runtime, handle.parentContext!,
            target: handle.target);
        await _questions!.release(access, [handle.questionKey!], check);
      }
    }
    if (dataAccess != null && dataAccess._revision.value != null) {
      await _studyReader.release(dataAccess, check);
    }
    check();
  }

  Future<String> openStudyContext({
    required ExternalSession session,
    String? targetRef,
    ExternalCallControl? control,
  }) =>
      _run(session, control, (runtime, check, allocations) async {
        final chosen = targetRef == null
            ? null
            : _lookup(targetRef, _HandleKind.target, runtime);
        final snapshot = await _studyTargets.queryStudyTargets(
            runtime, chosen?.snapshot.grant.revision, check);
        if (chosen != null && !snapshot.targets.contains(chosen.target)) {
          externalReadFail(ExternalReadFailure.stale);
        }
        check();
        final now = admission.trust.clock.now();
        return _mint(
            _Handle(_HandleKind.context, runtime, snapshot, now,
                now.add(contextLifetime),
                target: chosen?.target),
            allocations);
      });

  Future<ExternalStudyResult> _withStudy(
          ExternalSession session,
          String context,
          ExternalCallControl? control,
          bool statistics,
          Future<Map<String, Object?>> Function(
                  ExternalStudyReadAccess, void Function(), List<String>)
              body) =>
      _run(session, control, (runtime, check, allocations) async {
        final handle = _lookup(context, _HandleKind.context, runtime);
        final current = await _studyTargets.queryStudyTargets(
            runtime, handle.snapshot.grant.revision, check);
        if (handle.target == null
            ? !_same(current, handle.snapshot)
            : !current.targets.contains(handle.target)) {
          externalReadFail(ExternalReadFailure.stale);
        }
        if (statistics &&
            !current.grant.policy.categories
                .contains(ExternalContentCategory.studyStatistics)) {
          externalReadFail(ExternalReadFailure.denied);
        }
        final access = ExternalStudyReadAccess._(this, runtime, handle);
        access.validate();
        final result = await body(access, check, allocations);
        final release = await _studyTargets.queryStudyTargets(
            runtime, access.revision, check);
        if (handle.target == null
            ? !_same(current, release)
            : !release.targets.contains(handle.target)) {
          externalReadFail(ExternalReadFailure.stale);
        }
        check();
        access.validate();
        if (utf8.encode(jsonEncode(result)).length > maxResponseBytes) {
          externalReadFail(ExternalReadFailure.resourceLimit);
        }
        final output = ExternalStudyResult._(access, result);
        await _releaseStudyOutput(runtime, check,
            context: context,
            references: output.references,
            dataAccess: access);
        check();
        return output;
      });

  Future<ExternalStudyResult> listStudyBanks({
    required ExternalSession session,
    required String context,
    int pageSize = 20,
    String? cursor,
    ExternalCallControl? control,
  }) =>
      _withStudy(session, context, control, false,
          (access, check, allocations) async {
        if (pageSize < 1 || pageSize > 50) {
          externalReadFail(ExternalReadFailure.invalidRequest);
        }
        final parent = access._context;
        final previous = cursor == null
            ? null
            : _lookup(cursor, _HandleKind.studyCursor, access.runtime);
        if (previous != null &&
            (!identical(previous.parentContext, parent) ||
                previous.query != 'banks')) {
          externalReadFail(ExternalReadFailure.denied);
        }
        final byBank = <String, ExternalReadTarget>{};
        for (final target in access.targets) {
          byBank.putIfAbsent(target.bankName, () => target);
        }
        final targets = byBank.values.toList()
          ..sort((a, b) => a.bankName.compareTo(b.bankName));
        final offset = previous?.offset ?? 0;
        final end = min(targets.length, offset + pageSize);
        final now = admission.trust.clock.now();
        final canReadStatistics = parent.snapshot.grant.policy.categories
            .contains(ExternalContentCategory.studyStatistics);
        final items = <Map<String, Object?>>[];
        for (final target in targets.sublist(offset, end)) {
          final counts = canReadStatistics
              ? await _studyReader.overview(access._one(target),
                  now.millisecondsSinceEpoch ~/ 1000, 0, check)
              : null;
          final ref = _mint(
              _Handle(_HandleKind.target, access.runtime, parent.snapshot, now,
                  parent.expiresAt,
                  target: target, parentContext: parent),
              allocations);
          items.add({
            'targetRef': ref,
            'bankName': target.bankName,
            'folderName': target.folderName,
            if (counts != null) ...{
              'questionCount': counts.questionCount,
              'dueCount': counts.dueCount,
              'masteredCount': counts.masteredCount,
            },
          });
        }
        return {
          'items': items,
          'statisticsAuthorized': canReadStatistics,
          'nextCursor': end == targets.length
              ? null
              : _mint(
                  _Handle(_HandleKind.studyCursor, access.runtime,
                      parent.snapshot, now, parent.expiresAt,
                      parentContext: parent, offset: end, query: 'banks'),
                  allocations),
        };
      });

  Future<ExternalStudyResult> studyOverview({
    required ExternalSession session,
    required String context,
    String? timezone,
    ExternalCallControl? control,
  }) =>
      _withStudy(session, context, control, true, (access, check, _) async {
        final now = admission.trust.clock.now();
        const zone = EmbeddedIanaTimeZoneResolver();
        final selectedZone = _studyTimezone(timezone ?? studyTimeZone);
        final start = zone.utcInstantOfLocalMidnight(
            zone.localDateOf(now, selectedZone), selectedZone);
        final counts = await _studyReader.overview(
            access,
            now.millisecondsSinceEpoch ~/ 1000,
            start.millisecondsSinceEpoch ~/ 1000,
            check);
        return {
          'questionCount': counts.questionCount,
          'masteredCount': counts.masteredCount,
          'dueCount': counts.dueCount,
          'todayPracticeCount': counts.todayPracticeCount,
          'wrongQuestionCount': counts.wrongQuestionCount,
        };
      });

  Future<ExternalStudyResult> studyDueSummary({
    required ExternalSession session,
    required String context,
    required DateTime from,
    required DateTime to,
    String? timezone,
    ExternalCallControl? control,
  }) =>
      _withStudy(session, context, control, true, (access, check, _) async {
        if (!from.isBefore(to) ||
            to.difference(from) > const Duration(days: 90)) {
          externalReadFail(ExternalReadFailure.invalidRequest);
        }
        const zone = EmbeddedIanaTimeZoneResolver();
        final selectedZone = _studyTimezone(timezone ?? studyTimeZone);
        zone.localDateOf(from, selectedZone);
        final now = admission.trust.clock.now();
        final due = await _studyReader.dueNow(
            access, now.millisecondsSinceEpoch ~/ 1000, check);
        final buckets = <String, int>{};
        ExternalScheduledReview? after;
        var count = 0;
        while (true) {
          check();
          final page = await _studyReader.scheduled(access,
              _studyWindowSecond(from), _studyWindowSecond(to), after, check);
          for (final item in page) {
            final time = item.time;
            final date = zone
                .localDateOf(
                    DateTime.fromMillisecondsSinceEpoch(time * 1000,
                        isUtc: true),
                    selectedZone)
                .toString();
            buckets[date] = (buckets[date] ?? 0) + 1;
            count++;
          }
          if (page.length < 128) break;
          after = page.last;
        }
        final dates = buckets.keys.toList()..sort();
        return {
          'dueNow': due,
          'scheduledCount': count,
          'buckets': [
            for (final date in dates) {'date': date, 'count': buckets[date]}
          ],
        };
      });

  Future<ExternalStudyResult> studyWeakQuestions({
    required ExternalSession session,
    required String context,
    int pageSize = 20,
    String? cursor,
    ExternalCallControl? control,
  }) =>
      _withStudy(session, context, control, true,
          (access, check, allocations) async {
        if (pageSize < 1 || pageSize > 50) {
          externalReadFail(ExternalReadFailure.invalidRequest);
        }
        final parent = access._context;
        if (!parent.snapshot.grant.policy.categories
            .contains(ExternalContentCategory.questionContent)) {
          externalReadFail(ExternalReadFailure.denied);
        }
        final previous = cursor == null
            ? null
            : _lookup(cursor, _HandleKind.studyCursor, access.runtime);
        if (previous != null &&
            (!identical(previous.parentContext, parent) ||
                previous.query != 'weak')) {
          externalReadFail(ExternalReadFailure.denied);
        }
        final page = await _studyReader.weak(access, pageSize,
            previous?.lastLapse, previous?.lastQuestionId, check);
        final now = admission.trust.clock.now();
        final selected = page.take(pageSize).toList();
        final items = <Map<String, Object?>>[];
        for (final item in selected) {
          final ref = _mint(
              _Handle(_HandleKind.question, access.runtime, parent.snapshot,
                  now, parent.expiresAt,
                  target: item.target,
                  parentContext: parent,
                  questionKey: item.question.key),
              allocations);
          items.add({
            'questionRef': ref,
            'bankName': item.target.bankName,
            'stemPreview': item.question.summary.stemPreview,
            'lapseCount': item.lapseCount,
            'difficulty': item.difficulty,
            'lastLapseAt':
                item.lastLapseTime == null || item.lastLapseTime! <= 0
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(
                            item.lastLapseTime! * 1000,
                            isUtc: true)
                        .toIso8601String(),
          });
        }
        final last = selected.lastOrNull;
        return {
          'items': items,
          'nextCursor': page.length <= pageSize || last == null
              ? null
              : _mint(
                  _Handle(_HandleKind.studyCursor, access.runtime,
                      parent.snapshot, now, parent.expiresAt,
                      parentContext: parent,
                      query: 'weak',
                      lastLapse: last.lastLapseTime ?? 0,
                      lastQuestionId: last.question.key.storageId),
                  allocations),
        };
      });
}

String _studyTimezone(String value) {
  try {
    final zone = value.trim();
    const EmbeddedIanaTimeZoneResolver().localDateOf(DateTime.utc(2026), zone);
    return zone;
  } on StudyQueryException {
    externalReadFail(ExternalReadFailure.invalidRequest);
  }
}

// Review timestamps are integer seconds. Ceil both edges so fractional RFC
// instants still select exactly [from, to), including dates before the epoch.
int _studyWindowSecond(DateTime value) {
  final micros = value.microsecondsSinceEpoch;
  final seconds = micros ~/ Duration.microsecondsPerSecond;
  return micros > 0 && micros.remainder(Duration.microsecondsPerSecond) != 0
      ? seconds + 1
      : seconds;
}
