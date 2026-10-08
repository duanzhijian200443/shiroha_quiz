import 'package:flutter/material.dart';
import '../../domain/generated_question/generated_question_contract.dart';
import '../dependencies/generated_question_dependencies_scope.dart';
import 'generated_proposal_controllers.dart';
import 'generated_proposal_question_card.dart';
import 'generated_typed_question_editor.dart';

class GeneratedProposalReviewScreen extends StatefulWidget {
  const GeneratedProposalReviewScreen(
      {super.key, required this.proposalId, required this.dependencies});
  final String proposalId;
  final GeneratedQuestionDependenciesScope dependencies;
  @override
  State<GeneratedProposalReviewScreen> createState() =>
      _GeneratedProposalReviewScreenState();
}

class _GeneratedProposalReviewScreenState
    extends State<GeneratedProposalReviewScreen> {
  late final controller = GeneratedProposalReviewController(
      proposalId: widget.proposalId,
      factory: widget.dependencies.authority,
      service: widget.dependencies.service)
    ..load();
  bool allowExit = false;
  bool exitDialog = false;
  bool terminalDialog = false;
  bool receiptNotified = false;
  final scroll = ScrollController();
  void publishReceipt() {
    if (controller.receipt != null && !receiptNotified) {
      receiptNotified = true;
      if (scroll.hasClients) scroll.jumpTo(0);
      widget.dependencies.onCommitted?.call();
    }
  }

  Future<void> reconcile() async {
    await controller.reconcile();
    if (mounted) publishReceipt();
  }

  Future<void> terminal({bool reject = false}) async {
    if (terminalDialog || controller.busy) return;
    setState(() => terminalDialog = true);
    try {
      final preview = await controller.prepareTerminal(reject: reject);
      if (preview == null || !mounted) return;
      final confirmed = await _confirm(
          reject ? '拒绝整个批次？' : '正式批准入库？',
          '目标题库：${preview.target.bankName}\n学习空间：${controller.targetLabel}\n'
          '正式入库：${preview.acceptedItemIds.length} 题\n已拒绝：${preview.rejectedCount} 题\n审核版本：${preview.revision}');
      if (confirmed && mounted) {
        await controller.confirmTerminal(preview);
        if (mounted) publishReceipt();
      }
    } finally {
      if (mounted) setState(() => terminalDialog = false);
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    controller.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String title, String description) async {
    var answered = false;
    void answer(BuildContext dialog, bool value) {
      if (answered) return;
      answered = true;
      Navigator.pop(dialog, value);
    }

    return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: Text(title),
                    content: Text(description),
                    actions: [
                      TextButton(
                          onPressed: () => answer(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          key: const ValueKey('generated-confirm'),
                          onPressed: () => answer(context, true),
                          child: const Text('确认'))
                    ])) ==
        true;
  }

  Future<bool> save() async {
    final target = controller.target;
    if (target == null || controller.busy || !controller.hasPending) {
      return false;
    }
    if (!await _confirm('保存审核修改？',
        '目标：${controller.targetLabel}\n审核版本：${controller.loadedReviewRevision}\n这会保存工作副本，不会正式入库。')) {
      return false;
    }
    return controller.save(target);
  }

  Future<void> reload() async {
    if (controller.busy) return;
    if (controller.hasPending &&
        !await _confirm('重新加载审核？',
            '本地 ${controller.localPendingOperations.length} 个未保存操作将被明确放弃。其他窗口的已保存修改会重新读取。')) {
      return;
    }
    await controller.discardAndReload();
  }

  Future<void> exit() async {
    if (controller.busy || exitDialog) return;
    exitDialog = true;
    try {
      var leave = true;
      if (controller.hasPending) {
        final action = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('存在未保存审核修改'),
                    content: const Text('保存工作副本或明确放弃后返回。返回不会批准或拒绝批次。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, 'stay'),
                          child: const Text('继续审核')),
                      TextButton(
                          key: const ValueKey('generated-discard-exit'),
                          onPressed: () => Navigator.pop(context, 'discard'),
                          child: const Text('放弃并返回')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, 'save'),
                          child: const Text('保存并返回'))
                    ]));
        leave = action == 'discard' || (action == 'save' && await save());
      }
      if (leave && mounted) {
        setState(() => allowExit = true);
        Navigator.pop(context);
      }
    } finally {
      exitDialog = false;
    }
  }

  Future<void> edit(GeneratedItem item) async {
    final changes = await Navigator.of(context)
        .push<List<Map<String, Object?>>>(MaterialPageRoute(
            builder: (_) => GeneratedTypedQuestionEditor(item: item)));
    if (!mounted || changes == null) return;
    for (final change in changes) {
      controller.edit(change);
    }
  }

  Future<void> rebind() async {
    if (controller.busy) return;
    try {
      final choices = await controller.session!.targets();
      if (!mounted) return;
      final selected = await showDialog<int>(
          context: context,
          builder: (context) =>
              SimpleDialog(title: const Text('选择新的审核目标'), children: [
                if (choices.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(16), child: Text('暂无现有题库')),
                for (var i = 0; i < choices.length; i++)
                  SimpleDialogOption(
                      key: ValueKey('generated-target-$i'),
                      onPressed: () => Navigator.pop(context, i),
                      child: Text(choices[i].label))
              ]));
      if (selected == null || !mounted) return;
      if (await _confirm('确认重新绑定？',
          '新目标：${choices[selected].label}\n全部题目的审核决定和来源确认将重置，必须重新审核。')) {
        controller.rebind(choices[selected].target);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(generatedReviewError(e))));
      }
    }
  }

  Future<void> acknowledge(GeneratedItem item) async {
    final states = controller.evidence[item.itemId] ?? const [];
    if (await _confirm('明确确认来源变化？',
        '${states.map((s) => '${(s as Map)['evidenceKey']}：${s['status']}').join('\n')}\n原始来源会保留，正式入库时仍会重新校验。')) {
      controller.acknowledge(item.itemId);
    }
  }

  Widget actions(GeneratedItem item) =>
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final decision in [
          GeneratedDecision.accepted,
          GeneratedDecision.rejected,
          GeneratedDecision.deferred
        ])
          OutlinedButton(
              key: ValueKey('generated-${decision.name}-${item.itemId}'),
              onPressed: controller.editable
                  ? () => controller.decide(item.itemId, decision)
                  : null,
              child: Text(switch (decision) {
                GeneratedDecision.accepted => '接受',
                GeneratedDecision.rejected => '拒绝',
                _ => '稍后处理'
              })),
        TextButton(
            key: ValueKey('generated-edit-${item.itemId}'),
            onPressed: controller.editable ? () => edit(item) : null,
            child: const Text('编辑')),
        if ((controller.evidence[item.itemId] ?? [])
            .any((s) => (s as Map)['status'] != 'authorized'))
          TextButton(
              key: ValueKey('generated-ack-${item.itemId}'),
              onPressed: controller.editable && !controller.targetPending
                  ? () => acknowledge(item)
                  : null,
              child: const Text('确认来源变化')),
        if (item.evidenceAcknowledgement != null) const Text('已明确确认来源状态'),
      ]);
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => PopScope(
          canPop: allowExit || (!controller.hasPending && !controller.busy),
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) exit();
          },
          child: Scaffold(
              appBar: AppBar(title: const Text('题目审核'), actions: [
                IconButton(
                    tooltip: '重新加载',
                    key: const ValueKey('generated-reload'),
                    onPressed: controller.busy ? null : reload,
                    icon: const Icon(Icons.refresh))
              ]),
              body: controller.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 900),
                          child: ListView(
                              controller: scroll,
                              padding: const EdgeInsets.all(16),
                              children: [
                                if (controller.lastError != null)
                                  Text(controller.lastError!,
                                      key: const ValueKey('generated-error')),
                                if (controller.proposal
                                    case final proposal?) ...[
                                  Text(
                                      '来源：${proposal.originKind} · ${proposal.clientProfileId}'),
                                  Text(
                                      '目标：${controller.targetLabel}\n文件夹：${controller.target?.folderName ?? '未分类'}'),
                                  Text(
                                      '请求 ${proposal.requestedCount} 题 · 实际 ${proposal.actualCount} 题 · 审核版本 ${controller.loadedReviewRevision}'),
                                  Text('状态：${controller.lifecycleLabel}'),
                                  if (controller.receipt
                                      case final receipt?) ...[
                                    Text(
                                        '已正式入库 ${receipt.itemMappings.length} 题',
                                        key: const ValueKey(
                                            'generated-receipt')),
                                    Text(
                                        '入库凭据 · 批次 ${receipt.proposalId}\n审核版本 ${receipt.reviewRevision}'),
                                    for (final entry
                                        in receipt.itemMappings.entries)
                                      Text('题目 ${entry.key} → ${entry.value}'),
                                  ],
                                  if (proposal.countMismatchWarning)
                                    const Text('实际题目数量与请求数量不同'),
                                  if (controller.targetPending)
                                    const Text('新目标尚未保存；保存后重新审核并刷新来源状态。'),
                                  Wrap(spacing: 8, children: [
                                    TextButton(
                                        key: const ValueKey('generated-rebind'),
                                        onPressed:
                                            controller.editable ? rebind : null,
                                        child: const Text('重新绑定目标')),
                                    TextButton(
                                        key: const ValueKey(
                                            'generated-refresh-evidence'),
                                        onPressed: controller.busy ||
                                                controller.targetPending
                                            ? null
                                            : controller.refreshEvidence,
                                        child: const Text('刷新来源状态'))
                                  ]),
                                  for (final item in controller.workingItems)
                                    GeneratedProposalQuestionCard(
                                        item: item,
                                        evidenceState:
                                            controller.evidence[item.itemId] ??
                                                const [],
                                        actions: actions(item)),
                                ],
                              ]))),
              bottomNavigationBar: SafeArea(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(controller.busy
                                ? '正在处理…'
                                : '未保存操作：${controller.localPendingOperations.length}'),
                            FilledButton(
                                key: const ValueKey('generated-save'),
                                onPressed:
                                    controller.editable && controller.hasPending
                                        ? save
                                        : null,
                                child: const Text('保存审核')),
                            FilledButton(
                                key: const ValueKey('generated-approve'),
                                onPressed:
                                    controller.canApprove && !terminalDialog
                                        ? () => terminal()
                                        : null,
                                child: const Text('正式批准入库')),
                            OutlinedButton(
                                key:
                                    const ValueKey('generated-reject-proposal'),
                                onPressed:
                                    controller.canReject && !terminalDialog
                                        ? () => terminal(reject: true)
                                        : null,
                                child: const Text('拒绝整个批次')),
                            if (controller.needsVerification)
                              OutlinedButton(
                                  key: const ValueKey('generated-reconcile'),
                                  onPressed: controller.busy ? null : reconcile,
                                  child: const Text('核实提交结果')),
                          ]))))));
}
