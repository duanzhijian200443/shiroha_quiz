import 'package:flutter/material.dart';
import '../../application/home_training_result.dart';
import '../../application/study_activity/study_activity_contracts.dart';

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
      _ => null
    };
    final duration = week?.totalDurationMs;
    final durationText = duration == null
        ? '暂不可用'
        : duration > 0 && duration < 60000
            ? '小于 1 分钟'
            : '${duration ~/ 60000} 分钟';
    return Card(
        key: const ValueKey('home-learning-activity'),
        elevation: 0,
        child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('学习日历', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(loading
                  ? '加载本周学习记录…'
                  : week == null
                      ? '本周学习记录暂不可用'
                      : '本周学习 ${week.learningDayCount} 天 · $durationText'),
              if (!loading && week != null) ...[
                const SizedBox(height: 12),
                Row(children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                        child: Semantics(
                            label:
                                '${week.days[i].localDate} ${week.days[i].localDate.compareTo(todayLocalDate) > 0 ? '未来日期' : week.days[i].durationMs > 0 ? '已学习' : '未记录学习'}',
                            child: Column(children: [
                              Text(
                                  const ['一', '二', '三', '四', '五', '六', '日'][i]),
                              const SizedBox(height: 4),
                              Icon(
                                  week.days[i].localDate
                                                  .compareTo(todayLocalDate) <=
                                              0 &&
                                          week.days[i].durationMs > 0
                                      ? Icons.check_circle
                                      : Icons.circle_outlined,
                                  size: 18,
                                  color: colors.onSurfaceVariant),
                            ])))
                ]),
                if (week.recordingQuality ==
                    StudyActivityRecordingQuality.partial)
                  const Padding(
                      padding: EdgeInsets.only(top: 8), child: Text('记录可能不完整')),
              ],
            ])));
  }
}
