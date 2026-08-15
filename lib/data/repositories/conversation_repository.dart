import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import '../../application/conversations/conversation_repository.dart';
import '../../core/database/database_helper.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';

/// SQLite implementation of the additive C0 Conversation persistence port.
///
/// It may read `projects` and `library_files` only to enforce scope and File
/// reference integrity. It never reads Folder, Bank, Question, MCP, provider,
/// or managed-byte state.
final class SqliteConversationRepository implements ConversationRepositoryPort {
  SqliteConversationRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _databaseHelper;

  static const String _conversations = 'conversations';
  static const String _messages = 'conversation_messages';
  static const String _conversationFiles = 'conversation_files';
  static const String _projects = 'projects';
  static const String _libraryFiles = 'library_files';

  @override
  Future<ConversationThreadSlice> createWithFirstMessage({
    required Conversation conversation,
    required ConversationMessage firstMessage,
    required List<String> fileIds,
    required DateTime attachedAt,
  }) {
    return _write((db) async {
      return db.transaction((txn) async {
        if (firstMessage.conversationId != conversation.conversationId ||
            firstMessage.sequence != 1 ||
            firstMessage.role != ConversationMessageRole.user) {
          throw const ConversationException(ConversationFailure.invalidInput);
        }
        if (await _conversationIdExists(txn, conversation.conversationId) ||
            await _messageIdExists(txn, firstMessage.messageId)) {
          throw const ConversationException(ConversationFailure.idConflict);
        }
        await _expectCreatableScope(txn, conversation.scope);
        final files = await _expectFiles(txn, fileIds);

        await txn.insert(_conversations, _conversationToRow(conversation));
        await txn.insert(_messages, _messageToRow(firstMessage));
        for (final fileId in fileIds) {
          await txn.insert(_conversationFiles, <String, Object?>{
            'conversation_id': conversation.conversationId,
            'file_id': fileId,
            'attached_at': attachedAt.millisecondsSinceEpoch,
          });
        }
        return ConversationThreadSlice(
          conversation: conversation,
          messages: <ConversationMessage>[firstMessage],
          files: files,
          hasMoreBefore: false,
          nextBeforeSequence: null,
        );
      });
    });
  }

  @override
  Future<AppendMessageResult> appendMessage({
    required String conversationId,
    required String messageId,
    required ConversationMessageRole role,
    required String content,
    required DateTime createdAt,
  }) {
    return _write((db) async {
      return db.transaction((txn) async {
        final current = await _expectConversation(txn, conversationId);
        if (current.scope.isUnavailableLearningSpace) {
          throw const ConversationException(
            ConversationFailure.scopeUnavailable,
          );
        }
        if (await _messageIdExists(txn, messageId)) {
          throw const ConversationException(ConversationFailure.idConflict);
        }
        final sequenceRows = await txn.rawQuery(
          'SELECT COALESCE(MAX(sequence), 0) AS value '
          'FROM $_messages WHERE conversation_id = ?',
          <Object?>[conversationId],
        );
        final sequence = (sequenceRows.single['value']! as int) + 1;
        final message = ConversationMessage(
          messageId: messageId,
          conversationId: conversationId,
          sequence: sequence,
          role: role,
          content: content,
          createdAt: createdAt,
        );
        await txn.insert(_messages, _messageToRow(message));
        final updated = await _advanceRecency(txn, current, createdAt);
        return AppendMessageResult(conversation: updated, message: message);
      });
    });
  }

  @override
  Future<AppendFileResult> attachFile({
    required String conversationId,
    required String fileId,
    required DateTime attachedAt,
  }) {
    return _write((db) async {
      return db.transaction((txn) async {
        final current = await _expectConversation(txn, conversationId);
        final file = await _expectFile(txn, fileId);
        final existing = await txn.query(
          _conversationFiles,
          columns: const <String>['file_id'],
          where: 'conversation_id = ? AND file_id = ?',
          whereArgs: <Object?>[conversationId, fileId],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          return AppendFileResult(
            conversation: current,
            file: file,
            attached: false,
          );
        }
        await txn.insert(_conversationFiles, <String, Object?>{
          'conversation_id': conversationId,
          'file_id': fileId,
          'attached_at': attachedAt.millisecondsSinceEpoch,
        });
        final updated = await _advanceRecency(txn, current, attachedAt);
        return AppendFileResult(
          conversation: updated,
          file: file,
          attached: true,
        );
      });
    });
  }

  @override
  Future<DetachFileResult> detachFile({
    required String conversationId,
    required String fileId,
    required DateTime detachedAt,
  }) {
    return _write((db) async {
      return db.transaction((txn) async {
        final current = await _expectConversation(txn, conversationId);
        final deleted = await txn.delete(
          _conversationFiles,
          where: 'conversation_id = ? AND file_id = ?',
          whereArgs: <Object?>[conversationId, fileId],
        );
        if (deleted == 0) {
          return DetachFileResult(
            conversation: current,
            fileId: fileId,
            detached: false,
          );
        }
        final updated = await _advanceRecency(txn, current, detachedAt);
        return DetachFileResult(
          conversation: updated,
          fileId: fileId,
          detached: true,
        );
      });
    });
  }

  @override
  Future<MoveConversationResult> moveConversation({
    required String conversationId,
    required ConversationScope targetScope,
    required DateTime movedAt,
  }) {
    return _write((db) async {
      return db.transaction((txn) async {
        final current = await _expectConversation(txn, conversationId);
        await _expectCreatableScope(txn, targetScope);

        if (current.scope == targetScope) {
          return MoveConversationResult(
            conversation: current,
            moved: false,
          );
        }

        final nextMilliseconds = math.max(
          movedAt.millisecondsSinceEpoch,
          current.updatedAt.millisecondsSinceEpoch + 1,
        );
        final nextUpdatedAt = DateTime.fromMillisecondsSinceEpoch(
          nextMilliseconds,
          isUtc: true,
        );

        final count = await txn.update(
          _conversations,
          <String, Object?>{
            'scope_kind': targetScope.kind == ConversationScopeKind.global
                ? 'global'
                : 'learning_space',
            'project_id': targetScope.kind == ConversationScopeKind.global
                ? null
                : targetScope.projectId,
            'updated_at': nextMilliseconds,
          },
          where: 'conversation_id = ?',
          whereArgs: <Object?>[conversationId],
        );
        if (count != 1) {
          throw const ConversationException(
            ConversationFailure.conversationNotFound,
          );
        }

        final updated = current.withScope(
          scope: targetScope,
          updatedAt: nextUpdatedAt,
        );
        return MoveConversationResult(
          conversation: updated,
          moved: true,
        );
      });
    });
  }

  @override
  Future<List<ConversationFileRef>> listAttachableFiles({required int limit}) {
    return _read((db) async {
      final rows = await db.query(
        _libraryFiles,
        columns: const <String>[
          'file_id',
          'display_name',
          'mime_type',
          'size_bytes',
        ],
        orderBy: 'created_at DESC, file_id ASC',
        limit: limit,
      );
      return rows.map(_fileFromRow).toList(growable: false);
    });
  }

  @override
  Future<List<Conversation>> listRecentConversations({required int limit}) {
    return _read((db) async {
      final rows = await db.query(
        _conversations,
        orderBy: 'updated_at DESC, conversation_id ASC',
        limit: limit,
      );
      return rows.map(_conversationFromRow).toList(growable: false);
    });
  }

  @override
  Future<List<Conversation>> listConversationsForProject({
    required String projectId,
    required int limit,
  }) {
    return _read((db) async {
      final rows = await db.query(
        _conversations,
        where: "scope_kind = 'learning_space' AND project_id = ?",
        whereArgs: <Object?>[projectId],
        orderBy: 'updated_at DESC, conversation_id ASC',
        limit: limit,
      );
      return rows.map(_conversationFromRow).toList(growable: false);
    });
  }

  @override
  Future<ConversationThreadSlice> loadConversation({
    required String conversationId,
    required int limit,
    int? beforeSequence,
  }) {
    return _read((db) async {
      return db.transaction((txn) async {
        final conversation = await _expectConversation(txn, conversationId);
        final rows = await txn.query(
          _messages,
          where: beforeSequence == null
              ? 'conversation_id = ?'
              : 'conversation_id = ? AND sequence < ?',
          whereArgs: <Object?>[
            conversationId,
            if (beforeSequence != null) beforeSequence,
          ],
          orderBy: 'sequence DESC',
          limit: limit + 1,
        );
        final hasMoreBefore = rows.length > limit;
        final selected = rows.take(limit).map(_messageFromRow).toList()
          ..sort((left, right) => left.sequence.compareTo(right.sequence));
        return ConversationThreadSlice(
          conversation: conversation,
          messages: selected,
          files: await _listConversationFiles(txn, conversationId),
          hasMoreBefore: hasMoreBefore,
          nextBeforeSequence: hasMoreBefore && selected.isNotEmpty
              ? selected.first.sequence
              : null,
        );
      });
    });
  }

  @override
  Future<void> deleteConversation(String conversationId) {
    return _write((db) async {
      await db.transaction((txn) async {
        await _expectConversation(txn, conversationId);
        await txn.delete(
          _conversations,
          where: 'conversation_id = ?',
          whereArgs: <Object?>[conversationId],
        );
      });
    });
  }

  Future<Conversation> _advanceRecency(
    DatabaseExecutor db,
    Conversation current,
    DateTime candidate,
  ) async {
    final nextMilliseconds = math.max(
      candidate.millisecondsSinceEpoch,
      current.updatedAt.millisecondsSinceEpoch + 1,
    );
    final updated = current.withUpdatedAt(
      DateTime.fromMillisecondsSinceEpoch(nextMilliseconds, isUtc: true),
    );
    final count = await db.update(
      _conversations,
      <String, Object?>{'updated_at': nextMilliseconds},
      where: 'conversation_id = ?',
      whereArgs: <Object?>[current.conversationId],
    );
    if (count != 1) {
      throw const ConversationException(
        ConversationFailure.conversationNotFound,
      );
    }
    return updated;
  }

  Future<void> _expectCreatableScope(
    DatabaseExecutor db,
    ConversationScope scope,
  ) async {
    if (scope.kind == ConversationScopeKind.global) return;
    final projectId = scope.projectId;
    if (projectId == null) {
      throw const ConversationException(ConversationFailure.scopeUnavailable);
    }
    final rows = await db.query(
      _projects,
      columns: const <String>['project_id'],
      where: 'project_id = ?',
      whereArgs: <Object?>[projectId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const ConversationException(ConversationFailure.projectNotFound);
    }
  }

  Future<List<ConversationFileRef>> _expectFiles(
    DatabaseExecutor db,
    List<String> fileIds,
  ) async {
    if (fileIds.isEmpty) return const <ConversationFileRef>[];
    final placeholders = List<String>.filled(fileIds.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT file_id, display_name, mime_type, size_bytes '
      'FROM $_libraryFiles WHERE file_id IN ($placeholders)',
      fileIds,
    );
    final byId = <String, ConversationFileRef>{
      for (final row in rows) row['file_id']! as String: _fileFromRow(row),
    };
    if (byId.length != fileIds.length) {
      throw const ConversationException(ConversationFailure.fileNotFound);
    }
    return <ConversationFileRef>[for (final fileId in fileIds) byId[fileId]!];
  }

  Future<ConversationFileRef> _expectFile(
    DatabaseExecutor db,
    String fileId,
  ) async {
    final rows = await db.query(
      _libraryFiles,
      columns: const <String>[
        'file_id',
        'display_name',
        'mime_type',
        'size_bytes',
      ],
      where: 'file_id = ?',
      whereArgs: <Object?>[fileId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const ConversationException(ConversationFailure.fileNotFound);
    }
    return _fileFromRow(rows.single);
  }

  Future<List<ConversationFileRef>> _listConversationFiles(
    DatabaseExecutor db,
    String conversationId,
  ) async {
    final rows = await db.rawQuery(
      '''
      SELECT f.file_id, f.display_name, f.mime_type, f.size_bytes
      FROM $_conversationFiles cf
      JOIN $_libraryFiles f ON f.file_id = cf.file_id
      WHERE cf.conversation_id = ?
      ORDER BY cf.attached_at ASC, cf.file_id ASC
      ''',
      <Object?>[conversationId],
    );
    return rows.map(_fileFromRow).toList(growable: false);
  }

  Future<Conversation> _expectConversation(
    DatabaseExecutor db,
    String conversationId,
  ) async {
    final rows = await db.query(
      _conversations,
      where: 'conversation_id = ?',
      whereArgs: <Object?>[conversationId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const ConversationException(
        ConversationFailure.conversationNotFound,
      );
    }
    return _conversationFromRow(rows.single);
  }

  Future<bool> _conversationIdExists(
    DatabaseExecutor db,
    String conversationId,
  ) async {
    final rows = await db.query(
      _conversations,
      columns: const <String>['conversation_id'],
      where: 'conversation_id = ?',
      whereArgs: <Object?>[conversationId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> _messageIdExists(DatabaseExecutor db, String messageId) async {
    final rows = await db.query(
      _messages,
      columns: const <String>['message_id'],
      where: 'message_id = ?',
      whereArgs: <Object?>[messageId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Map<String, Object?> _conversationToRow(Conversation conversation) {
    return <String, Object?>{
      'conversation_id': conversation.conversationId,
      'scope_kind': switch (conversation.scope.kind) {
        ConversationScopeKind.global => 'global',
        ConversationScopeKind.learningSpace => 'learning_space',
      },
      'project_id': conversation.scope.projectId,
      'title': conversation.title,
      'created_at': conversation.createdAt.millisecondsSinceEpoch,
      'updated_at': conversation.updatedAt.millisecondsSinceEpoch,
    };
  }

  Conversation _conversationFromRow(Map<String, Object?> row) {
    final scope = switch (row['scope_kind']) {
      'global' => ConversationScope.global(),
      'learning_space' => row['project_id'] == null
          ? ConversationScope.unavailableLearningSpace()
          : ConversationScope.learningSpace(row['project_id']! as String),
      _ => throw const FormatException('Unknown conversation scope.'),
    };
    final rawTitle = row['title']! as String;
    final conversation = Conversation(
      conversationId: row['conversation_id']! as String,
      scope: scope,
      title: rawTitle,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at']! as int,
        isUtc: true,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at']! as int,
        isUtc: true,
      ),
    );
    if (conversation.title != rawTitle) {
      throw const FormatException('Conversation title is not canonical.');
    }
    return conversation;
  }

  Map<String, Object?> _messageToRow(ConversationMessage message) {
    return <String, Object?>{
      'message_id': message.messageId,
      'conversation_id': message.conversationId,
      'sequence': message.sequence,
      'role': switch (message.role) {
        ConversationMessageRole.user => 'user',
        ConversationMessageRole.assistant => 'assistant',
      },
      'content': message.content,
      'created_at': message.createdAt.millisecondsSinceEpoch,
    };
  }

  ConversationMessage _messageFromRow(Map<String, Object?> row) {
    final rawContent = row['content']! as String;
    final message = ConversationMessage(
      messageId: row['message_id']! as String,
      conversationId: row['conversation_id']! as String,
      sequence: row['sequence']! as int,
      role: switch (row['role']) {
        'user' => ConversationMessageRole.user,
        'assistant' => ConversationMessageRole.assistant,
        _ => throw const FormatException('Unknown conversation message role.'),
      },
      content: rawContent,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at']! as int,
        isUtc: true,
      ),
    );
    if (message.content != rawContent) {
      throw const FormatException('Conversation message is not canonical.');
    }
    return message;
  }

  ConversationFileRef _fileFromRow(Map<String, Object?> row) {
    return ConversationFileRef(
      fileId: row['file_id']! as String,
      displayName: row['display_name']! as String,
      mimeType: row['mime_type']! as String,
      sizeBytes: row['size_bytes']! as int,
    );
  }

  Future<T> _read<T>(Future<T> Function(Database db) action) async {
    try {
      return await action(await _databaseHelper.database);
    } on ConversationException {
      rethrow;
    } on FormatException {
      throw const ConversationException(ConversationFailure.dataCorrupt);
    } on TypeError {
      throw const ConversationException(ConversationFailure.dataCorrupt);
    } on StateError {
      throw const ConversationException(ConversationFailure.dataCorrupt);
    } on ConversationSchemaException {
      throw const ConversationException(ConversationFailure.dataCorrupt);
    } on DatabaseRuntimeException {
      throw const ConversationException(
        ConversationFailure.temporarilyUnavailable,
      );
    } on DatabaseException {
      throw const ConversationException(
        ConversationFailure.temporarilyUnavailable,
      );
    }
  }

  Future<T> _write<T>(Future<T> Function(Database db) action) => _read(action);
}
