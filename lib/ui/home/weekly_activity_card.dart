import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../application/home_training_result.dart';
import '../../application/study_activity/study_activity_contracts.dart';
import '../theme/design_tokens.dart';
import 'today_visual_theme.dart';

class WeeklyActivityCard extends StatelessWidget {
  const WeeklyActivityCard(
      {super.key,
      required this.result,
      required this.loading,
      required this.todayLocalDate});
  final HomeTrainingResult<StudyActivityWeekSnapshot>? result;
  final bool loading;
  final String todayLocalDate;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final week = switch (result) {
      HomeTrainingSuccess(:final value) => value,
      _ => null,
    };
    final duration = week?.totalDurationMs;
    final durationText = duration == null
        ? '暂不可用'
        : duration > 0 && duration < 60000
            ? '小于 1 分钟'
            : duration >= 3600000
                ? '${(duration / 3600000).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')} 小时'
                : '${duration ~/ 60000} 分钟';
    final summary = Row(children: [
      const TodayIconTile(Icons.calendar_today_rounded, size: 32, iconSize: 22),
      const SizedBox(width: 8),
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('学习日历',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
            loading
                ? '加载本周学习记录…'
                : week == null
                    ? '本周学习记录暂不可用'
                    : '本周学习 ${week.learningDayCount} 天 · $durationText',
            style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant)),
      ])),
    ]);
    final maxDuration = week?.days
            .where((day) => day.localDate.compareTo(todayLocalDate) <= 0)
            .fold<int>(1, (value, day) => math.max(value, day.durationMs)) ??
        1;
    final chart = Row(children: [
      if (week != null)
        for (var i = 0; i < 7; i++)
          Expanded(
              child: Semantics(
            label:
                '${week.days[i].localDate} ${week.days[i].localDate.compareTo(todayLocalDate) > 0 ? '未来日期' : week.days[i].durationMs > 0 ? '已学习' : '未记录学习'}',
            child: Column(children: [
              Text(const ['一', '二', '三', '四', '五', '六', '日'][i],
                  style:
                      TextStyle(fontSize: 9, color: colors.onSurfaceVariant)),
              const SizedBox(height: 4),
              Container(
                width: 8,
                height: 28,
                decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8)),
                alignment: Alignment.bottomCenter,
                child: week.days[i].localDate.compareTo(todayLocalDate) <= 0 &&
                        week.days[i].durationMs > 0
                    ? Container(
                        key: ValueKey('home-week-bar-$i'),
                        width: 8,
                        height: math.max(
                            4, 28 * week.days[i].durationMs / maxDuration),
                        decoration: BoxDecoration(
                            color: colors.onSurfaceVariant,
                            borderRadius: BorderRadius.circular(8)))
                    : null,
              ),
            ]),
          )),
    ]);
    return Container(
      key: const ValueKey('home-learning-activity'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(14),
          boxShadow: DesignTokens.surfaceShadow(Theme.of(context).brightness)),
      child: LayoutBuilder(builder: (context, constraints) {
        final stacked = MediaQuery.textScalerOf(context).scale(14) > 18;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (loading || week == null)
            summary
          else if (stacked) ...[summary, const SizedBox(height: 12), chart] else
            Row(children: [
              Expanded(flex: 3, child: summary),
              const SizedBox(width: 10),
              Expanded(flex: 2, child: chart)
            ]),
          if (!loading &&
              week?.recordingQuality == StudyActivityRecordingQuality.partial)
            const Padding(
                padding: EdgeInsets.only(top: 8), child: Text('记录可能不完整')),
        ]);
      }),
    );
  }
}
