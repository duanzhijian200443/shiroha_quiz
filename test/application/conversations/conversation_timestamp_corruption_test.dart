import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/application/conversations/conversation_service.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/conversation_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(DatabaseHelper.resetRuntimeProfileForTesting);
  tearDown(DatabaseHelper.resetRuntimeProfileForTesting);

  test('out-of-range stored timestamps map to typed dataCorrupt', () async {
    final db = await DatabaseHelper.instance.database;
    await db.insert('conversations', <String, Object?>{
      'conversation_id': 'conversation-corrupt-time',
      'scope_kind': 'global',
      'project_id': null,
      'title': 'Corrupt time',
      'created_at': 9223372036854775807,
      'updated_at': 9223372036854775807,
    });

    final service = ConversationService(
      repository: SqliteConversationRepository(),
      conversationIdFactory: () => 'unused-conversation-id',
      messageIdFactory: () => 'unused-message-id',
    );

    await expectLater(
      service.loadConversation(conversationId: 'conversation-corrupt-time'),
      throwsA(
        isA<ConversationException>().having(
          (error) => error.failure,
          'failure',
          ConversationFailure.dataCorrupt,
        ),
      ),
    );
  });
}
