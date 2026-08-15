import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/conversation_repository.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/data/repositories/project_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

LibraryFile _file(String id, {int hour = 1}) => LibraryFile(
      fileId: id,
      displayName: '$id.pdf',
      mimeType: 'application/pdf',
      sizeBytes: hour,
      sha256: _sha,
      storageKey: 'library/$id',
      createdAt: DateTime.utc(2026, 8, 10, hour),
    );

Conversation _conversation(
  String id, {
  ConversationScope? scope,
  DateTime? time,
}) {
  final resolved = time ?? DateTime.utc(2026, 8, 10, 12);
  return Conversation(
    conversationId: id,
    scope: scope ?? ConversationScope.global(),
    title: 'Conversation $id',
    createdAt: resolved,
    updatedAt: resolved,
  );
}

ConversationMessage _message(
  String id,
  String conversationId, {
  int sequence = 1,
  String content = 'first question',
  DateTime? time,
}) {
  return ConversationMessage(
    messageId: id,
    conversationId: conversationId,
    sequence: sequence,
    role: ConversationMessageRole.user,
    content: content,
    createdAt: time ?? DateTime.utc(2026, 8, 10, 12),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(DatabaseHelper.resetRuntimeProfileForTesting);
  tearDown(DatabaseHelper.resetRuntimeProfileForTesting);

  test('creates first message and File relations atomically', () async {
    final files = LibraryFileRepository();
    await files.save(_file('file-a'));
    await files.save(_file('file-b', hour: 2));
    final repository = SqliteConversationRepository();
    final conversation = _conversation('conversation-a');
    final first = _message('message-a', conversation.conversationId);

    final created = await repository.createWithFirstMessage(
      conversation: conversation,
      firstMessage: first,
      fileIds: const <String>['file-b', 'file-a'],
      attachedAt: conversation.createdAt,
    );

    expect(created.messages, <ConversationMessage>[first]);
    expect(
        created.files.map((file) => file.fileId), <String>['file-b', 'file-a']);
    final loaded = await repository.loadConversation(
      conversationId: conversation.conversationId,
      limit: 100,
    );
    expect(loaded.messages, <ConversationMessage>[first]);
    expect(
        loaded.files.map((file) => file.fileId), <String>['file-a', 'file-b']);
  });

  test('missing Project or File rolls back the complete first transaction',
      () async {
    final repository = SqliteConversationRepository();
    final missingProject = _conversation(
      'conversation-project-missing',
      scope: ConversationScope.learningSpace('project-missing'),
    );
    await expectLater(
      repository.createWithFirstMessage(
        conversation: missingProject,
        firstMessage:
            _message('message-project-missing', missingProject.conversationId),
        fileIds: const <String>[],
        attachedAt: missingProject.createdAt,
      ),
      throwsA(
        isA<ConversationException>().having(
          (error) => error.failure,
          'failure',
          ConversationFailure.projectNotFound,
        ),
      ),
    );

    final global = _conversation('conversation-file-missing');
    await expectLater(
      repository.createWithFirstMessage(
        conversation: global,
        firstMessage: _message('message-file-missing', global.conversationId),
        fileIds: const <String>['file-missing'],
        attachedAt: global.createdAt,
      ),
      throwsA(
        isA<ConversationException>().having(
          (error) => error.failure,
          'failure',
          ConversationFailure.fileNotFound,
        ),
      ),
    );
    final db = await DatabaseHelper.instance.database;
    expect(await db.query('conversations'), isEmpty);
    expect(await db.query('conversation_messages'), isEmpty);
    expect(await db.query('conversation_files'), isEmpty);
  });

  test('append allocates stable sequence and monotonic recent ordering',
      () async {
    final repository = SqliteConversationRepository();
    final firstTime = DateTime.utc(2026, 8, 10, 12);
    final firstConversation = _conversation('conversation-a', time: firstTime);
    final secondConversation = _conversation(
      'conversation-b',
      time: firstTime.add(const Duration(milliseconds: 1)),
    );
    await repository.createWithFirstMessage(
      conversation: firstConversation,
      firstMessage: _message('message-a1', firstConversation.conversationId),
      fileIds: const <String>[],
      attachedAt: firstTime,
    );
    await repository.createWithFirstMessage(
      conversation: secondConversation,
      firstMessage: _message('message-b1', secondConversation.conversationId),
      fileIds: const <String>[],
      attachedAt: secondConversation.createdAt,
    );

    final appended = await repository.appendMessage(
      conversationId: firstConversation.conversationId,
      messageId: 'message-a2',
      role: ConversationMessageRole.user,
      content: 'second',
      createdAt: firstTime.subtract(const Duration(hours: 1)),
    );
    expect(appended.message.sequence, 2);
    expect(
      appended.conversation.updatedAt.millisecondsSinceEpoch,
      firstTime.millisecondsSinceEpoch + 1,
    );
    expect(
      (await repository.listRecentConversations(limit: 10))
          .map((value) => value.conversationId),
      <String>['conversation-a', 'conversation-b'],
    );
  });

  test('concurrent appends produce unique contiguous sequence values',
      () async {
    final repository = SqliteConversationRepository();
    final conversation = _conversation('conversation-concurrent');
    await repository.createWithFirstMessage(
      conversation: conversation,
      firstMessage: _message('message-c1', conversation.conversationId),
      fileIds: const <String>[],
      attachedAt: conversation.createdAt,
    );

    await Future.wait(<Future<AppendMessageResult>>[
      repository.appendMessage(
        conversationId: conversation.conversationId,
        messageId: 'message-c2',
        role: ConversationMessageRole.user,
        content: 'second',
        createdAt: conversation.createdAt,
      ),
      repository.appendMessage(
        conversationId: conversation.conversationId,
        messageId: 'message-c3',
        role: ConversationMessageRole.user,
        content: 'third',
        createdAt: conversation.createdAt,
      ),
    ]);

    final loaded = await repository.loadConversation(
      conversationId: conversation.conversationId,
      limit: 100,
    );
    expect(loaded.messages.map((message) => message.sequence), <int>[1, 2, 3]);
  });

  test('message slice loads newest bounded rows without gaps or duplicates',
      () async {
    final repository = SqliteConversationRepository();
    final conversation = _conversation('conversation-page');
    await repository.createWithFirstMessage(
      conversation: conversation,
      firstMessage: _message('message-p1', conversation.conversationId),
      fileIds: const <String>[],
      attachedAt: conversation.createdAt,
    );
    for (var index = 2; index <= 5; index++) {
      await repository.appendMessage(
        conversationId: conversation.conversationId,
        messageId: 'message-p$index',
        role: ConversationMessageRole.user,
        content: 'message $index',
        createdAt: conversation.createdAt,
      );
    }

    final latest = await repository.loadConversation(
      conversationId: conversation.conversationId,
      limit: 2,
    );
    expect(latest.messages.map((message) => message.sequence), <int>[4, 5]);
    expect(latest.hasMoreBefore, isTrue);
    expect(latest.nextBeforeSequence, 4);
    final earlier = await repository.loadConversation(
      conversationId: conversation.conversationId,
      beforeSequence: latest.nextBeforeSequence,
      limit: 3,
    );
    expect(earlier.messages.map((message) => message.sequence), <int>[1, 2, 3]);
    expect(earlier.hasMoreBefore, isFalse);
  });

  test('Project deletion preserves thread/files and makes scope unavailable',
      () async {
    final files = LibraryFileRepository();
    await files.save(_file('file-orphan'));
    final projects = SqliteProjectRepository();
    final project = Project(
      projectId: 'project-orphan',
      displayName: 'Orphan source',
      createdAt: DateTime.utc(2026, 8, 10),
    );
    await projects.createProject(project);
    final repository = SqliteConversationRepository();
    final conversation = _conversation(
      'conversation-orphan',
      scope: ConversationScope.learningSpace(project.projectId),
    );
    await repository.createWithFirstMessage(
      conversation: conversation,
      firstMessage: _message('message-orphan', conversation.conversationId),
      fileIds: const <String>['file-orphan'],
      attachedAt: conversation.createdAt,
    );

    await projects.deleteProject(project.projectId);

    final loaded = await repository.loadConversation(
      conversationId: conversation.conversationId,
      limit: 100,
    );
    expect(loaded.conversation.scope.isUnavailableLearningSpace, isTrue);
    expect(loaded.messages, hasLength(1));
    expect(loaded.files.single.fileId, 'file-orphan');
    expect(
      await repository.listConversationsForProject(
        projectId: project.projectId,
        limit: 20,
      ),
      isEmpty,
    );
    await expectLater(
      repository.appendMessage(
        conversationId: conversation.conversationId,
        messageId: 'message-orphan-2',
        role: ConversationMessageRole.user,
        content: 'blocked',
        createdAt: DateTime.utc(2026, 8, 10, 13),
      ),
      throwsA(
        isA<ConversationException>().having(
          (error) => error.failure,
          'failure',
          ConversationFailure.scopeUnavailable,
        ),
      ),
    );
  });

  test('attach/detach is idempotent and independent from scope recency',
      () async {
    final files = LibraryFileRepository();
    await files.save(_file('file-context'));
    final repository = SqliteConversationRepository();
    final conversation = _conversation('conversation-files');
    await repository.createWithFirstMessage(
      conversation: conversation,
      firstMessage: _message('message-files', conversation.conversationId),
      fileIds: const <String>[],
      attachedAt: conversation.createdAt,
    );

    final attached = await repository.attachFile(
      conversationId: conversation.conversationId,
      fileId: 'file-context',
      attachedAt: conversation.createdAt,
    );
    expect(attached.attached, isTrue);
    final repeated = await repository.attachFile(
      conversationId: conversation.conversationId,
      fileId: 'file-context',
      attachedAt: conversation.createdAt.add(const Duration(hours: 1)),
    );
    expect(repeated.attached, isFalse);
    expect(repeated.conversation.updatedAt, attached.conversation.updatedAt);

    final detached = await repository.detachFile(
      conversationId: conversation.conversationId,
      fileId: 'file-context',
      detachedAt: conversation.createdAt,
    );
    expect(detached.detached, isTrue);
    final repeatedDetach = await repository.detachFile(
      conversationId: conversation.conversationId,
      fileId: 'file-context',
      detachedAt: conversation.createdAt.add(const Duration(hours: 2)),
    );
    expect(repeatedDetach.detached, isFalse);
    expect(
        repeatedDetach.conversation.updatedAt, detached.conversation.updatedAt);
  });

  test('append failure rolls back inserted message and recency update',
      () async {
    final repository = SqliteConversationRepository();
    final conversation = _conversation('conversation-atomic');
    await repository.createWithFirstMessage(
      conversation: conversation,
      firstMessage: _message('message-atomic-1', conversation.conversationId),
      fileIds: const <String>[],
      attachedAt: conversation.createdAt,
    );
    final db = await DatabaseHelper.instance.database;
    await db.execute('''
      CREATE TRIGGER block_conversation_recency
      BEFORE UPDATE OF updated_at ON conversations
      BEGIN
        SELECT RAISE(ABORT, 'synthetic failure');
      END
    ''');

    await expectLater(
      repository.appendMessage(
        conversationId: conversation.conversationId,
        messageId: 'message-atomic-2',
        role: ConversationMessageRole.user,
        content: 'must roll back',
        createdAt: DateTime.utc(2026, 8, 10, 13),
      ),
      throwsA(
        isA<ConversationException>().having(
          (error) => error.failure,
          'failure',
          ConversationFailure.temporarilyUnavailable,
        ),
      ),
    );
    expect(await db.query('conversation_messages'), hasLength(1));
    expect(
      (await db.query('conversations')).single['updated_at'],
      conversation.updatedAt.millisecondsSinceEpoch,
    );
  });

  test('conversation and File deletion cascade only relation-owned rows',
      () async {
    final files = LibraryFileRepository();
    await files.save(_file('file-delete'));
    final repository = SqliteConversationRepository();
    final conversation = _conversation('conversation-delete');
    await repository.createWithFirstMessage(
      conversation: conversation,
      firstMessage: _message('message-delete', conversation.conversationId),
      fileIds: const <String>['file-delete'],
      attachedAt: conversation.createdAt,
    );
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'library_files',
      where: 'file_id = ?',
      whereArgs: <Object?>['file-delete'],
    );
    expect(await db.query('conversation_files'), isEmpty);
    expect(await db.query('conversations'), hasLength(1));
    expect(await db.query('conversation_messages'), hasLength(1));

    await files.save(_file('file-survives'));
    await repository.attachFile(
      conversationId: conversation.conversationId,
      fileId: 'file-survives',
      attachedAt: DateTime.utc(2026, 8, 10, 13),
    );
    await repository.deleteConversation(conversation.conversationId);
    expect(await db.query('conversations'), isEmpty);
    expect(await db.query('conversation_messages'), isEmpty);
    expect(await db.query('conversation_files'), isEmpty);
    expect(await files.findById('file-survives'), isNotNull);
  });

  test('unknown roles are rejected and corrupt rows map to dataCorrupt',
      () async {
    final repository = SqliteConversationRepository();
    final conversation = _conversation('conversation-corrupt');
    await repository.createWithFirstMessage(
      conversation: conversation,
      firstMessage: _message('message-corrupt', conversation.conversationId),
      fileIds: const <String>[],
      attachedAt: conversation.createdAt,
    );
    final db = await DatabaseHelper.instance.database;
    await expectLater(
      db.update(
        'conversation_messages',
        <String, Object?>{'role': 'tool'},
        where: 'message_id = ?',
        whereArgs: <Object?>['message-corrupt'],
      ),
      throwsA(isA<DatabaseException>()),
    );
    await db.update(
      'conversation_messages',
      <String, Object?>{'content': '  noncanonical  '},
      where: 'message_id = ?',
      whereArgs: <Object?>['message-corrupt'],
    );
    await expectLater(
      repository.loadConversation(
        conversationId: conversation.conversationId,
        limit: 100,
      ),
      throwsA(
        isA<ConversationException>().having(
          (error) => error.failure,
          'failure',
          ConversationFailure.dataCorrupt,
        ),
      ),
    );
  });

  group('CONV-MOVE repository contract', () {
    test('moves Global -> Space A and verifies project lists', () async {
      final projects = SqliteProjectRepository();
      await projects.createProject(Project(
        projectId: 'project-a',
        displayName: 'Project A',
        createdAt: DateTime.utc(2026, 8, 10),
      ));
      final repository = SqliteConversationRepository();
      final conv =
          _conversation('conv-g2a', time: DateTime.utc(2026, 8, 10, 10));
      await repository.createWithFirstMessage(
        conversation: conv,
        firstMessage:
            _message('msg-1', 'conv-g2a', time: DateTime.utc(2026, 8, 10, 10)),
        fileIds: const <String>[],
        attachedAt: DateTime.utc(2026, 8, 10, 10),
      );

      final result = await repository.moveConversation(
        conversationId: 'conv-g2a',
        targetScope: ConversationScope.learningSpace('project-a'),
        movedAt: DateTime.utc(2026, 8, 10, 11),
      );

      expect(result.moved, isTrue);
      expect(result.conversation.scope,
          ConversationScope.learningSpace('project-a'));
      expect(result.conversation.updatedAt, DateTime.utc(2026, 8, 10, 11));

      final inProject = await repository.listConversationsForProject(
        projectId: 'project-a',
        limit: 10,
      );
      expect(inProject.map((c) => c.conversationId), contains('conv-g2a'));
    });

    test('moves Space A -> Space B and verifies source loses, target gains',
        () async {
      final projects = SqliteProjectRepository();
      await projects.createProject(Project(
        projectId: 'project-a',
        displayName: 'Project A',
        createdAt: DateTime.utc(2026, 8, 10),
      ));
      await projects.createProject(Project(
        projectId: 'project-b',
        displayName: 'Project B',
        createdAt: DateTime.utc(2026, 8, 10),
      ));
      final repository = SqliteConversationRepository();
      final conv = _conversation(
        'conv-a2b',
        scope: ConversationScope.learningSpace('project-a'),
        time: DateTime.utc(2026, 8, 10, 10),
      );
      await repository.createWithFirstMessage(
        conversation: conv,
        firstMessage:
            _message('msg-1', 'conv-a2b', time: DateTime.utc(2026, 8, 10, 10)),
        fileIds: const <String>[],
        attachedAt: DateTime.utc(2026, 8, 10, 10),
      );

      final result = await repository.moveConversation(
        conversationId: 'conv-a2b',
        targetScope: ConversationScope.learningSpace('project-b'),
        movedAt: DateTime.utc(2026, 8, 10, 11),
      );

      expect(result.moved, isTrue);
      expect(result.conversation.scope,
          ConversationScope.learningSpace('project-b'));

      final listA = await repository.listConversationsForProject(
          projectId: 'project-a', limit: 10);
      final listB = await repository.listConversationsForProject(
          projectId: 'project-b', limit: 10);
      expect(listA, isEmpty);
      expect(listB.single.conversationId, 'conv-a2b');
    });

    test('moves Space A -> Global', () async {
      final projects = SqliteProjectRepository();
      await projects.createProject(Project(
        projectId: 'project-a',
        displayName: 'Project A',
        createdAt: DateTime.utc(2026, 8, 10),
      ));
      final repository = SqliteConversationRepository();
      final conv = _conversation(
        'conv-a2g',
        scope: ConversationScope.learningSpace('project-a'),
        time: DateTime.utc(2026, 8, 10, 10),
      );
      await repository.createWithFirstMessage(
        conversation: conv,
        firstMessage:
            _message('msg-1', 'conv-a2g', time: DateTime.utc(2026, 8, 10, 10)),
        fileIds: const <String>[],
        attachedAt: DateTime.utc(2026, 8, 10, 10),
      );

      final result = await repository.moveConversation(
        conversationId: 'conv-a2g',
        targetScope: ConversationScope.global(),
        movedAt: DateTime.utc(2026, 8, 10, 11),
      );

      expect(result.moved, isTrue);
      expect(result.conversation.scope, ConversationScope.global());
      final listA = await repository.listConversationsForProject(
          projectId: 'project-a', limit: 10);
      expect(listA, isEmpty);
    });

    test('recovers from UnavailableLearningSpace -> Global and -> valid Space',
        () async {
      final projects = SqliteProjectRepository();
      await projects.createProject(Project(
        projectId: 'project-del',
        displayName: 'To Delete',
        createdAt: DateTime.utc(2026, 8, 10),
      ));
      await projects.createProject(Project(
        projectId: 'project-survives',
        displayName: 'Survives',
        createdAt: DateTime.utc(2026, 8, 10),
      ));
      final repository = SqliteConversationRepository();
      final conv = _conversation(
        'conv-unavail',
        scope: ConversationScope.learningSpace('project-del'),
        time: DateTime.utc(2026, 8, 10, 10),
      );
      await repository.createWithFirstMessage(
        conversation: conv,
        firstMessage: _message('msg-1', 'conv-unavail',
            time: DateTime.utc(2026, 8, 10, 10)),
        fileIds: const <String>[],
        attachedAt: DateTime.utc(2026, 8, 10, 10),
      );

      // Delete the project so conversation becomes unavailableLearningSpace
      await projects.deleteProject('project-del');
      final loaded = await repository.loadConversation(
          conversationId: 'conv-unavail', limit: 10);
      expect(loaded.conversation.scope.isUnavailableLearningSpace, isTrue);

      // Recovery to Space
      final resSpace = await repository.moveConversation(
        conversationId: 'conv-unavail',
        targetScope: ConversationScope.learningSpace('project-survives'),
        movedAt: DateTime.utc(2026, 8, 10, 12),
      );
      expect(resSpace.moved, isTrue);
      expect(resSpace.conversation.scope,
          ConversationScope.learningSpace('project-survives'));

      // Recovery to Global
      final resGlobal = await repository.moveConversation(
        conversationId: 'conv-unavail',
        targetScope: ConversationScope.global(),
        movedAt: DateTime.utc(2026, 8, 10, 13),
      );
      expect(resGlobal.moved, isTrue);
      expect(resGlobal.conversation.scope, ConversationScope.global());
    });

    test(
        'missing target Project throws projectNotFound and leaves scope unchanged',
        () async {
      final repository = SqliteConversationRepository();
      final conv =
          _conversation('conv-miss-proj', time: DateTime.utc(2026, 8, 10, 10));
      await repository.createWithFirstMessage(
        conversation: conv,
        firstMessage: _message('msg-1', 'conv-miss-proj',
            time: DateTime.utc(2026, 8, 10, 10)),
        fileIds: const <String>[],
        attachedAt: DateTime.utc(2026, 8, 10, 10),
      );

      await expectLater(
        repository.moveConversation(
          conversationId: 'conv-miss-proj',
          targetScope: ConversationScope.learningSpace('non-existent-project'),
          movedAt: DateTime.utc(2026, 8, 10, 11),
        ),
        throwsA(
          isA<ConversationException>().having(
            (e) => e.failure,
            'failure',
            ConversationFailure.projectNotFound,
          ),
        ),
      );

      final loaded = await repository.loadConversation(
          conversationId: 'conv-miss-proj', limit: 10);
      expect(loaded.conversation.scope, ConversationScope.global());
      expect(loaded.conversation.updatedAt, DateTime.utc(2026, 8, 10, 10));
    });

    test('same scope is no-op (moved = false, updatedAt unchanged)', () async {
      final repository = SqliteConversationRepository();
      final conv =
          _conversation('conv-same', time: DateTime.utc(2026, 8, 10, 10));
      await repository.createWithFirstMessage(
        conversation: conv,
        firstMessage:
            _message('msg-1', 'conv-same', time: DateTime.utc(2026, 8, 10, 10)),
        fileIds: const <String>[],
        attachedAt: DateTime.utc(2026, 8, 10, 10),
      );

      final result = await repository.moveConversation(
        conversationId: 'conv-same',
        targetScope: ConversationScope.global(),
        movedAt: DateTime.utc(2026, 8, 10, 15),
      );

      expect(result.moved, isFalse);
      expect(result.conversation.updatedAt, DateTime.utc(2026, 8, 10, 10));

      final loaded = await repository.loadConversation(
          conversationId: 'conv-same', limit: 10);
      expect(loaded.conversation.updatedAt, DateTime.utc(2026, 8, 10, 10));
    });

    test('monotonic recency advance even with older movedAt timestamp',
        () async {
      final projects = SqliteProjectRepository();
      await projects.createProject(Project(
        projectId: 'project-a',
        displayName: 'Project A',
        createdAt: DateTime.utc(2026, 8, 10),
      ));
      final repository = SqliteConversationRepository();
      final conv =
          _conversation('conv-recency', time: DateTime.utc(2026, 8, 10, 12));
      await repository.createWithFirstMessage(
        conversation: conv,
        firstMessage: _message('msg-1', 'conv-recency',
            time: DateTime.utc(2026, 8, 10, 12)),
        fileIds: const <String>[],
        attachedAt: DateTime.utc(2026, 8, 10, 12),
      );

      // Pass an earlier time than current updatedAt
      final result = await repository.moveConversation(
        conversationId: 'conv-recency',
        targetScope: ConversationScope.learningSpace('project-a'),
        movedAt: DateTime.utc(2026, 8, 10, 8),
      );

      expect(result.moved, isTrue);
      expect(
        result.conversation.updatedAt.millisecondsSinceEpoch,
        conv.updatedAt.millisecondsSinceEpoch + 1,
      );
    });

    test(
        'preserves messages, attached files, title, createdAt, and IDs completely',
        () async {
      final files = LibraryFileRepository();
      await files.save(_file('file-1'));
      await files.save(_file('file-2', hour: 2));

      final projects = SqliteProjectRepository();
      await projects.createProject(Project(
        projectId: 'project-a',
        displayName: 'Project A',
        createdAt: DateTime.utc(2026, 8, 10),
      ));

      final repository = SqliteConversationRepository();
      final conv =
          _conversation('conv-preserve', time: DateTime.utc(2026, 8, 10, 10));
      await repository.createWithFirstMessage(
        conversation: conv,
        firstMessage: _message('msg-1', 'conv-preserve',
            sequence: 1, content: 'User question 1'),
        fileIds: const <String>['file-1', 'file-2'],
        attachedAt: DateTime.utc(2026, 8, 10, 10),
      );
      await repository.appendMessage(
        conversationId: 'conv-preserve',
        messageId: 'msg-2',
        role: ConversationMessageRole.assistant,
        content: 'Assistant answer',
        createdAt: DateTime.utc(2026, 8, 10, 10, 1),
      );

      // Move
      await repository.moveConversation(
        conversationId: 'conv-preserve',
        targetScope: ConversationScope.learningSpace('project-a'),
        movedAt: DateTime.utc(2026, 8, 10, 11),
      );

      final loaded = await repository.loadConversation(
          conversationId: 'conv-preserve', limit: 10);
      expect(loaded.conversation.conversationId, 'conv-preserve');
      expect(loaded.conversation.title, 'Conversation conv-preserve');
      expect(loaded.conversation.createdAt, DateTime.utc(2026, 8, 10, 10));
      expect(loaded.conversation.scope,
          ConversationScope.learningSpace('project-a'));

      expect(loaded.messages, hasLength(2));
      expect(loaded.messages[0].messageId, 'msg-1');
      expect(loaded.messages[0].content, 'User question 1');
      expect(loaded.messages[0].role, ConversationMessageRole.user);
      expect(loaded.messages[1].messageId, 'msg-2');
      expect(loaded.messages[1].content, 'Assistant answer');
      expect(loaded.messages[1].role, ConversationMessageRole.assistant);

      expect(loaded.files.map((f) => f.fileId), <String>['file-1', 'file-2']);
    });

    test(
        'moving to target space followed by project deletion produces unavailableLearningSpace',
        () async {
      final projects = SqliteProjectRepository();
      await projects.createProject(Project(
        projectId: 'project-del-later',
        displayName: 'Delete Later',
        createdAt: DateTime.utc(2026, 8, 10),
      ));

      final repository = SqliteConversationRepository();
      final conv =
          _conversation('conv-del-later', time: DateTime.utc(2026, 8, 10, 10));
      await repository.createWithFirstMessage(
        conversation: conv,
        firstMessage: _message('msg-1', 'conv-del-later'),
        fileIds: const <String>[],
        attachedAt: DateTime.utc(2026, 8, 10, 10),
      );

      await repository.moveConversation(
        conversationId: 'conv-del-later',
        targetScope: ConversationScope.learningSpace('project-del-later'),
        movedAt: DateTime.utc(2026, 8, 10, 11),
      );

      await projects.deleteProject('project-del-later');

      final loaded = await repository.loadConversation(
          conversationId: 'conv-del-later', limit: 10);
      expect(loaded.conversation.scope.isUnavailableLearningSpace, isTrue);
      expect(
          loaded.conversation.scope.kind, ConversationScopeKind.learningSpace);
      expect(loaded.conversation.scope.projectId, isNull);
    });
  });
}
