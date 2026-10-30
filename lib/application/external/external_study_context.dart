part of 'external_read_context.dart';

/// App-only target enumeration. Implementations check READ and at least one
/// relevant category; this metadata query never returns learning progress.
abstract interface class ExternalStudyTargetReadPort {
  Future<ExternalReadSnapshot> queryStudyTargets(ExternalRuntimeAccess access,
      int? expectedRevision, void Function() check);
}

final class ExternalStudyReadAccess {
  ExternalStudyReadAccess._(this._owner, this.runtime, this._context,
      [List<ExternalReadTarget>? selected])
      : targets = List.unmodifiable(selected ??
            (_context.target == null
                ? _context.snapshot.targets
                : [_context.target!]));
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

  ExternalStudyReadAccess _one(ExternalReadTarget target) =>
      ExternalStudyReadAccess._(_owner, runtime, _context, [target]);
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
  Future<List<int>> scheduled(ExternalStudyReadAccess access, int fromSeconds,
      int toSeconds, void Function() check);
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
          required ExternalCallControl control}) =>
      _run(session, control, (runtime, check, allocations) async {
        final parent = context == null
            ? null
            : _lookup(context, _HandleKind.context, runtime);
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
          if (handle.target != null &&
              !current.targets.contains(handle.target)) {
            externalReadFail(ExternalReadFailure.stale);
          }
          if (handle.questionKey != null) {
            final access = ExternalQuestionReadAccess._(
                this, runtime, handle.parentContext!,
                target: handle.target);
            await _questions!.release(access, [handle.questionKey!], check);
          }
        }
        check();
      });

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

  Future<T> _withStudy<T>(
          ExternalSession session,
          String context,
          ExternalCallControl? control,
          bool statistics,
          Future<T> Function(
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
        return result;
      });

  Future<Map<String, Object?>> listStudyBanks({
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

  Future<Map<String, Object?>> studyOverview({
    required ExternalSession session,
    required String context,
    String timezone = 'UTC',
    ExternalCallControl? control,
  }) =>
      _withStudy(session, context, control, true, (access, check, _) async {
        final now = admission.trust.clock.now();
        const zone = EmbeddedIanaTimeZoneResolver();
        final start = zone.utcInstantOfLocalMidnight(
            zone.localDateOf(now, timezone), timezone);
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

  Future<Map<String, Object?>> studyDueSummary({
    required ExternalSession session,
    required String context,
    required DateTime from,
    required DateTime to,
    String timezone = 'UTC',
    ExternalCallControl? control,
  }) =>
      _withStudy(session, context, control, true, (access, check, _) async {
        if (!from.isBefore(to) ||
            to.difference(from) > const Duration(days: 90)) {
          externalReadFail(ExternalReadFailure.invalidRequest);
        }
        const zone = EmbeddedIanaTimeZoneResolver();
        zone.localDateOf(from, timezone);
        final now = admission.trust.clock.now();
        final due = await _studyReader.dueNow(
            access, now.millisecondsSinceEpoch ~/ 1000, check);
        final times = await _studyReader.scheduled(
            access,
            from.millisecondsSinceEpoch ~/ 1000,
            to.millisecondsSinceEpoch ~/ 1000,
            check);
        final buckets = <String, int>{};
        for (final time in times) {
          final date = zone
              .localDateOf(
                  DateTime.fromMillisecondsSinceEpoch(time * 1000, isUtc: true),
                  timezone)
              .toString();
          buckets[date] = (buckets[date] ?? 0) + 1;
        }
        final dates = buckets.keys.toList()..sort();
        return {
          'dueNow': due,
          'scheduledCount': times.length,
          'buckets': [
            for (final date in dates) {'date': date, 'count': buckets[date]}
          ],
        };
      });

  Future<Map<String, Object?>> studyWeakQuestions({
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
