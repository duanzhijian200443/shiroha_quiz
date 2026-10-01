import 'package:flutter/material.dart';
import '../../application/study_plan/study_plan_selection_service.dart';
import '../../domain/study_plan/active_study_plan.dart';
import '../../domain/study_plan/study_plan_values.dart';
import '../theme/design_tokens.dart';

/// One real plan, shared by Today and the lightweight current-plan detail.
class TodayPlanCard extends StatelessWidget {
  const TodayPlanCard(
      {super.key,
      required this.state,
      this.detailed = false,
      this.onOpen,
      this.onAskAssistant,
      this.onRetry,
      this.onStart,
      this.onStop});
  final StudyPlanFocusedState? state;
  final bool detailed;
  final VoidCallback? onOpen;
  final VoidCallback? onAskAssistant;
  final VoidCallback? onRetry;
  final VoidCallback? onStart;
  final ValueChanged<ActiveStudyPlan>? onStop;

  @override
  Widget build(BuildContext context) {
    final plan = switch (state) {
      StudyPlanFocusedReady(:final activePlan) => activePlan,
      StudyPlanFocusedNoCandidates(:final activePlan) => activePlan,
      StudyPlanFocusedPlanUnavailable(:final activePlan) => activePlan,
      _ => null,
    };
    final status = switch (state) {
      null => '正在加载计划…',
      StudyPlanFocusedNoActivePlan() => '尚未采用学习计划',
      StudyPlanFocusedReady(:final selectedStorageIds) =>
        '今日可特训：${selectedStorageIds.length} 题',
      StudyPlanFocusedNoCandidates() => '今日暂无任务',
      StudyPlanFocusedPlanUnavailable() => '当前计划题库已不可用',
      StudyPlanFocusedFailure() => '暂时无法加载计划',
    };
    final advisory = switch (state) {
      StudyPlanFocusedReady(:final advisory) => advisory,
      StudyPlanFocusedNoCandidates(:final advisory) => advisory,
      _ => null,
    };
    final colors = Theme.of(context).colorScheme;
    if (!detailed) {
      return Container(
        key: ValueKey(plan == null
            ? 'today-focused-unavailable'
            : 'today-focused-plan-card'),
        decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(14),
            boxShadow:
                DesignTokens.surfaceShadow(Theme.of(context).brightness)),
        child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(plan == null ? '学习计划' : '${plan.bankName} · 训练计划',
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 14),
                        Row(children: [
                          Icon(Icons.calendar_today_outlined,
                              size: 14, color: colors.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(
                              child: Text(status,
                                  key: const ValueKey('today-focused-status'),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: colors.onSurfaceVariant))),
                          Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                  color: colors.surfaceContainerHighest,
                                  shape: BoxShape.circle),
                              child: Icon(Icons.chevron_right_rounded,
                                  size: 17, color: colors.onSurfaceVariant)),
                        ]),
                        if (state is StudyPlanFocusedNoActivePlan)
                          TextButton(
                              key: const ValueKey('home-ask-assistant'),
                              onPressed: onAskAssistant,
                              child: const Text('去助手制定计划')),
                        if (state is StudyPlanFocusedFailure)
                          TextButton(
                              onPressed: onRetry, child: const Text('重试')),
                      ])),
            )),
      );
    }
    return Card(
      key: ValueKey(plan == null
          ? 'today-focused-unavailable'
          : 'today-focused-plan-card'),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.cardRadius)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: detailed ? null : onOpen,
        child: Padding(
          padding: const EdgeInsets.all(DesignTokens.cardInternalPadding),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.flag_outlined, color: colors.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(plan == null ? '学习计划' : '${plan.bankName} · 训练计划',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700))),
              if (!detailed && plan != null)
                const Icon(Icons.chevron_right_rounded),
            ]),
            const SizedBox(height: 12),
            Text(status,
                key: const ValueKey('today-focused-status'),
                style: TextStyle(color: colors.onSurfaceVariant)),
            if (state is StudyPlanFocusedNoActivePlan) ...[
              const SizedBox(height: 8),
              TextButton(
                  key: const ValueKey('home-ask-assistant'),
                  onPressed: onAskAssistant,
                  child: const Text('去助手制定计划')),
            ],
            if (state is StudyPlanFocusedFailure)
              TextButton(onPressed: onRetry, child: const Text('重试')),
            if (detailed && plan != null) ...[
              const SizedBox(height: 16),
              _info(context, '题库', plan.bankName),
              if (plan.goal != null) _info(context, '目标', plan.goal!),
              _info(context, '每日特训量', '${plan.dailyTarget} 题'),
              _info(
                  context,
                  '优先级',
                  switch (plan.priority) {
                    StudyPlanPriority.balanced => '均衡',
                    StudyPlanPriority.dueFirst => '到期优先',
                    StudyPlanPriority.weakFirst => '薄弱优先',
                    StudyPlanPriority.newFirst => '新题优先',
                  }),
              if (plan.horizonDays != null)
                _info(context, '期限', '${plan.horizonDays} 天'),
              if (advisory?.masteryReached == true ||
                  advisory?.horizonElapsed == true)
                Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Wrap(spacing: 8, runSpacing: 8, children: [
                      if (advisory!.masteryReached)
                        const Chip(label: Text('已掌握全部题目')),
                      if (advisory.horizonElapsed)
                        const Chip(label: Text('计划期已结束')),
                    ])),
              const SizedBox(height: 16),
              SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                      key: const ValueKey('today-focused-start'),
                      onPressed: state is StudyPlanFocusedPlanUnavailable
                          ? null
                          : onStart,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('开始特训'))),
              TextButton(
                  key: const ValueKey('today-focused-stop'),
                  onPressed: onStop == null ? null : () => onStop!(plan),
                  child: const Text('停止计划')),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _info(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      );
}
