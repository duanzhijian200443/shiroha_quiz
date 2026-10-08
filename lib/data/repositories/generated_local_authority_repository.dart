import 'package:uuid/uuid.dart';

import '../../application/backup/backup_restore_gate.dart';
import '../../application/generated_question/generated_local_authority.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../domain/generated_question/generated_question_contract.dart';
import 'generated_proposal_reader.dart';

/// Local data ownership in existing app_settings; no credentials or migration.
final class GeneratedLocalAuthorityRepository
    implements GeneratedLocalIdentityPort, GeneratedLocalProposalReadPort {
  GeneratedLocalAuthorityRepository(
      {DatabaseHelper? databaseHelper, String Function()? idFactory})
      : _helper = databaseHelper ?? DatabaseHelper.instance,
        _id = idFactory ?? const Uuid().v4;
  static const ownerSettingKey = 'generated_proposal_local_owner';
  static final _uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
  final DatabaseHelper _helper;
  final String Function() _id;

  String _owner(Object? value) {
    if (value is! String || !_uuid.hasMatch(value)) {
      throw const GeneratedLocalIdentityException(
          GeneratedLocalIdentityFailure.corrupt);
    }
    return value;
  }

  @override
  Future<String> loadOrCreateOwner() =>
      BackupRestoreMutationGate.instance.runMutation(() async {
        try {
          final db = await _helper.database;
          return await db.transaction((txn) async {
            var setting = await txn.query('app_settings',
                columns: ['value'],
                where: 'key=?',
                whereArgs: [ownerSettingKey]);
            if (setting.isEmpty) {
              if ((await txn.query('generated_question_proposals',
                      columns: ['proposal_id'], limit: 1))
                  .isNotEmpty) {
                throw const GeneratedLocalIdentityException(
                    GeneratedLocalIdentityFailure.missingWithProposals);
              }
              final minted = _owner(_id());
              await txn.insert(
                  'app_settings', {'key': ownerSettingKey, 'value': minted},
                  conflictAlgorithm: ConflictAlgorithm.ignore);
              // The durable winner is authoritative, even on concurrent entry.
              setting = await txn.query('app_settings',
                  columns: ['value'],
                  where: 'key=?',
                  whereArgs: [ownerSettingKey]);
            }
            if (setting.length != 1) {
              throw const GeneratedLocalIdentityException(
                  GeneratedLocalIdentityFailure.corrupt);
            }
            final owner = _owner(setting.single['value']);
            if ((await txn.query('generated_question_proposals',
                    columns: ['proposal_id'],
                    where: 'local_owner<>?',
                    whereArgs: [owner],
                    limit: 1))
                .isNotEmpty) {
              throw const GeneratedLocalIdentityException(
                  GeneratedLocalIdentityFailure.ownerMismatch);
            }
            return owner;
          });
        } on GeneratedLocalIdentityException {
          rethrow;
        } catch (_) {
          throw const GeneratedLocalIdentityException(
              GeneratedLocalIdentityFailure.persistenceFailed);
        }
      });

  void _authorize(GeneratedQuestionProposal proposal,
      GeneratedLocalReadAuthority authority) {
    authority.validate();
    if (proposal.localOwner != authority.localOwner) {
      generatedFail(GeneratedFailure.proposalUnavailable);
    }
  }

  Future<T> _query<T>(Future<T> Function(DatabaseExecutor) query) async {
    try {
      final db = await _helper.database;
      return await db.transaction(query);
    } on GeneratedQuestionException {
      rethrow;
    } catch (_) {
      generatedFail(GeneratedFailure.corruptState);
    }
  }

  @override
  Future<GeneratedQuestionProposal> read(
      String proposalId, GeneratedLocalReadAuthority authority) {
    authority.validate();
    generatedToken(proposalId, uuid: true);
    return _query((db) async {
      final proposal = await readGeneratedProposal(db, proposalId);
      _authorize(proposal, authority);
      return proposal;
    });
  }

  @override
  Future<List<GeneratedQuestionProposal>> pending(
      GeneratedLocalReadAuthority authority) {
    authority.validate();
    return _query((db) async {
      final rows = await db.query('generated_question_proposals',
          columns: ['proposal_id'],
          where: "local_owner=? AND lifecycle_status='pending_review'",
          whereArgs: [authority.localOwner],
          orderBy: 'created_at_utc_ms,proposal_id');
      final result = <GeneratedQuestionProposal>[];
      for (final row in rows) {
        final proposal =
            await readGeneratedProposal(db, row['proposal_id'] as String);
        _authorize(proposal, authority);
        result.add(proposal);
      }
      authority.validate();
      return List.unmodifiable(result);
    });
  }
}
