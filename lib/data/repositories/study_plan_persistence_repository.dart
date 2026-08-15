/// Durable SQLite implementation of the SPL-1 StudyPlan persistence seam.
///
/// Owns: durable ActiveStudyPlan load, atomic adoption commitment with
/// in-transaction source-turn revalidation and CAS, and atomic stop CAS.
///
/// SPL-1-D1 scope: writes to `study_plans` only. ZERO mutation to
/// `questions`, `review_states`, `conversations`, `projects`, or `settings`.
library;

import 'package:sqflite/sqflite.dart';

import '../../application/study_plan/study_plan_ports.dart';
import '../../core/database/database_helper.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/study_plan/active_study_plan.dart';
import '../../domain/study_plan/study_plan_values.dart';

class StudyPlanPersistenceRepository implements StudyPlanPersistencePort {
  StudyPlanPersistenceRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final StudyPlanPersistenceRepository instance =
      StudyPlanPersistenceRepository();

  final DatabaseHelper _databaseHelper;

  @override
  Future<ActiveStudyPlan?> loadActivePlan() async {
    try {
      final db = await _databaseHelper.database;
      final rows = await db.query(
        'study_plans',
        columns: const <String>[
          'plan_id',
          'bank_name',
          'goal',
          'daily_target',
          'priority',
          'horizon_days',
          'source_conversation_id',
          'source_user_message_id',
          'adopted_at',
        ],
      );
      if (rows.isEmpty) return null;
      if (rows.length > 1) {
        throw const StudyPlanException(StudyPlanFailure.internalError);
      }
      return _mapRowToActivePlan(rows.single);
    } on StudyPlanException {
      rethrow;
    } on DatabaseRuntimeException {
      throw const StudyPlanException(StudyPlanFailure.temporarilyUnavailable);
    } on DatabaseException {
      throw const StudyPlanException(StudyPlanFailure.temporarilyUnavailable);
    }
  }

  @override
  Future<StudyPlanPersistenceCommitResult> commitAdoption({
    required String planId,
    required String bankName,
    String? goal,
    required int dailyTarget,
    required StudyPlanPriority priority,
    int? horizonDays,
    String? sourceConversationId,
    String? sourceUserMessageId,
    required ConversationScope sourceScope,
    required DateTime adoptedAt,
    String? expectedActivePlanId,
    required bool replacementConfirmed,
  }) async {
    // Validate mutual consistency of replacement parameters
    if (expectedActivePlanId != null && !replacementConfirmed) {
      return const StudyPlanPersistenceCommitFailed();
    }
    if (expectedActivePlanId == null && replacementConfirmed) {
      return const StudyPlanPersistenceCommitFailed();
    }

    final trimmedBankName = bankName.trim();
    if (trimmedBankName.isEmpty) {
      return const StudyPlanPersistenceCommitFailed();
    }

    try {
      final db = await _databaseHelper.database;
      return await db.transaction((txn) async {
        // 1. Revalidate source Conversation and scope structural equality
        if (sourceConversationId != null) {
          final convRows = await txn.query(
            'conversations',
            columns: const <String>[
              'conversation_id',
              'scope_kind',
              'project_id',
            ],
            where: 'conversation_id = ?',
            whereArgs: <Object?>[sourceConversationId],
            limit: 1,
          );
          if (convRows.isEmpty) {
            return const StudyPlanPersistenceCommitStaleScope();
          }
          final conv = convRows.single;
          final scopeKind = conv['scope_kind'] as String?;
          final convProjectId = conv['project_id'] as String?;

          if (sourceScope.kind == ConversationScopeKind.global) {
            if (scopeKind != 'global' || convProjectId != null) {
              return const StudyPlanPersistenceCommitStaleScope();
            }
          } else if (sourceScope.kind == ConversationScopeKind.learningSpace) {
            if (scopeKind != 'learning_space' ||
                convProjectId != sourceScope.projectId) {
              return const StudyPlanPersistenceCommitStaleScope();
            }
            // Project must exist
            final projectRows = await txn.query(
              'projects',
              columns: const <String>['project_id'],
              where: 'project_id = ?',
              whereArgs: <Object?>[sourceScope.projectId],
              limit: 1,
            );
            if (projectRows.isEmpty) {
              return const StudyPlanPersistenceCommitStaleScope();
            }
            // project_banks relation must exist
            final relationRows = await txn.query(
              'project_banks',
              columns: const <String>['bank_name'],
              where: 'project_id = ? AND bank_name = ?',
              whereArgs: <Object?>[sourceScope.projectId, trimmedBankName],
              limit: 1,
            );
            if (relationRows.isEmpty) {
              return const StudyPlanPersistenceCommitStaleScope();
            }
          } else {
            return const StudyPlanPersistenceCommitStaleScope();
          }
        }

        // 2. Revalidate source User Message
        if (sourceUserMessageId != null) {
          final msgRows = await txn.query(
            'conversation_messages',
            columns: const <String>['message_id', 'conversation_id', 'role'],
            where: 'message_id = ?',
            whereArgs: <Object?>[sourceUserMessageId],
            limit: 1,
          );
          if (msgRows.isEmpty) {
            return const StudyPlanPersistenceCommitStaleScope();
          }
          final msg = msgRows.single;
          if (msg['conversation_id'] != sourceConversationId ||
              msg['role'] != 'user') {
            return const StudyPlanPersistenceCommitStaleScope();
          }
        }

        // 3. Revalidate target bank has >= 1 question
        final countRows = await txn.rawQuery(
          'SELECT COUNT(*) AS c FROM questions WHERE bank_name = ?',
          <Object?>[trimmedBankName],
        );
        final questionCount = (countRows.single['c'] as num?)?.toInt() ?? 0;
        if (questionCount < 1) {
          return const StudyPlanPersistenceCommitTargetUnavailable();
        }

        final adoptedAtMs = adoptedAt.millisecondsSinceEpoch;

        // 4. Execute CAS
        if (expectedActivePlanId == null) {
          // No active plan expected: check existing singleton
          final existingRows = await txn.query(
            'study_plans',
            columns: const <String>['plan_id'],
            where: 'singleton_key = 1',
            limit: 1,
          );
          if (existingRows.isNotEmpty) {
            return const StudyPlanPersistenceCommitAlreadyActive();
          }

          try {
            await txn.insert(
              'study_plans',
              <String, Object?>{
                'plan_id': planId,
                'singleton_key': 1,
                'bank_name': trimmedBankName,
                'goal': goal,
                'daily_target': dailyTarget,
                'priority': priority.canonicalCode,
                'horizon_days': horizonDays,
                'source_conversation_id': sourceConversationId,
                'source_user_message_id': sourceUserMessageId,
                'adopted_at': adoptedAtMs,
              },
              conflictAlgorithm: ConflictAlgorithm.fail,
            );
          } on DatabaseException catch (e) {
            if (e.isUniqueConstraintError() ||
                e.toString().toLowerCase().contains('unique')) {
              return const StudyPlanPersistenceCommitAlreadyActive();
            }
            return const StudyPlanPersistenceCommitFailed();
          }
        } else {
          // Replacement expected: atomic UPDATE WHERE plan_id = expected
          final affected = await txn.update(
            'study_plans',
            <String, Object?>{
              'plan_id': planId,
              'bank_name': trimmedBankName,
              'goal': goal,
              'daily_target': dailyTarget,
              'priority': priority.canonicalCode,
              'horizon_days': horizonDays,
              'source_conversation_id': sourceConversationId,
              'source_user_message_id': sourceUserMessageId,
              'adopted_at': adoptedAtMs,
            },
            where: 'singleton_key = 1 AND plan_id = ?',
            whereArgs: <Object?>[expectedActivePlanId],
          );
          if (affected != 1) {
            return const StudyPlanPersistenceCommitStaleActivePlan();
          }
        }

        final activePlan = ActiveStudyPlan(
          planId: planId,
          bankName: trimmedBankName,
          goal: goal,
          dailyTarget: dailyTarget,
          priority: priority,
          horizonDays: horizonDays,
          sourceConversationId: sourceConversationId,
          sourceUserMessageId: sourceUserMessageId,
          adoptedAt:
              DateTime.fromMillisecondsSinceEpoch(adoptedAtMs, isUtc: true),
        );
        return StudyPlanPersistenceCommitSuccess(activePlan);
      });
    } on DatabaseRuntimeException {
      return const StudyPlanPersistenceCommitFailed();
    } on DatabaseException {
      return const StudyPlanPersistenceCommitFailed();
    }
  }

  @override
  Future<StudyPlanPersistenceStopResult> stopActivePlan({
    required String expectedPlanId,
  }) async {
    final trimmedId = expectedPlanId.trim();
    if (trimmedId.isEmpty) {
      return const StudyPlanPersistenceStopStaleActivePlan();
    }
    try {
      final db = await _databaseHelper.database;
      final affected = await db.delete(
        'study_plans',
        where: 'singleton_key = 1 AND plan_id = ?',
        whereArgs: <Object?>[trimmedId],
      );
      if (affected != 1) {
        return const StudyPlanPersistenceStopStaleActivePlan();
      }
      return const StudyPlanPersistenceStopSuccess();
    } on DatabaseRuntimeException {
      return const StudyPlanPersistenceStopFailed();
    } on DatabaseException {
      return const StudyPlanPersistenceStopFailed();
    }
  }

  ActiveStudyPlan _mapRowToActivePlan(Map<String, Object?> row) {
    try {
      final priorityCode = row['priority'] as String?;
      if (priorityCode == null) {
        throw const FormatException('Missing priority code');
      }
      final priority = StudyPlanPriority.fromCanonicalCode(priorityCode);
      final adoptedAtMs = row['adopted_at'] as int?;
      if (adoptedAtMs == null || adoptedAtMs < 0) {
        throw const FormatException('Invalid adopted_at');
      }
      return ActiveStudyPlan(
        planId: row['plan_id']! as String,
        bankName: row['bank_name']! as String,
        goal: row['goal'] as String?,
        dailyTarget: row['daily_target'] as int?,
        priority: priority,
        horizonDays: row['horizon_days'] as int?,
        sourceConversationId: row['source_conversation_id'] as String?,
        sourceUserMessageId: row['source_user_message_id'] as String?,
        adoptedAt:
            DateTime.fromMillisecondsSinceEpoch(adoptedAtMs, isUtc: true),
      );
    } catch (_) {
      throw const StudyPlanException(StudyPlanFailure.internalError);
    }
  }
}
