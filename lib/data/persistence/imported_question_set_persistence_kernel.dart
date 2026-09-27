import '../../application/answer_completion/document_question_set_seed.dart';
import '../../core/database/sqflite_runtime.dart';

/// Writes only the relation on QuestionRepository's caller-owned transaction.
final class ImportedQuestionSetPersistenceKernel {
  const ImportedQuestionSetPersistenceKernel();

  Future<void> write(
    Transaction transaction, {
    required String setId,
    required String bankName,
    required DocumentQuestionSetSeed seed,
    required int createdAt,
    required List<String> storageIds,
  }) async {
    if (storageIds.isEmpty) {
      throw ArgumentError('A captured document must contain questions.');
    }
    await transaction.insert('imported_question_sets', <String, Object?>{
      'set_id': setId,
      'bank_name': bankName,
      'display_name': seed.displayName,
      'created_at': createdAt,
      'source_file_id': seed.sourceFileId,
    });
    for (var position = 0; position < storageIds.length; position++) {
      await transaction.insert('imported_question_set_items', <String, Object?>{
        'set_id': setId,
        'question_storage_id': storageIds[position],
        'position': position,
      });
    }
  }
}
