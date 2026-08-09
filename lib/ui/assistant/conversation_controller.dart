import 'package:flutter/foundation.dart';

import '../../application/conversations/conversation_repository.dart';
import '../../application/conversations/conversation_service.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';

const String conversationReadSafeError = '暂时无法读取对话，请稍后重试';
const String conversationWriteSafeError = '暂时无法保存对话，请稍后重试';

final class ConversationController extends ChangeNotifier {
  ConversationController(this.service);

  final ConversationService service;

  List<Conversation> recent = const <Conversation>[];
  List<ConversationFileRef> attachableFiles = const <ConversationFileRef>[];
  final Map<String, List<Conversation>> projectConversations =
      <String, List<Conversation>>{};
  final Set<String> loadingProjectIds = <String>{};
  final Set<String> draftFileIds = <String>{};

  ConversationThreadSlice? activeThread;
  ConversationScope draftScope = ConversationScope.global();
  bool isLoading = false;
  bool isSending = false;
  bool isLoadingOlder = false;
  String? errorMessage;
  String? statusMessage;

  ConversationScope get currentScope =>
      activeThread?.conversation.scope ?? draftScope;

  bool get isDraft => activeThread == null;

  List<ConversationFileRef> get selectedFiles {
    final active = activeThread;
    if (active != null) return active.files;
    final selected = draftFileIds;
    return attachableFiles
        .where((file) => selected.contains(file.fileId))
        .toList(growable: false);
  }

  Future<void> load() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final values = await Future.wait<Object>(<Future<Object>>[
        service.listRecentConversations(),
        service.listAttachableFiles(),
      ]);
      recent = values[0] as List<Conversation>;
      attachableFiles = values[1] as List<ConversationFileRef>;
    } catch (_) {
      errorMessage = conversationReadSafeError;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  void startNew({ConversationScope? scope}) {
    activeThread = null;
    draftScope = scope ?? ConversationScope.global();
    draftFileIds.clear();
    errorMessage = null;
    statusMessage = null;
    notifyListeners();
  }

  void selectDraftScope(ConversationScope scope) {
    if (!isDraft) return;
    draftScope = scope;
    errorMessage = null;
    notifyListeners();
  }

  Future<bool> openConversation(String conversationId) async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      activeThread = await service.loadConversation(
        conversationId: conversationId,
      );
      draftFileIds.clear();
      statusMessage = 'Shiroha 回复能力尚未接入，消息已保存';
      return true;
    } on ConversationException catch (error) {
      errorMessage = _safeReadError(error.failure);
      return false;
    } catch (_) {
      errorMessage = conversationReadSafeError;
      return false;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> send(String content) async {
    isSending = true;
    errorMessage = null;
    notifyListeners();
    try {
      final active = activeThread;
      if (active == null) {
        activeThread = await service.startWithUserMessage(
          scope: draftScope,
          content: content,
          fileIds: draftFileIds,
        );
        draftFileIds.clear();
      } else {
        final appended = await service.appendUserMessage(
          conversationId: active.conversation.conversationId,
          content: content,
        );
        activeThread = ConversationThreadSlice(
          conversation: appended.conversation,
          messages: <ConversationMessage>[...active.messages, appended.message],
          files: active.files,
          hasMoreBefore: active.hasMoreBefore,
          nextBeforeSequence: active.nextBeforeSequence,
        );
      }
      statusMessage = 'Shiroha 回复能力尚未接入，消息已保存';
      try {
        await _refreshLists();
      } catch (_) {
        // The message is already persisted; a failed recency refresh must
        // not be reported as a save failure, or the composer would keep the
        // text and a retry would persist a duplicate message.
        errorMessage = conversationReadSafeError;
      }
      return true;
    } on ConversationException catch (error) {
      errorMessage = _safeWriteError(error.failure);
      return false;
    } catch (_) {
      errorMessage = conversationWriteSafeError;
      return false;
    } finally {
      isSending = false;
      notifyListeners();
    }
  }

  Future<void> loadOlderMessages() async {
    final active = activeThread;
    final before = active?.nextBeforeSequence;
    if (active == null || !active.hasMoreBefore || before == null) return;
    isLoadingOlder = true;
    errorMessage = null;
    notifyListeners();
    try {
      final older = await service.loadConversation(
        conversationId: active.conversation.conversationId,
        beforeSequence: before,
      );
      activeThread = ConversationThreadSlice(
        conversation: older.conversation,
        messages: <ConversationMessage>[...older.messages, ...active.messages],
        files: older.files,
        hasMoreBefore: older.hasMoreBefore,
        nextBeforeSequence: older.nextBeforeSequence,
      );
    } on ConversationException catch (error) {
      errorMessage = _safeReadError(error.failure);
    } catch (_) {
      errorMessage = conversationReadSafeError;
    } finally {
      isLoadingOlder = false;
      notifyListeners();
    }
  }

  Future<bool> toggleFile(String fileId) async {
    if (isDraft) {
      if (!draftFileIds.add(fileId)) draftFileIds.remove(fileId);
      errorMessage = null;
      notifyListeners();
      return true;
    }
    final active = activeThread!;
    final exists = active.files.any((file) => file.fileId == fileId);
    try {
      if (exists) {
        final result = await service.detachFile(
          conversationId: active.conversation.conversationId,
          fileId: fileId,
        );
        activeThread = ConversationThreadSlice(
          conversation: result.conversation,
          messages: active.messages,
          files: active.files
              .where((file) => file.fileId != fileId)
              .toList(growable: false),
          hasMoreBefore: active.hasMoreBefore,
          nextBeforeSequence: active.nextBeforeSequence,
        );
      } else {
        final result = await service.attachFile(
          conversationId: active.conversation.conversationId,
          fileId: fileId,
        );
        activeThread = ConversationThreadSlice(
          conversation: result.conversation,
          messages: active.messages,
          files: <ConversationFileRef>[...active.files, result.file],
          hasMoreBefore: active.hasMoreBefore,
          nextBeforeSequence: active.nextBeforeSequence,
        );
      }
      errorMessage = null;
      await _refreshLists();
      notifyListeners();
      return true;
    } on ConversationException catch (error) {
      errorMessage = _safeWriteError(error.failure);
      notifyListeners();
      return false;
    } catch (_) {
      errorMessage = conversationWriteSafeError;
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteActiveConversation() async {
    final active = activeThread;
    if (active == null) return false;
    try {
      await service.deleteConversation(active.conversation.conversationId);
      startNew();
      await _refreshLists();
      notifyListeners();
      return true;
    } on ConversationException catch (error) {
      errorMessage = _safeWriteError(error.failure);
      notifyListeners();
      return false;
    } catch (_) {
      errorMessage = conversationWriteSafeError;
      notifyListeners();
      return false;
    }
  }

  Future<void> loadProjectConversations(String projectId) async {
    if (!loadingProjectIds.add(projectId)) return;
    notifyListeners();
    try {
      projectConversations[projectId] =
          await service.listConversationsForProject(projectId: projectId);
    } catch (_) {
      errorMessage = conversationReadSafeError;
    } finally {
      loadingProjectIds.remove(projectId);
      notifyListeners();
    }
  }

  Future<void> refreshAfterProjectDeleted(String projectId) async {
    projectConversations.remove(projectId);
    final active = activeThread;
    await _refreshLists();
    if (active?.conversation.scope.projectId == projectId) {
      await openConversation(active!.conversation.conversationId);
    }
    notifyListeners();
  }

  Future<void> _refreshLists() async {
    recent = await service.listRecentConversations();
    for (final projectId in projectConversations.keys.toList()) {
      projectConversations[projectId] =
          await service.listConversationsForProject(projectId: projectId);
    }
  }

  String _safeReadError(ConversationFailure failure) {
    return switch (failure) {
      ConversationFailure.conversationNotFound => '对话已不存在',
      ConversationFailure.scopeUnavailable => '原学习空间已删除',
      _ => conversationReadSafeError,
    };
  }

  String _safeWriteError(ConversationFailure failure) {
    return switch (failure) {
      ConversationFailure.invalidInput => '消息内容不能为空',
      ConversationFailure.conversationNotFound => '对话已不存在',
      ConversationFailure.projectNotFound => '学习空间已不存在，请重新选择范围',
      ConversationFailure.fileNotFound => '文件已不存在，请刷新后重试',
      ConversationFailure.scopeUnavailable => '原学习空间已删除，请新建对话',
      _ => conversationWriteSafeError,
    };
  }
}
