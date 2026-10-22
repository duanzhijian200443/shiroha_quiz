import 'package:flutter/material.dart';
import '../../application/modules/assistant_artifact_contributions.dart';
import '../../application/safe_write/agent_write_proposal.dart';
import '../../domain/study_plan/study_plan_values.dart';
import 'assistant_artifact_controller.dart';

/// Finite module-owned presenters in the retained Assistant artifact slot.
/// No generic approval action, widget registry or additional state owner.
class AssistantArtifactCards extends StatelessWidget {
  const AssistantArtifactCards({super.key, required this.controller});
  final AssistantArtifactController controller;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (controller.presents(missingAnswerArtifactUi.key) &&
            controller.hasProposalCard) ...[
          const SizedBox(height: 12),
          _ProposalCard(controller: controller),
        ],
        if (controller.presents(studyPlanArtifactUi.key) &&
            controller.hasStudyPlanCard) ...[
          const SizedBox(height: 12),
          _StudyPlanProposalCard(controller: controller),
        ],
      ]);
}

/// W0 proposal approval card rendered from the typed staged-event preview.
/// Approve submits only the proposal identity; Reject performs zero writes.
class _ProposalCard extends StatelessWidget {
  const _ProposalCard({required this.controller});

  final AssistantArtifactController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = controller.proposalPreview;
    final bankName = preview['bank_name'];
    final stem = _proposalNodesText(preview['stem']);
    final options = _proposalOptions(preview['options']);
    final answer = _proposalAnswerText(preview['proposed_answer']);
    final status = controller.proposalStatusText;
    final actionMessage = controller.proposalActionMessage;

    return Card(
      key: const ValueKey<String>('w0-proposal-card'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Agent \u63d0\u8bae\u8865\u5168\u7b54\u6848',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (bankName is String && bankName.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('\u9898\u5e93\uff1a$bankName'),
            ],
            if (stem.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(stem),
            ],
            for (final option in options) ...[
              const SizedBox(height: 4),
              Text('${option.$1}. ${option.$2}'),
            ],
            const SizedBox(height: 8),
            const Text('\u5f53\u524d\u7b54\u6848\uff1a\u672a\u586b\u5199'),
            const SizedBox(height: 4),
            Text('\u62df\u5199\u5165\u7b54\u6848\uff1a$answer'),
            const Divider(height: 16),
            Text(
              '\u53ea\u4fee\u6539\u7b54\u6848\uff0c\u590d\u4e60\u72b6\u6001'
              '\u4e0d\u53d8',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (status != null) ...[
              const SizedBox(height: 8),
              Text(
                status,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (actionMessage != null) ...[
              const SizedBox(height: 6),
              Text(
                actionMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (controller.proposalOutcome ==
                AgentWriteProposalOutcome.pending) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  OutlinedButton(
                    key: const ValueKey<String>('w0-proposal-reject'),
                    onPressed: controller.canRejectProposal
                        ? controller
                            .bindProposalAction(controller.rejectProposal)
                        : null,
                    child: const Text('\u62d2\u7edd'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey<String>('w0-proposal-approve'),
                    onPressed: controller.canApproveProposal
                        ? controller
                            .bindProposalAction(controller.approveProposal)
                        : null,
                    child: const Text('\u6279\u51c6\u5e76\u5199\u5165'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Projects the structured tool-contract node list into bounded display
/// text. Unsupported nodes render as a fixed placeholder.
String _proposalNodesText(Object? rawNodes) {
  if (rawNodes is! List) return '';
  final buffer = StringBuffer();
  for (final item in rawNodes) {
    if (item is! Map) continue;
    switch (item['type']) {
      case 'text':
        final text = item['text'];
        if (text is String) buffer.write(text);
      case 'inline_math':
        final latex = item['latex'];
        if (latex is String) buffer.write('\\($latex\\)');
      case 'block_math':
        final latex = item['latex'];
        if (latex is String) buffer.write('\\[$latex\\]');
      default:
        buffer.write('[Unsupported content]');
    }
  }
  return buffer.toString();
}

/// Parses the preview `options` list into (label, projected content) pairs.
List<(String, String)> _proposalOptions(Object? rawOptions) {
  if (rawOptions is! List) return const <(String, String)>[];
  final options = <(String, String)>[];
  for (final item in rawOptions) {
    if (item is! Map) continue;
    final label = item['label'];
    if (label is! String) continue;
    options.add((label, _proposalNodesText(item['content'])));
  }
  return options;
}

/// Projects the preview `proposed_answer` into bounded display text.
String _proposalAnswerText(Object? rawAnswer) {
  if (rawAnswer is! Map) return '';
  return switch (rawAnswer['kind']) {
    'choice' => _proposalLabelsText(rawAnswer['labels']),
    'content' => _proposalNodesText(rawAnswer['nodes']),
    _ => '',
  };
}

String _proposalLabelsText(Object? rawLabels) {
  if (rawLabels is! List) return '';
  return rawLabels.whereType<String>().join(', ');
}

/// Replacement confirmation text bound to the exact observed active plan.
/// Shows only Application-owned plan data (bank name, optional goal); never
/// provider/model identity.
String _replacementConfirmationText({
  String? currentBankName,
  String? currentGoal,
}) {
  final hasBank = currentBankName != null && currentBankName.isNotEmpty;
  final hasGoal = currentGoal != null && currentGoal.isNotEmpty;
  final buffer = StringBuffer('当前已有学习计划');
  if (hasBank || hasGoal) {
    buffer.write('（');
    if (hasBank) {
      buffer.write('题库：');
      buffer.write(currentBankName);
    }
    if (hasBank && hasGoal) buffer.write('，');
    if (hasGoal) {
      buffer.write('目标：');
      buffer.write(currentGoal);
    }
    buffer.write('）');
  }
  buffer.write('。采用此草案将替换现有计划，确定要替换吗？');
  return buffer.toString();
}

/// SPL-1 StudyPlan proposal card rendered from the typed staged-event preview.
/// Adopt calls StudyPlanCommandService (with replacement confirmation if
/// needed); Reject performs zero durable writes.
class _StudyPlanProposalCard extends StatelessWidget {
  const _StudyPlanProposalCard({required this.controller});

  final AssistantArtifactController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final preview = controller.studyPlanPreview;
    final bankName = preview['bank_name']?.toString() ?? '';
    final goal = preview['goal']?.toString();
    final dailyTarget = preview['daily_target'];
    final priorityCode = preview['priority']?.toString();
    final horizonDays = preview['horizon_days'];
    final questionCount = preview['question_count'];
    final masteredCount = preview['mastered_count'];
    final dueCount = preview['due_count'];
    final weakCount = preview['weak_count'];
    final newCount = preview['new_count'];
    final estimatedDays = preview['estimated_days'];
    final status = controller.studyPlanStatusText;
    final actionMessage = controller.studyPlanActionMessage;
    // Exact observed ActiveStudyPlan used as the replacement CAS baseline.
    final currentPlan = controller.pendingReplacementActivePlan;
    final currentBankName = currentPlan?.bankName;
    final currentGoal = currentPlan?.goal;

    return Card(
      key: const ValueKey<String>('study-plan-draft-card'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: [
                Icon(Icons.event_note_outlined,
                    size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  '学习计划草案',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (bankName.isNotEmpty) Text('题库：$bankName'),
            if (goal != null && goal.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('目标：$goal'),
            ],
            if (dailyTarget != null) ...[
              const SizedBox(height: 4),
              Text('每日特训量：$dailyTarget 题'),
            ],
            if (priorityCode != null) ...[
              const SizedBox(height: 4),
              Text('优先策略：${_priorityLabel(priorityCode)}'),
            ],
            if (horizonDays != null) ...[
              const SizedBox(height: 4),
              Text('计划周期：$horizonDays 天'),
            ],
            if (questionCount != null) ...[
              const SizedBox(height: 6),
              Text(
                '题库概况：共 $questionCount 题 · '
                '已掌握 ${masteredCount ?? 0} · '
                '待复习 ${dueCount ?? 0} · '
                '薄弱 ${weakCount ?? 0} · 新题 ${newCount ?? 0}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            if (estimatedDays != null) ...[
              const SizedBox(height: 4),
              Text(
                '预计约 $estimatedDays 天完成',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '采用此计划不会修改 FSRS / '
              '现有复习记录。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.outline,
                fontStyle: FontStyle.italic,
              ),
            ),
            if (status != null) ...[
              const SizedBox(height: 8),
              Text(
                status,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            if (actionMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                actionMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.error,
                ),
              ),
            ],
            if (controller.showReplacementConfirmation) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.errorContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colors.error.withValues(alpha: 0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _replacementConfirmationText(
                        currentBankName: currentBankName,
                        currentGoal: currentGoal,
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          key: const ValueKey<String>(
                            'study-plan-cancel-replace',
                          ),
                          onPressed: controller.bindReplacementAction(
                              controller.cancelReplacement),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          key: const ValueKey<String>(
                            'study-plan-confirm-replace',
                          ),
                          onPressed: controller.canAdoptStudyPlan
                              ? controller.bindReplacementAction(
                                  controller.confirmReplacement)
                              : null,
                          child: const Text('确认替换'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ] else if (controller.studyPlanOutcome ==
                StudyPlanDraftOutcome.pending) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  OutlinedButton(
                    key: const ValueKey<String>('study-plan-draft-reject'),
                    onPressed: controller.canRejectStudyPlan
                        ? controller
                            .bindStudyPlanAction(controller.rejectStudyPlan)
                        : null,
                    child: const Text('不采用'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey<String>('study-plan-draft-adopt'),
                    onPressed: controller.canAdoptStudyPlan
                        ? controller.bindStudyPlanAction(
                            controller.initiateAdoptStudyPlan)
                        : null,
                    child: const Text('采用计划'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _priorityLabel(String code) {
    return switch (code) {
      'balanced' => '均衡',
      'due_first' => '到期复习优先',
      'weak_first' => '薄弱题优先',
      'new_first' => '新题优先',
      _ => code,
    };
  }
}
