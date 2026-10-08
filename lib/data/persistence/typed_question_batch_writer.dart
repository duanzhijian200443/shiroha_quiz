import '../../core/database/sqflite_runtime.dart';
import '../repositories/content_asset_reclamation_observation_repository.dart';
import 'question_v2_persistence_mapper.dart';

/// Transaction-local primitive only. The caller owns approval, target decisions,
/// training-binding reconciliation and the enclosing transaction/terminal CAS.
final class TypedQuestionBatchWriter {
  const TypedQuestionBatchWriter();
  Future<void> write(
    DatabaseExecutor txn, {
    required String bankName,
    required String? resolvedFolderName,
    required List<FrozenQuestionV2Write> frozenWrites,
    required Set<ContentAssetIdentity> assetIdentities,
  }) async {
    await ContentAssetReclamationObservationRepository.resetInTransaction(
        txn, assetIdentities);
    for (final frozenWrite in frozenWrites) {
      await txn.insert('questions', frozenWrite.questionRow);
      await txn.insert('question_v2_payloads', frozenWrite.payloadRow);
      await txn.insert('review_states',
          initialReviewState(frozenWrite.questionRow['id']! as String),
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (resolvedFolderName != null) {
      await txn.insert(
          'bank_folders',
          <String, Object?>{
            'bank_name': bankName,
            'folder_name': resolvedFolderName
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static Map<String, dynamic> initialReviewState(String questionId) => {
        'question_id': questionId,
        'state': 0,
        'difficulty': 5.0,
        'stability': 0.0,
        'last_review_time': 0,
        'next_review_time': 0,
        'reps': 0,
        'lapses': 0,
        'last_lapse_time': 0,
      };
}
