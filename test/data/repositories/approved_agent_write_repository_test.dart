// W0-D1 synthetic acceptance: permission-aware staging admission and the
// dedicated atomic commit adapter on real v15 databases through the frozen
// DatabaseHelper.openPathForTesting seam (r7d-style file seam) plus
// tester-independent async tests. Synthetic sqflite FFI only; no real
// database, OCR, Provider, Replay, network, private PDF, or external fixture
// is touched; all content is constructed inside this file.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/safe_write/agent_write_persistence.dart';
import 'package:shiroha_quiz/application/safe_write/typed_answer_command.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/approved_agent_write_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _mapper = QuestionV2PersistenceMapper();
const _bankName = 'w0_d1_synthetic_bank';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
const _globalConversation = 'conv_global_001';
const _globalMessage = 'msg_global_user_001';
const _learningConversation = 'conv_learning_001';
const _learningMessage = 'msg_learning_user_001';
const _projectId = 'proj_w0_d1_001';

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

QuestionDraftV2 _choiceDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'w0_d1_choice_q',
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _text('Choice stem.'),
    options: <QuestionOption>[
      QuestionOption(optionId: 'opt_a', label: 'A', content: _text('first')),
      QuestionOption(optionId: 'opt_b', label: 'B', content: _text('second')),
      QuestionOption(optionId: 'opt_c', label: 'C', content: _text('third')),
    ],
    answer: answer,
    explanation: _text('Explanation.'),
  );
}

QuestionDraftV2 _contentDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'w0_d1_content_q',
    kind: QuestionKind.shortAnswer,
    questionNumber: 2,
    stem: _text('Content stem.'),
    answer: answer,
    explanation: _text('Explanation.'),
  );
}

final _openHelpers = <_FileDatabaseHelper>[];

class _FileDatabaseHelper extends Fake implements DatabaseHelper {
  _FileDatabaseHelper(this.path) {
    _openHelpers.add(this);
  }

  final String path;
  Database? _database;

  @override
  Future<Database> get database async =>
      _database ??= await DatabaseHelper.instance.openPathForTesting(path);

  @override
  Future<void> close() async {
    final db = _database;
    _database = null;
    if (db != null) await db.close();
  }

  Future<void> closeAndCleanup() async {
    await close();
    final dir = File(path).parent;
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}

Future<void> _insertConversation(
  Database db, {
  required String conversationId,
  required ConversationScope scope,
}) async {
  await db.insert('conversations', <String, Object?>{
    'conversation_id': conversationId,
    'scope_kind': switch (scope.kind) {
      ConversationScopeKind.global => 'global',
      ConversationScopeKind.learningSpace => 'learning_space',
    },
    'project_id': scope.projectId,
    'title': 'Synthetic conversation.',
    'created_at': 1700000000000,
    'updated_at': 1700000000000,
  });
}

Future<void> _insertMessage(
  Database db, {
  required String messageId,
  required String conversationId,
  required String role,
}) async {
  await db.insert('conversation_messages', <String, Object?>{
    'message_id': messageId,
    'conversation_id': conversationId,
    'sequence': 1,
    'role': role,
    'content': 'Synthetic user message.',
    'created_at': 1700000000000,
  });
}

Future<void> _insertProject(Database db) async {
  await db.insert('projects', <String, Object?>{
    'project_id': _projectId,
    'display_name': 'Synthetic project.',
    'created_at': 1700000000000,
  });
}

Future<void> _insertBankRelation(Database db) async {
  await db.insert('project_banks', <String, Object?>{
    'project_id': _projectId,
    'bank_name': _bankName,
  });
}

Future<void> _insertTypedRow(
  Database db,
  QuestionDraftV2 draft, {
  required String storageId,
}) async {
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: _bankName,
    createdAt: 1700000001,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
  await db.insert('review_states', <String, Object?>{
    'question_id': storageId,
    'state': 3,
    'difficulty': 2.5,
    'stability': 9.5,
    'reps': 7,
    'lapses': 4,
    'last_review_time': 1700001001,
    'next_review_time': 1700002001,
    'last_lapse_time': 1700000501,
  });
}

Future<void> _insertLegacyRow(Database db, {required String id}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': 3,
    'content': 'Legacy stem text.',
    'options': '[]',
    'standard_answer': 'Legacy answer|||Legacy explanation.',
    'explanation': 'Legacy explanation.',
    'raw_explanation': 'Legacy raw explanation.',
    'created_at': 1700000000,
    'bank_name': _bankName,
  });
}

Future<TypedPersistedQuestion> _reloadTyped(
  Database db,
  String storageId,
) async {
  final rows = await db.rawQuery(
    '''
    SELECT q.*,
           p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
           p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
    FROM questions q
    LEFT JOIN question_v2_payloads p ON q.id = p.question_id
    WHERE q.id = ?
    ''',
    <Object?>[storageId],
  );
  expect(rows, hasLength(1));
  final decoded = _mapper.decodeJoinedRow(rows.single);
  expect(decoded, isA<TypedPersistedQuestion>());
  return decoded as TypedPersistedQuestion;
}

Future<String> _standardAnswer(Database db, String storageId) async {
  final rows = await db.query(
    'questions',
    columns: <String>['standard_answer'],
    where: 'id = ?',
    whereArgs: <Object?>[storageId],
  );
  return rows.single['standard_answer']! as String;
}

Future<String> _payloadJson(Database db, String storageId) async {
  final rows = await db.query(
    'question_v2_payloads',
    columns: <String>['payload_json'],
    where: 'question_id = ?',
    whereArgs: <Object?>[storageId],
  );
  return rows.single['payload_json']! as String;
}

Future<List<Map<String, Object?>>> _reviewStates(
  Database db,
  String storageId,
) async {
  return db.query(
    'review_states',
    where: 'question_id = ?',
    whereArgs: <Object?>[storageId],
  );
}

AgentWriteAdmissionRequest _globalAdmissionRequest(String storageId) {
  return AgentWriteAdmissionRequest(
    sourceConversationId: _globalConversation,
    sourceMessageId: _globalMessage,
    scope: ConversationScope.global(),
    targetStorageId: storageId,
  );
}

AgentWriteAdmissionRequest _learningAdmissionRequest(String storageId) {
  return AgentWriteAdmissionRequest(
    sourceConversationId: _learningConversation,
    sourceMessageId: _learningMessage,
    scope: ConversationScope.learningSpace(_projectId),
    targetStorageId: storageId,
  );
}

AgentWriteCommitRequest _globalCommitRequest({
  required String storageId,
  required QuestionDraftV2 expectedDraft,
  required QuestionAnswer proposedAnswer,
}) {
  return AgentWriteCommitRequest(
    sourceConversationId: _globalConversation,
    sourceMessageId: _globalMessage,
    scope: ConversationScope.global(),
    targetStorageId: storageId,
    expectedBankName: _bankName,
    expectedDraft: expectedDraft,
    proposedAnswer: proposedAnswer,
  );
}

AgentWriteCommitRequest _learningCommitRequest({
  required String storageId,
  required QuestionDraftV2 expectedDraft,
  required QuestionAnswer proposedAnswer,
}) {
  return AgentWriteCommitRequest(
    sourceConversationId: _learningConversation,
    sourceMessageId: _learningMessage,
    scope: ConversationScope.learningSpace(_projectId),
    targetStorageId: storageId,
    expectedBankName: _bankName,
    expectedDraft: expectedDraft,
    proposedAnswer: proposedAnswer,
  );
}

AgentWriteReconciliationRequest _globalReconciliationRequest({
  required String storageId,
  required QuestionDraftV2 expectedDraft,
  required QuestionAnswer proposedAnswer,
}) {
  return AgentWriteReconciliationRequest(
    sourceConversationId: _globalConversation,
    sourceMessageId: _globalMessage,
    scope: ConversationScope.global(),
    targetStorageId: storageId,
    expectedBankName: _bankName,
    expectedDraft: expectedDraft,
    proposedAnswer: proposedAnswer,
  );
}

AgentWriteReconciliationRequest _learningReconciliationRequest({
  required String storageId,
  required QuestionDraftV2 expectedDraft,
  required QuestionAnswer proposedAnswer,
}) {
  return AgentWriteReconciliationRequest(
    sourceConversationId: _learningConversation,
    sourceMessageId: _learningMessage,
    scope: ConversationScope.learningSpace(_projectId),
    targetStorageId: storageId,
    expectedBankName: _bankName,
    expectedDraft: expectedDraft,
    proposedAnswer: proposedAnswer,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  tearDown(() async {
    for (final helper in _openHelpers) {
      await helper.closeAndCleanup();
    }
    _openHelpers.clear();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  group('admission', () {
    test(
      'Global scope grants an eligible typed target with its snapshot',
      () async {
        final helper = _FileDatabaseHelper(
          p.join(
            (await Directory.systemTemp.createTemp('w0_d1_adm_')).path,
            'a.db',
          ),
        );
        addTearDown(helper.close);
        final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
        final db = await helper.database;
        await _insertConversation(
          db,
          conversationId: _globalConversation,
          scope: ConversationScope.global(),
        );
        await _insertMessage(
          db,
          messageId: _globalMessage,
          conversationId: _globalConversation,
          role: 'user',
        );
        await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);

        final result = await repository.admitStagingTarget(
          _globalAdmissionRequest(_storageId),
        );

        expect(result, isA<AgentWriteAdmissionGranted>());
        final granted = result as AgentWriteAdmissionGranted;
        expect(granted.target.storageId, _storageId);
        expect(granted.target.bankName, _bankName);
        expect(granted.target.draft, _choiceDraft());
      },
    );

    test('nonexistent target is denied without identity or content', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_adm_')).path,
          'b.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );

      final result = await repository.admitStagingTarget(
        _globalAdmissionRequest('missing_target'),
      );

      expect(result, isA<AgentWriteAdmissionDenied>());
    });

    test('Learning Space grants only with project and bank relation', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_adm_')).path,
          'c.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertProject(db);
      await _insertConversation(
        db,
        conversationId: _learningConversation,
        scope: ConversationScope.learningSpace(_projectId),
      );
      await _insertMessage(
        db,
        messageId: _learningMessage,
        conversationId: _learningConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);
      await _insertBankRelation(db);

      final result = await repository.admitStagingTarget(
        _learningAdmissionRequest(_storageId),
      );

      expect(result, isA<AgentWriteAdmissionGranted>());
    });

    test(
        'unauthorized (missing relation) and nonexistent share the identical '
        'denied shape', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_adm_')).path,
          'd.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertProject(db);
      await _insertConversation(
        db,
        conversationId: _learningConversation,
        scope: ConversationScope.learningSpace(_projectId),
      );
      await _insertMessage(
        db,
        messageId: _learningMessage,
        conversationId: _learningConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);
      // No project_banks relation: the target exists but is unauthorized.

      final unauthorized = await repository.admitStagingTarget(
        _learningAdmissionRequest(_storageId),
      );
      final nonexistent = await repository.admitStagingTarget(
        _learningAdmissionRequest('missing_target'),
      );

      expect(unauthorized, isA<AgentWriteAdmissionDenied>());
      expect(nonexistent, isA<AgentWriteAdmissionDenied>());
      expect(identical(unauthorized, nonexistent), isTrue);
    });

    test(
        'Learning Space conversation without a live Project (project_id null) '
        'is denied', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_adm_')).path,
          'e.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _learningConversation,
        scope: ConversationScope.unavailableLearningSpace(),
      );
      await _insertMessage(
        db,
        messageId: _learningMessage,
        conversationId: _learningConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);

      final result = await repository.admitStagingTarget(
        _learningAdmissionRequest(_storageId),
      );

      expect(result, isA<AgentWriteAdmissionDenied>());
    });

    test(
      'assistant message, foreign message and scope mismatch are denied',
      () async {
        final helper = _FileDatabaseHelper(
          p.join(
            (await Directory.systemTemp.createTemp('w0_d1_adm_')).path,
            'f.db',
          ),
        );
        addTearDown(helper.close);
        final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
        final db = await helper.database;
        await _insertConversation(
          db,
          conversationId: _globalConversation,
          scope: ConversationScope.global(),
        );
        await _insertMessage(
          db,
          messageId: _globalMessage,
          conversationId: _globalConversation,
          role: 'assistant',
        );
        await _insertConversation(
          db,
          conversationId: 'conv_foreign_001',
          scope: ConversationScope.global(),
        );
        await _insertMessage(
          db,
          messageId: 'msg_foreign_user_001',
          conversationId: 'conv_foreign_001',
          role: 'user',
        );
        await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);

        final assistantMessage = await repository.admitStagingTarget(
          _globalAdmissionRequest(_storageId),
        );
        final foreignMessage = await repository.admitStagingTarget(
          AgentWriteAdmissionRequest(
            sourceConversationId: _globalConversation,
            sourceMessageId: 'msg_foreign_user_001',
            scope: ConversationScope.global(),
            targetStorageId: _storageId,
          ),
        );
        final scopeMismatch = await repository.admitStagingTarget(
          AgentWriteAdmissionRequest(
            sourceConversationId: _globalConversation,
            sourceMessageId: _globalMessage,
            scope: ConversationScope.learningSpace(_projectId),
            targetStorageId: _storageId,
          ),
        );

        expect(assistantMessage, isA<AgentWriteAdmissionDenied>());
        expect(foreignMessage, isA<AgentWriteAdmissionDenied>());
        expect(scopeMismatch, isA<AgentWriteAdmissionDenied>());
      },
    );

    test('unavailable Learning Space scope is denied', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_adm_')).path,
          'g.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      await _insertConversation(
        await helper.database,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );

      final result = await repository.admitStagingTarget(
        AgentWriteAdmissionRequest(
          sourceConversationId: _globalConversation,
          sourceMessageId: _globalMessage,
          scope: ConversationScope.unavailableLearningSpace(),
          targetStorageId: _storageId,
        ),
      );

      expect(result, isA<AgentWriteAdmissionDenied>());
    });

    test('corrupt typed sidecar is a distinct unavailable result', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_adm_')).path,
          'h.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await db.insert('questions', <String, Object?>{
        'id': _storageId,
        'type': 3,
        'content': 'Corrupt synthetic parent.',
        'options': '[]',
        'standard_answer': 'x|||',
        'created_at': 1,
        'bank_name': _bankName,
      });
      await db.insert('question_v2_payloads', <String, Object?>{
        'question_id': _storageId,
        'payload_schema_version': 2,
        'payload_json': '{corrupt',
      });

      final result = await repository.admitStagingTarget(
        _globalAdmissionRequest(_storageId),
      );

      expect(result, isA<AgentWriteAdmissionUnavailable>());
    });

    test('legacy target is denied like a nonexistent one', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_adm_')).path,
          'i.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertLegacyRow(db, id: _storageId);

      final result = await repository.admitStagingTarget(
        _globalAdmissionRequest(_storageId),
      );

      expect(result, isA<AgentWriteAdmissionDenied>());
    });

    test(
      'an already-answered target still admits (fill-only is proposal layer)',
      () async {
        final helper = _FileDatabaseHelper(
          p.join(
            (await Directory.systemTemp.createTemp('w0_d1_adm_')).path,
            'j.db',
          ),
        );
        addTearDown(helper.close);
        final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
        final db = await helper.database;
        await _insertConversation(
          db,
          conversationId: _globalConversation,
          scope: ConversationScope.global(),
        );
        await _insertMessage(
          db,
          messageId: _globalMessage,
          conversationId: _globalConversation,
          role: 'user',
        );
        await _insertTypedRow(
          db,
          _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
          storageId: _storageId,
        );

        final result = await repository.admitStagingTarget(
          _globalAdmissionRequest(_storageId),
        );

        expect(result, isA<AgentWriteAdmissionGranted>());
      },
    );
  });

  group('commit', () {
    test(
      'Global success writes sidecar and V1 and keeps review state',
      () async {
        final helper = _FileDatabaseHelper(
          p.join(
            (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
            'a.db',
          ),
        );
        addTearDown(helper.close);
        final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
        final db = await helper.database;
        await _insertConversation(
          db,
          conversationId: _globalConversation,
          scope: ConversationScope.global(),
        );
        await _insertMessage(
          db,
          messageId: _globalMessage,
          conversationId: _globalConversation,
          role: 'user',
        );
        await _insertTypedRow(db, _contentDraft(), storageId: _storageId);
        final expectedDraft = (await _reloadTyped(db, _storageId)).draft;
        final reviewBefore = await _reviewStates(db, _storageId);
        final proposed = ContentAnswer(content: _text('manual answer'));

        await repository.commitApproved(
          _globalCommitRequest(
            storageId: _storageId,
            expectedDraft: expectedDraft,
            proposedAnswer: proposed,
          ),
        );

        final typed = await _reloadTyped(db, _storageId);
        expect(typed.draft.answer, proposed);
        expect(
          await _standardAnswer(db, _storageId),
          'manual answer|||Explanation.',
        );
        final payload = jsonDecode(await _payloadJson(db, _storageId))
            as Map<String, dynamic>;
        expect(
          (payload['answer'] as Map<String, dynamic>)['content']['nodes'][0]
              ['text'],
          'manual answer',
        );
        expect(await _reviewStates(db, _storageId), reviewBefore);
      },
    );

    test('Learning Space success requires the current bank relation', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
          'b.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertProject(db);
      await _insertConversation(
        db,
        conversationId: _learningConversation,
        scope: ConversationScope.learningSpace(_projectId),
      );
      await _insertMessage(
        db,
        messageId: _learningMessage,
        conversationId: _learningConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);
      await _insertBankRelation(db);
      final expectedDraft = (await _reloadTyped(db, _storageId)).draft;
      final reviewBefore = await _reviewStates(db, _storageId);

      await repository.commitApproved(
        _learningCommitRequest(
          storageId: _storageId,
          expectedDraft: expectedDraft,
          proposedAnswer: ChoiceAnswer(optionIds: <String>['opt_b']),
        ),
      );

      final typed = await _reloadTyped(db, _storageId);
      expect(typed.draft.answer, ChoiceAnswer(optionIds: <String>['opt_b']));
      expect(await _reviewStates(db, _storageId), reviewBefore);
    });

    test('stale expected draft fails with zero writes', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
          'c.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
      final staleDraft = _choiceDraft();
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      await expectLater(
        repository.commitApproved(
          _globalCommitRequest(
            storageId: _storageId,
            expectedDraft: staleDraft,
            proposedAnswer: ContentAnswer(content: _text('x')),
          ),
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.stale,
          ),
        ),
      );
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('fill-only recheck refuses an already-answered target', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
          'd.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertTypedRow(
        db,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
      final expectedDraft = (await _reloadTyped(db, _storageId)).draft;
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      await expectLater(
        repository.commitApproved(
          _globalCommitRequest(
            storageId: _storageId,
            expectedDraft: expectedDraft,
            proposedAnswer: ContentAnswer(content: _text('x')),
          ),
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.stale,
          ),
        ),
      );
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('detached bank relation fails stale with zero writes', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
          'e.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertProject(db);
      await _insertConversation(
        db,
        conversationId: _learningConversation,
        scope: ConversationScope.learningSpace(_projectId),
      );
      await _insertMessage(
        db,
        messageId: _learningMessage,
        conversationId: _learningConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);
      // Relation was present at staging but is detached before COMMIT.
      final expectedDraft = (await _reloadTyped(db, _storageId)).draft;
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      await expectLater(
        repository.commitApproved(
          _learningCommitRequest(
            storageId: _storageId,
            expectedDraft: expectedDraft,
            proposedAnswer: ContentAnswer(content: _text('x')),
          ),
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.stale,
          ),
        ),
      );
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('deleted source message fails notFound with zero writes', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
          'f.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);
      final expectedDraft = (await _reloadTyped(db, _storageId)).draft;
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      await expectLater(
        repository.commitApproved(
          _globalCommitRequest(
            storageId: _storageId,
            expectedDraft: expectedDraft,
            proposedAnswer: ContentAnswer(content: _text('x')),
          ),
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.notFound,
          ),
        ),
      );
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('legacy target fails notTyped with zero writes', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
          'g.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertLegacyRow(db, id: _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      await expectLater(
        repository.commitApproved(
          _globalCommitRequest(
            storageId: _storageId,
            expectedDraft: _choiceDraft(),
            proposedAnswer: ContentAnswer(content: _text('x')),
          ),
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.notTyped,
          ),
        ),
      );
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('questions UPDATE failure rolls the transaction back', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
          'h.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);
      await db.execute('''
        CREATE TRIGGER w0_d1_block_question
        BEFORE UPDATE OF standard_answer ON questions
        BEGIN
          SELECT RAISE(ABORT, 'w0_d1_synthetic_question_failure');
        END;
      ''');
      final expectedDraft = (await _reloadTyped(db, _storageId)).draft;
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      await expectLater(
        repository.commitApproved(
          _globalCommitRequest(
            storageId: _storageId,
            expectedDraft: expectedDraft,
            proposedAnswer: ChoiceAnswer(optionIds: <String>['opt_a']),
          ),
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.transactionFailed,
          ),
        ),
      );
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('whitespace-only proposed content fails invalidAnswer', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
          'i.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _contentDraft(), storageId: _storageId);
      final expectedDraft = (await _reloadTyped(db, _storageId)).draft;
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      await expectLater(
        repository.commitApproved(
          _globalCommitRequest(
            storageId: _storageId,
            expectedDraft: expectedDraft,
            proposedAnswer: ContentAnswer(content: _text('   ')),
          ),
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.invalidAnswer,
          ),
        ),
      );
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('raw fallback proposed content fails invalidAnswer', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
          'j.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _contentDraft(), storageId: _storageId);
      final expectedDraft = (await _reloadTyped(db, _storageId)).draft;
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      await expectLater(
        repository.commitApproved(
          _globalCommitRequest(
            storageId: _storageId,
            expectedDraft: expectedDraft,
            proposedAnswer: ContentAnswer(
              content: RichContent(
                nodes: <ContentNode>[
                  RawFallbackNode(<Object?, Object?>{
                    'type': 'future_diagram',
                    'payload': <Object?, Object?>{'shape': 'synthetic'},
                  }),
                ],
              ),
            ),
          ),
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.invalidAnswer,
          ),
        ),
      );
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test(
        'kind mismatch singleChoice + ContentAnswer fails invalidAnswer with '
        'zero writes', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
          'k2.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);
      final expectedDraft = (await _reloadTyped(db, _storageId)).draft;
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);
      final reviewBefore = await _reviewStates(db, _storageId);

      await expectLater(
        repository.commitApproved(
          _globalCommitRequest(
            storageId: _storageId,
            expectedDraft: expectedDraft,
            proposedAnswer: ContentAnswer(content: _text('x')),
          ),
        ),
        throwsA(
          isA<TypedAnswerMutationException>().having(
            (error) => error.failure,
            'failure',
            TypedAnswerMutationFailure.invalidAnswer,
          ),
        ),
      );
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
      expect(await _reviewStates(db, _storageId), reviewBefore);
    });

    test(
        'unknown and duplicate choice identities fail invalidAnswer with '
        'zero writes', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
          'k3.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _choiceDraft(), storageId: _storageId);
      final expectedDraft = (await _reloadTyped(db, _storageId)).draft;
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);
      final reviewBefore = await _reviewStates(db, _storageId);

      for (final proposed in <QuestionAnswer>[
        ChoiceAnswer(optionIds: <String>['ghost_opt']),
        ChoiceAnswer(optionIds: <String>['opt_a', 'opt_a']),
      ]) {
        await expectLater(
          repository.commitApproved(
            _globalCommitRequest(
              storageId: _storageId,
              expectedDraft: expectedDraft,
              proposedAnswer: proposed,
            ),
          ),
          throwsA(
            isA<TypedAnswerMutationException>().having(
              (error) => error.failure,
              'failure',
              TypedAnswerMutationFailure.invalidAnswer,
            ),
          ),
        );
        expect(await _payloadJson(db, _storageId), payloadBefore);
        expect(await _standardAnswer(db, _storageId), standardBefore);
        expect(await _reviewStates(db, _storageId), reviewBefore);
      }
    });

    test(
      'whitespace-only math content fails invalidAnswer with zero writes',
      () async {
        final helper = _FileDatabaseHelper(
          p.join(
            (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
            'k4.db',
          ),
        );
        addTearDown(helper.close);
        final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
        final db = await helper.database;
        await _insertConversation(
          db,
          conversationId: _globalConversation,
          scope: ConversationScope.global(),
        );
        await _insertMessage(
          db,
          messageId: _globalMessage,
          conversationId: _globalConversation,
          role: 'user',
        );
        await _insertTypedRow(db, _contentDraft(), storageId: _storageId);
        final expectedDraft = (await _reloadTyped(db, _storageId)).draft;
        final payloadBefore = await _payloadJson(db, _storageId);
        final standardBefore = await _standardAnswer(db, _storageId);
        final reviewBefore = await _reviewStates(db, _storageId);

        await expectLater(
          repository.commitApproved(
            _globalCommitRequest(
              storageId: _storageId,
              expectedDraft: expectedDraft,
              proposedAnswer: ContentAnswer(
                content: RichContent(
                  nodes: <ContentNode>[
                    InlineMathNode('   '),
                    BlockMathNode(' \t '),
                  ],
                ),
              ),
            ),
          ),
          throwsA(
            isA<TypedAnswerMutationException>().having(
              (error) => error.failure,
              'failure',
              TypedAnswerMutationFailure.invalidAnswer,
            ),
          ),
        );
        expect(await _payloadJson(db, _storageId), payloadBefore);
        expect(await _standardAnswer(db, _storageId), standardBefore);
        expect(await _reviewStates(db, _storageId), reviewBefore);
      },
    );

    test(
      'corrupt target sidecar fails corruptPayload with zero writes',
      () async {
        final helper = _FileDatabaseHelper(
          p.join(
            (await Directory.systemTemp.createTemp('w0_d1_cmt_')).path,
            'k.db',
          ),
        );
        addTearDown(helper.close);
        final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
        final db = await helper.database;
        await _insertConversation(
          db,
          conversationId: _globalConversation,
          scope: ConversationScope.global(),
        );
        await _insertMessage(
          db,
          messageId: _globalMessage,
          conversationId: _globalConversation,
          role: 'user',
        );
        await db.insert('questions', <String, Object?>{
          'id': _storageId,
          'type': 3,
          'content': 'Corrupt synthetic parent.',
          'options': '[]',
          'standard_answer': 'x|||',
          'created_at': 1,
          'bank_name': _bankName,
        });
        await db.insert('question_v2_payloads', <String, Object?>{
          'question_id': _storageId,
          'payload_schema_version': 2,
          'payload_json': '{corrupt',
        });
        final standardBefore = await _standardAnswer(db, _storageId);

        await expectLater(
          repository.commitApproved(
            _globalCommitRequest(
              storageId: _storageId,
              expectedDraft: _choiceDraft(),
              proposedAnswer: ContentAnswer(content: _text('x')),
            ),
          ),
          throwsA(
            isA<TypedAnswerMutationException>().having(
              (error) => error.failure,
              'failure',
              TypedAnswerMutationFailure.corruptPayload,
            ),
          ),
        );
        expect(await _standardAnswer(db, _storageId), standardBefore);
      },
    );
  });

  group('ambiguous commit reconciliation', () {
    test('exact post-image reports committed with zero writes', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_rec_')).path,
          'a.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertTypedRow(
        db,
        _contentDraft(answer: ContentAnswer(content: _text('x'))),
        storageId: _storageId,
      );
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      final result = await repository.reconcileAfterAmbiguousCommit(
        _globalReconciliationRequest(
          storageId: _storageId,
          expectedDraft: _contentDraft(),
          proposedAnswer: ContentAnswer(content: _text('x')),
        ),
      );

      expect(result, isA<AgentWriteReconciliationCommitted>());
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('exact baseline reports baseline with zero writes', () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_rec_')).path,
          'b.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _contentDraft(), storageId: _storageId);
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      final result = await repository.reconcileAfterAmbiguousCommit(
        _globalReconciliationRequest(
          storageId: _storageId,
          expectedDraft: _contentDraft(),
          proposedAnswer: ContentAnswer(content: _text('x')),
        ),
      );

      expect(result, isA<AgentWriteReconciliationBaseline>());
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('a different confirmed draft reports conflicted with zero writes',
        () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_rec_')).path,
          'c.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertConversation(
        db,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        db,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      // A confirmed draft that is neither the baseline nor the post-image
      // (different stem and different answer).
      final otherDraft = QuestionDraftV2(
        questionId: 'w0_d1_other_q',
        kind: QuestionKind.shortAnswer,
        questionNumber: 2,
        stem: _text('Other stem.'),
        answer: ContentAnswer(content: _text('other')),
        explanation: _text('Explanation.'),
      );
      await _insertTypedRow(db, otherDraft, storageId: _storageId);
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      final result = await repository.reconcileAfterAmbiguousCommit(
        _globalReconciliationRequest(
          storageId: _storageId,
          expectedDraft: _contentDraft(),
          proposedAnswer: ContentAnswer(content: _text('x')),
        ),
      );

      expect(result, isA<AgentWriteReconciliationConflicted>());
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('denied authority reports unavailable without leaking content',
        () async {
      final helper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_rec_')).path,
          'd.db',
        ),
      );
      addTearDown(helper.close);
      final repository = ApprovedAgentWriteRepository(databaseHelper: helper);
      final db = await helper.database;
      await _insertProject(db);
      await _insertConversation(
        db,
        conversationId: _learningConversation,
        scope: ConversationScope.learningSpace(_projectId),
      );
      await _insertMessage(
        db,
        messageId: _learningMessage,
        conversationId: _learningConversation,
        role: 'user',
      );
      await _insertTypedRow(db, _contentDraft(), storageId: _storageId);
      // No project_banks relation: the target exists but is unauthorized.
      final payloadBefore = await _payloadJson(db, _storageId);
      final standardBefore = await _standardAnswer(db, _storageId);

      final result = await repository.reconcileAfterAmbiguousCommit(
        _learningReconciliationRequest(
          storageId: _storageId,
          expectedDraft: _contentDraft(),
          proposedAnswer: ContentAnswer(content: _text('x')),
        ),
      );

      expect(result, isA<AgentWriteReconciliationUnavailable>());
      expect(await _payloadJson(db, _storageId), payloadBefore);
      expect(await _standardAnswer(db, _storageId), standardBefore);
    });

    test('corrupt and unreadable targets report unavailable with zero writes',
        () async {
      final corruptHelper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_rec_')).path,
          'e.db',
        ),
      );
      addTearDown(corruptHelper.close);
      final corruptRepository =
          ApprovedAgentWriteRepository(databaseHelper: corruptHelper);
      final corruptDb = await corruptHelper.database;
      await _insertConversation(
        corruptDb,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        corruptDb,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await corruptDb.insert('questions', <String, Object?>{
        'id': _storageId,
        'type': 3,
        'content': 'Corrupt synthetic parent.',
        'options': '[]',
        'standard_answer': 'x|||',
        'created_at': 1,
        'bank_name': _bankName,
      });
      await corruptDb.insert('question_v2_payloads', <String, Object?>{
        'question_id': _storageId,
        'payload_schema_version': 2,
        'payload_json': '{corrupt',
      });

      final corrupt = await corruptRepository.reconcileAfterAmbiguousCommit(
        _globalReconciliationRequest(
          storageId: _storageId,
          expectedDraft: _contentDraft(),
          proposedAnswer: ContentAnswer(content: _text('x')),
        ),
      );
      expect(corrupt, isA<AgentWriteReconciliationUnavailable>());

      final unreadableHelper = _FileDatabaseHelper(
        p.join(
          (await Directory.systemTemp.createTemp('w0_d1_rec_')).path,
          'f.db',
        ),
      );
      addTearDown(unreadableHelper.close);
      final unreadableRepository =
          ApprovedAgentWriteRepository(databaseHelper: unreadableHelper);
      final unreadableDb = await unreadableHelper.database;
      await _insertConversation(
        unreadableDb,
        conversationId: _globalConversation,
        scope: ConversationScope.global(),
      );
      await _insertMessage(
        unreadableDb,
        messageId: _globalMessage,
        conversationId: _globalConversation,
        role: 'user',
      );
      await _insertTypedRow(
        unreadableDb,
        _contentDraft(),
        storageId: _storageId,
      );
      // A synthetic read failure: the target table disappears mid-read.
      await unreadableDb.execute('DROP TABLE questions');

      final unreadable =
          await unreadableRepository.reconcileAfterAmbiguousCommit(
        _globalReconciliationRequest(
          storageId: _storageId,
          expectedDraft: _contentDraft(),
          proposedAnswer: ContentAnswer(content: _text('x')),
        ),
      );
      expect(unreadable, isA<AgentWriteReconciliationUnavailable>());
    });
  });
}
