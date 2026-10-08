import 'package:flutter/foundation.dart';
import '../../application/generated_question/generated_local_authority.dart';
import '../../application/generated_question/generated_question_service.dart';
import '../../domain/generated_question/generated_question_contract.dart';

String generatedReviewError(Object error) => switch (error) {
      GeneratedLocalIdentityException(:final failure) => switch (failure) {
          GeneratedLocalIdentityFailure.missingWithProposals =>
            '本地身份缺失，已有题目批次不能自动认领。请先完成兼容处理。',
          GeneratedLocalIdentityFailure.corrupt => '本地数据身份损坏，已停止审核访问。',
          GeneratedLocalIdentityFailure.ownerMismatch =>
            '本地身份与题目批次不一致，已停止审核访问。',
          GeneratedLocalIdentityFailure.persistenceFailed => '无法读取或初始化本地身份。',
        },
      GeneratedQuestionException(:final failure) => switch (failure) {
          GeneratedFailure.staleRevision => '审核内容已被其他窗口修改。请重新加载；本地未保存操作仍保留。',
          GeneratedFailure.targetChanged => '目标题库或学习空间关系已变化，请明确重新绑定并重新审核。',
          GeneratedFailure.staleEvidence => '来源证据已变化，请刷新来源状态并明确确认。',
          GeneratedFailure.duplicateContent => '检测到重复题目，无法正式入库。请修改或拒绝重复题目。',
          GeneratedFailure.reviewIncomplete => '请明确接受或拒绝全部题目，稍后处理的题目不能提交。',
          GeneratedFailure.qualityBlocked => '题目未通过质量检查，请修改后重新审核。',
          GeneratedFailure.terminalConflict => '该批次已完成其他终态操作，请核实持久化结果。',
          GeneratedFailure.unauthorized => '当前审核会话已失效，请关闭后重新打开。',
          GeneratedFailure.proposalUnavailable => '该题目批次不存在或当前无法访问。',
          GeneratedFailure.persistenceFailed => '保存结果未能确认，请重新读取批次状态。',
          GeneratedFailure.invalidEdit => '该编辑不受支持，请保留题型、选项身份及顺序。',
          GeneratedFailure.corruptState => '题目批次数据无法安全读取。',
          GeneratedFailure.invalidSubmission ||
          GeneratedFailure.unsupportedContent ||
          GeneratedFailure.unsafePayload ||
          GeneratedFailure.resourceLimit ||
          GeneratedFailure.invalidEvidence ||
          GeneratedFailure.idempotencyConflict =>
            '内容未通过安全或结构检查，请检查编辑内容。',
        },
      _ => '操作暂时无法完成，请重试或重新读取状态。',
    };

String generatedDecisionLabel(GeneratedDecision decision) => switch (decision) {
      GeneratedDecision.unreviewed => '待决定',
      GeneratedDecision.accepted => '已接受',
      GeneratedDecision.rejected => '已拒绝',
      GeneratedDecision.deferred => '稍后处理',
    };

class GeneratedProposalInboxController extends ChangeNotifier {
  GeneratedProposalInboxController(this.factory);
  final GeneratedLocalAuthorityFactory factory;
  GeneratedLocalAuthoritySession? _session;
  List<GeneratedQuestionProposal> proposals = const [];
  bool isLoading = false;
  String? lastError;
  bool _disposed = false;
  bool showCompleted = false;
  Future<void> load({bool? completed}) async {
    if (isLoading || _disposed) return;
    if (completed != null) showCompleted = completed;
    isLoading = true;
    lastError = null;
    notifyListeners();
    try {
      final local = _session ?? await factory.openSession();
      if (_disposed) {
        local.close();
        return;
      }
      _session = local;
      final result = showCompleted
          ? await _session!.completed()
          : await _session!.pending();
      if (!_disposed) proposals = result;
    } catch (e) {
      if (!_disposed) lastError = generatedReviewError(e);
    } finally {
      if (!_disposed) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _session?.close();
    super.dispose();
  }
}

class GeneratedProposalReviewController extends ChangeNotifier {
  GeneratedProposalReviewController(
      {required this.proposalId, required this.factory, required this.service});
  final String proposalId;
  final GeneratedLocalAuthorityFactory factory;
  final GeneratedQuestionService service;
  GeneratedLocalAuthoritySession? session;
  GeneratedQuestionProposal? proposal;
  Map<String, List<Object?>> evidence = {};
  bool isLoading = false;
  String? lastError;
  bool disposed = false;
  int? loadedReviewRevision;
  List<GeneratedItem> workingItems = const [];
  GeneratedTarget? target;
  List<GeneratedReviewTargetChoice> targets = const [];
  final List<Map<String, Object?>> _operations = [];
  List<Map<String, Object?>> get localPendingOperations =>
      List.unmodifiable(_operations);
  bool isSaving = false;
  bool isCommitting = false;
  bool isRefreshing = false;
  bool hasConflict = false;
  GeneratedReceipt? receipt;
  bool needsVerification = false;
  GeneratedApprovalPreview? _intent;
  bool get hasPending => _operations.isNotEmpty;
  bool get busy => isLoading || isSaving || isCommitting || isRefreshing;
  bool get editable =>
      !disposed &&
      !busy &&
      !hasConflict &&
      !needsVerification &&
      receipt == null &&
      proposal?.lifecycleStatus == GeneratedStatus.pendingReview;
  bool get targetPending =>
      target != null &&
      proposal != null &&
      generatedCanonical(target!.toJson()) !=
          generatedCanonical(proposal!.target.toJson());
  String get targetLabel =>
      targets
          .where((c) =>
              generatedCanonical(c.target.toJson()) ==
              generatedCanonical(target!.toJson()))
          .map((c) => c.label)
          .firstOrNull ??
      '${target?.projectId ?? '本地'} · ${target?.bankName ?? ''}';
  void _adopt(GeneratedQuestionProposal value) {
    proposal = value;
    loadedReviewRevision = value.reviewRevision;
    workingItems = value.items;
    target = value.target;
    _operations.clear();
    hasConflict = false;
    receipt = value.commitReceipt;
  }

  Future<void> load() async {
    if (busy || hasPending || disposed) return;
    if (needsVerification) {
      await reconcile();
      return;
    }
    isLoading = true;
    lastError = null;
    notifyListeners();
    try {
      final local = session ?? await factory.openSession();
      if (disposed) {
        local.close();
        return;
      }
      session = local;
      final result = await session!.read(proposalId);
      final catalog = await session!.targets();
      final states = <String, List<Object?>>{};
      for (final item in result.items) {
        states[item.itemId] =
            await session!.evidenceState(proposalId, item.itemId);
      }
      if (!disposed) {
        _adopt(result);
        targets = catalog;
        evidence = states;
      }
    } catch (e) {
      if (!disposed) lastError = generatedReviewError(e);
    } finally {
      if (!disposed) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  int get acceptedCount => workingItems
      .where((i) => i.decision == GeneratedDecision.accepted)
      .length;
  int get rejectedCount => workingItems
      .where((i) => i.decision == GeneratedDecision.rejected)
      .length;
  bool get reviewed =>
      workingItems.isNotEmpty &&
      workingItems.every((i) =>
          i.decision == GeneratedDecision.accepted ||
          i.decision == GeneratedDecision.rejected);
  bool get canApprove =>
      editable && !hasPending && reviewed && acceptedCount > 0;
  bool get canReject =>
      editable &&
      !hasPending &&
      workingItems.isNotEmpty &&
      rejectedCount == workingItems.length;
  String get lifecycleLabel =>
      receipt == null ? proposal?.lifecycleStatus.code ?? '' : 'committed';
  Future<GeneratedApprovalPreview?> prepareTerminal(
      {bool reject = false}) async {
    if (reject ? !canReject : !canApprove) return null;
    isCommitting = true;
    lastError = null;
    notifyListeners();
    try {
      final current = await session!.read(proposalId);
      if (disposed) return null;
      if (current.lifecycleStatus != GeneratedStatus.pendingReview) {
        // Show the durable terminal result, but never create a new intent.
        _adopt(current);
        generatedFail(GeneratedFailure.terminalConflict);
      }
      if (current.reviewRevision != loadedReviewRevision) {
        // Never silently approve another window's still-pending edits.
        hasConflict = true;
        generatedFail(GeneratedFailure.staleRevision);
      }
      _adopt(current);
      if (!reviewed ||
          (reject
              ? rejectedCount != workingItems.length
              : acceptedCount == 0)) {
        generatedFail(GeneratedFailure.reviewIncomplete);
      }
      return GeneratedApprovalPreview(
          proposalId: proposalId,
          revision: current.reviewRevision,
          target: current.target,
          acceptedItemIds: [
            for (final item in current.items)
              if (item.decision == GeneratedDecision.accepted) item.itemId
          ],
          rejectedCount: rejectedCount,
          reject: reject);
    } catch (e) {
      if (!disposed) lastError = generatedReviewError(e);
      return null;
    } finally {
      if (!disposed) {
        isCommitting = false;
        notifyListeners();
      }
    }
  }

  bool _matchesReceipt(
          GeneratedReceipt value, GeneratedApprovalPreview intent) =>
      value.proposalId == intent.proposalId &&
      value.reviewRevision == intent.revision &&
      generatedCanonical(value.itemMappings.keys.toList()) ==
          generatedCanonical(intent.acceptedItemIds);
  Future<void> confirmTerminal(GeneratedApprovalPreview preview) async {
    if (busy || hasPending || needsVerification || receipt != null) return;
    if (preview.proposalId != proposalId ||
        preview.revision != loadedReviewRevision ||
        generatedCanonical(preview.target.toJson()) !=
            generatedCanonical(target!.toJson()) ||
        generatedCanonical(preview.acceptedItemIds) !=
            generatedCanonical([
              for (final item in workingItems)
                if (item.decision == GeneratedDecision.accepted) item.itemId
            ]) ||
        (preview.reject ? !canReject : !canApprove)) {
      lastError = generatedReviewError(
          const GeneratedQuestionException(GeneratedFailure.staleRevision));
      notifyListeners();
      return;
    }
    isCommitting = true;
    lastError = null;
    _intent = preview;
    notifyListeners();
    try {
      final context = session!.confirmDisplayedTarget(preview.target);
      if (preview.reject) {
        final result = await service.reject(
            RejectGeneratedProposalCommand.fromJson({
              'proposalId': proposalId,
              'expectedReviewRevision': preview.revision
            }),
            context);
        if (!disposed) {
          _adopt(result);
          needsVerification = false;
        }
      } else {
        final result = await service.approve(
            ApproveGeneratedProposalCommand.fromJson({
              'proposalId': proposalId,
              'expectedReviewRevision': preview.revision,
              'approvedItemIds': preview.acceptedItemIds
            }),
            context);
        if (!_matchesReceipt(result, preview)) {
          generatedFail(GeneratedFailure.terminalConflict);
        }
        if (!disposed) {
          receipt = result;
          needsVerification = false;
        }
      }
    } catch (e) {
      if (!disposed) {
        lastError = generatedReviewError(e);
        hasConflict = e is GeneratedQuestionException &&
            e.failure == GeneratedFailure.staleRevision;
        if (e is! GeneratedQuestionException ||
            e.failure == GeneratedFailure.persistenceFailed) {
          needsVerification = true;
          await _readTerminal();
        }
      }
    } finally {
      if (!disposed) {
        isCommitting = false;
        notifyListeners();
      }
    }
  }

  Future<void> _readTerminal() async {
    try {
      final current = await session!.read(proposalId);
      if (disposed) return;
      final intent = _intent;
      if (intent != null &&
          ((intent.reject &&
                  current.lifecycleStatus == GeneratedStatus.rejected &&
                  current.reviewRevision == intent.revision) ||
              (!intent.reject &&
                  current.commitReceipt != null &&
                  _matchesReceipt(current.commitReceipt!, intent)))) {
        _adopt(current);
        needsVerification = false;
        lastError = null;
      } else if (current.lifecycleStatus != GeneratedStatus.pendingReview) {
        _adopt(current);
        needsVerification = false;
        lastError = generatedReviewError(const GeneratedQuestionException(
            GeneratedFailure.terminalConflict));
      } else {
        lastError = '提交结果待核实。请重新核实同一批次，暂不能再次提交或编辑。';
      }
    } catch (_) {
      if (!disposed) lastError = '提交结果待核实。请重新核实同一批次，暂不能再次提交或编辑。';
    }
  }

  Future<void> reconcile() async {
    if (busy) return;
    isCommitting = true;
    notifyListeners();
    try {
      await _readTerminal();
    } finally {
      if (!disposed) {
        isCommitting = false;
        notifyListeners();
      }
    }
  }

  void _queue(Map<String, Object?> operation) {
    if (!editable) return;
    try {
      final next = [..._operations, operation];
      GeneratedReviewFlush.fromJson({
        'proposalId': proposalId,
        'expectedReviewRevision': loadedReviewRevision,
        'operations': next
      });
      var items = proposal!.items.toList();
      var nextTarget = proposal!.target;
      for (final op in next) {
        if (op['type'] == 'rebind') {
          nextTarget = GeneratedTarget.fromJson(op['target']);
          items = [
            for (final item in items)
              item.reviewed(item.working, GeneratedDecision.unreviewed, null)
          ];
          continue;
        }
        final edit = op['type'] == 'edit'
            ? Map<String, Object?>.from(op['edit'] as Map)
            : null;
        final index = items
            .indexWhere((i) => i.itemId == (edit?['itemId'] ?? op['itemId']));
        if (index < 0) generatedFail(GeneratedFailure.invalidEdit);
        final item = items[index];
        switch (op['type']) {
          case 'edit':
            items[index] = item.reviewed(
                applyGeneratedEdit(item.working, edit!),
                GeneratedDecision.unreviewed,
                item.evidenceAcknowledgement);
          case 'decide':
            items[index] = item.reviewed(
                item.working,
                GeneratedDecision.values.byName(op['decision'] as String),
                item.evidenceAcknowledgement);
          case 'acknowledge':
            items[index] = item.reviewed(item.working, item.decision,
                generatedCanonical(op['evidenceState']));
        }
      }
      _operations.add(operation);
      workingItems = items;
      target = nextTarget;
      lastError = null;
    } catch (e) {
      lastError = generatedReviewError(e);
    }
    notifyListeners();
  }

  void decide(String itemId, GeneratedDecision decision) =>
      _queue({'type': 'decide', 'itemId': itemId, 'decision': decision.name});
  void edit(Map<String, Object?> edit) =>
      _queue({'type': 'edit', 'edit': edit});
  void rebind(GeneratedTarget value) =>
      _queue({'type': 'rebind', 'target': value.toJson()});
  void acknowledge(String itemId) {
    if (targetPending || !editable) return;
    // The user is acknowledging the newly displayed state. Replace an older
    // unsaved acknowledgement so obsolete states cannot block its own batch.
    _operations.removeWhere(
        (op) => op['type'] == 'acknowledge' && op['itemId'] == itemId);
    _queue({
      'type': 'acknowledge',
      'itemId': itemId,
      'evidenceState': evidence[itemId] ?? const []
    });
  }

  Future<bool> save(GeneratedTarget confirmedTarget) async {
    if (busy || !hasPending || hasConflict) return false;
    isSaving = true;
    lastError = null;
    notifyListeners();
    try {
      if (generatedCanonical(confirmedTarget.toJson()) !=
          generatedCanonical(target!.toJson())) {
        generatedFail(GeneratedFailure.unauthorized);
      }
      final command = GeneratedReviewFlush.fromJson({
        'proposalId': proposalId,
        'expectedReviewRevision': loadedReviewRevision,
        'operations': _operations
      });
      final result = await service.flush(
          command, session!.confirmDisplayedTarget(confirmedTarget));
      if (!disposed) _adopt(result);
      return true;
    } catch (e) {
      if (!disposed) {
        lastError = generatedReviewError(e);
        hasConflict = e is GeneratedQuestionException &&
            e.failure == GeneratedFailure.staleRevision;
      }
      return false;
    } finally {
      if (!disposed) {
        isSaving = false;
        notifyListeners();
      }
    }
  }

  Future<void> discardAndReload() async {
    if (busy) return;
    _operations.clear();
    hasConflict = false;
    await load();
  }

  Future<void> refreshEvidence() async {
    if (busy || proposal == null) return;
    isRefreshing = true;
    notifyListeners();
    try {
      final states = <String, List<Object?>>{};
      for (final item in proposal!.items) {
        states[item.itemId] =
            await session!.evidenceState(proposalId, item.itemId);
      }
      if (!disposed) {
        evidence = states;
        lastError = null;
      }
    } catch (e) {
      if (!disposed) lastError = generatedReviewError(e);
    } finally {
      if (!disposed) {
        isRefreshing = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    disposed = true;
    session?.close();
    super.dispose();
  }
}

final class GeneratedApprovalPreview {
  GeneratedApprovalPreview(
      {required this.proposalId,
      required this.revision,
      required this.target,
      required Iterable<String> acceptedItemIds,
      required this.rejectedCount,
      required this.reject})
      : acceptedItemIds = List.unmodifiable(acceptedItemIds);
  final String proposalId;
  final int revision, rejectedCount;
  final GeneratedTarget target;
  final List<String> acceptedItemIds;
  final bool reject;
}
