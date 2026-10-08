import 'package:flutter/material.dart';
import '../../application/modules/module_composition.dart';
import '../../domain/generated_question/generated_question_contract.dart';
import '../dependencies/generated_question_dependencies_scope.dart';
import 'generated_proposal_controllers.dart';
import 'generated_proposal_review_screen.dart';

class GeneratedProposalWorkspaceAction extends StatelessWidget {
  const GeneratedProposalWorkspaceAction({super.key});
  @override
  Widget build(BuildContext context) {
    final scope = GeneratedQuestionDependenciesScope.maybeOf(context);
    if (scope == null ||
        !scope.contributions.any((c) =>
            c.slot == ModuleUiSlot.workspaceAction &&
            c.key == 'generated_proposal_review')) {
      return const SizedBox.shrink();
    }
    return IconButton(
        key: const ValueKey('generated_proposal_review'),
        tooltip: '待审核题目',
        icon: const Icon(Icons.fact_check_outlined),
        onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(
            builder: (_) =>
                GeneratedProposalInboxScreen(dependencies: scope))));
  }
}

class GeneratedProposalInboxScreen extends StatefulWidget {
  const GeneratedProposalInboxScreen({super.key, required this.dependencies});
  final GeneratedQuestionDependenciesScope dependencies;
  @override
  State<GeneratedProposalInboxScreen> createState() =>
      _GeneratedProposalInboxScreenState();
}

class _GeneratedProposalInboxScreenState
    extends State<GeneratedProposalInboxScreen> {
  late final controller =
      GeneratedProposalInboxController(widget.dependencies.authority)..load();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _open(String id) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => GeneratedProposalReviewScreen(
            proposalId: id, dependencies: widget.dependencies)));
    if (mounted) await controller.load();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
          appBar: AppBar(title: const Text('待审核题目'), actions: [
            IconButton(
                tooltip: '刷新列表',
                onPressed: controller.isLoading ? null : controller.load,
                icon: const Icon(Icons.refresh))
          ]),
          body: controller.isLoading
              ? const Center(child: CircularProgressIndicator())
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            Wrap(spacing: 8, children: [
                              ChoiceChip(
                                  label: const Text('待审核'),
                                  selected: !controller.showCompleted,
                                  onSelected: controller.isLoading
                                      ? null
                                      : (_) =>
                                          controller.load(completed: false)),
                              ChoiceChip(
                                  key: const ValueKey('generated-completed'),
                                  label: const Text('已完成'),
                                  selected: controller.showCompleted,
                                  onSelected: controller.isLoading
                                      ? null
                                      : (_) => controller.load(completed: true))
                            ]),
                            if (controller.lastError != null)
                              Text(controller.lastError!,
                                  key: const ValueKey('generated-error'))
                            else if (controller.proposals.isEmpty)
                              Padding(
                                  padding: const EdgeInsets.all(32),
                                  child: Text(
                                      controller.showCompleted
                                          ? '暂无已完成题目批次'
                                          : '暂无待审核题目',
                                      key: ValueKey('generated-empty'))),
                            for (final proposal in controller.proposals)
                              Card(
                                  child: ListTile(
                                      key: ValueKey(
                                          'generated-proposal-${proposal.proposalId}'),
                                      isThreeLine: true,
                                      title: Text(
                                          '题目批次 · ${proposal.proposalId.substring(0, 8)}'),
                                      subtitle: Text(
                                          '${DateTime.fromMillisecondsSinceEpoch(proposal.createdAtUtcMs).toLocal()} · 来源 ${proposal.originKind}\n'
                                          '学习空间 ${proposal.target.projectId ?? '本地'} · 题库 ${proposal.target.bankName}\n'
                                          '${proposal.actualCount} 题 · 接受 ${proposal.items.where((i) => i.decision == GeneratedDecision.accepted).length} · '
                                          '拒绝 ${proposal.items.where((i) => i.decision == GeneratedDecision.rejected).length} · '
                                          '待决定 ${proposal.items.where((i) => i.decision != GeneratedDecision.accepted && i.decision != GeneratedDecision.rejected).length} · ${proposal.lifecycleStatus.code}'),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => _open(proposal.proposalId))),
                          ])))));
}
