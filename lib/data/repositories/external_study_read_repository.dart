import '../../application/capabilities/capability.dart';
import '../../application/external/external_authorization.dart';
import '../../application/external/external_read_context.dart';
import '../../application/study_query/study_query_ports.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/external_authorization_schema.dart';
import '../../core/database/sqflite_runtime.dart';
import 'external_authorization_repository.dart';
import 'external_question_read_repository.dart';

/// T0 metrics over a set fixed by the App before any statistics SQL executes.
/// Question IDs deduplicate overlapping Project/bank grants through one IN set.
final class SqliteExternalStudyReadRepository implements ExternalStudyReadPort {
  SqliteExternalStudyReadRepository(
      {DatabaseHelper? databaseHelper, Future<void> Function()? afterQuery})
      : _helper = databaseHelper ?? DatabaseHelper.instance,
        _afterQuery = afterQuery;
  final DatabaseHelper _helper;
  final Future<void> Function()? _afterQuery;

  Future<T> _read<T>(ExternalStudyReadAccess access, void Function() check,
      Future<T> Function(Transaction, List<String>, String) query) async {
    check();
    access.validate();
    final db = await _helper.database;
    check();
    try {
      final result = await db.transaction((txn) async {
        final record =
            await readExternalAuthorization(txn, access.runtime.profileId);
        final grant = record.grant;
        if (record.profile.revokedAtUtcMs != null ||
            grant == null ||
            grant.revokedAtUtcMs != null ||
            grant.revision != access.revision ||
            !grant.policy.permissions.contains(CapabilityPermission.read) ||
            !grant.policy.categories
                .contains(ExternalContentCategory.studyStatistics)) {
          externalReadFail(ExternalReadFailure.denied);
        }
        for (final target in access.targets) {
          await requireExternalGrant(
              txn,
              access.runtime.profileId,
              access.revision,
              CapabilityPermission.read,
              target.scope,
              ExternalContentCategory.studyStatistics,
              access.runtime.profileId);
          check();
        }
        final banks = access.bankNames.toList()..sort();
        final predicate = banks.isEmpty
            ? '0'
            : 'q.bank_name IN (${List.filled(banks.length, '?').join(',')})';
        final value = await query(txn, banks, predicate);
        check();
        access.validate();
        return value;
      });
      await _afterQuery?.call();
      check();
      access.validate();
      return result;
    } on ExternalReadException {
      rethrow;
    } on ExternalAuthException {
      externalReadFail(ExternalReadFailure.denied);
    } catch (_) {
      externalReadFail(ExternalReadFailure.dataCorrupt);
    }
  }

  @override
  Future<StudyOverviewCounts> overview(ExternalStudyReadAccess access,
          int nowSeconds, int todayStartSeconds, void Function() check) =>
      _read(access, check, (db, banks, where) async {
        // Exact T0 definitions, with authorization limiting q before aggregation.
        final rows = await db.rawQuery('''
          SELECT COUNT(DISTINCT q.id) AS question_count,
            COUNT(DISTINCT CASE WHEN rs.state=3 THEN q.id END) AS mastered_count,
            COUNT(DISTINCT CASE WHEN rs.next_review_time<=? THEN q.id END) AS due_count,
            COUNT(DISTINCT CASE WHEN rl.review_time>=? THEN q.id END) AS today_count,
            COUNT(DISTINCT CASE WHEN (
              EXISTS (SELECT 1 FROM answer_attempts aa WHERE aa.question_id=q.id AND aa.correctness=0)
              OR (rs.lapses IS NOT NULL AND rs.lapses>0)
            ) THEN q.id END) AS wrong_count
          FROM questions q
          LEFT JOIN review_states rs ON rs.question_id=q.id
          LEFT JOIN review_logs rl ON rl.question_id=q.id
          WHERE $where
        ''', [nowSeconds, todayStartSeconds, ...banks]);
        final row = rows.single;
        int count(String name) => (row[name] as num).toInt();
        return StudyOverviewCounts(
            questionCount: count('question_count'),
            masteredCount: count('mastered_count'),
            dueCount: count('due_count'),
            todayPracticeCount: count('today_count'),
            wrongQuestionCount: count('wrong_count'));
      });

  @override
  Future<int> dueNow(ExternalStudyReadAccess access, int nowSeconds,
          void Function() check) =>
      _read(access, check, (db, banks, where) async {
        final rows = await db.rawQuery('''SELECT COUNT(*) AS count
          FROM review_states rs JOIN questions q ON q.id=rs.question_id
          WHERE $where AND rs.next_review_time<=?''', [...banks, nowSeconds]);
        return (rows.single['count'] as num).toInt();
      });

  @override
  Future<List<int>> scheduled(ExternalStudyReadAccess access, int fromSeconds,
          int toSeconds, void Function() check) =>
      _read(access, check, (db, banks, where) async {
        final rows = await db.rawQuery('''SELECT rs.next_review_time
          FROM review_states rs JOIN questions q ON q.id=rs.question_id
          WHERE $where AND rs.state>0 AND rs.next_review_time IS NOT NULL
            AND rs.next_review_time>=? AND rs.next_review_time<?
          ORDER BY rs.next_review_time ASC''',
            [...banks, fromSeconds, toSeconds]);
        return rows.map((r) => (r['next_review_time'] as num).toInt()).toList();
      });

  @override
  Future<List<ExternalWeakCandidate>> weak(ExternalStudyReadAccess access,
          int limit, int? afterLapse, String? afterId, void Function() check) =>
      _read(access, check, (db, banks, where) async {
        final rows = await db.rawQuery('''
          SELECT q.id, q.bank_name, r.lapses, r.difficulty, r.last_lapse_time
          FROM questions q JOIN review_states r ON r.question_id=q.id
          WHERE $where AND r.lapses>0
            AND (? IS NULL OR COALESCE(r.last_lapse_time,0)<?
              OR (COALESCE(r.last_lapse_time,0)=? AND q.id<?))
          ORDER BY COALESCE(r.last_lapse_time,0) DESC, q.id DESC LIMIT ?
        ''',
            [...banks, afterLapse, afterLapse, afterLapse, afterId, limit + 1]);
        final questions =
            SqliteExternalQuestionReadRepository(databaseHelper: _helper);
        final result = <ExternalWeakCandidate>[];
        for (final row in rows) {
          final id = row['id'];
          final lapses = row['lapses'];
          final difficulty = row['difficulty'];
          final last = row['last_lapse_time'];
          if (id is! String ||
              id.length > 256 ||
              lapses is! int ||
              difficulty is! num ||
              !difficulty.isFinite ||
              (last != null && last is! int)) {
            externalReadFail(ExternalReadFailure.dataCorrupt);
          }
          final target =
              access.targets.firstWhere((t) => t.bankName == row['bank_name']);
          final candidate = await questions.studyCandidate(
              db, access.questionAccess(target), id, check);
          result.add(ExternalWeakCandidate(
              target, candidate, lapses, difficulty.toDouble(), last as int?));
        }
        return result;
      });
}
