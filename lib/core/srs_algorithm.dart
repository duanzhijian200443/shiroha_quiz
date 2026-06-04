class SRSAlgorithm {
  // grade: 0(遗忘), 1(困难), 2(顺利), 3(极易)
  static Map<String, dynamic> calculateNextState(
    int grade,
    Map<String, dynamic> currentState,
  ) {
    int reps = (currentState['reps'] as num?)?.toInt() ?? 0;
    double easeFactor =
        (currentState['ease_factor'] as num?)?.toDouble() ?? 2.5;
    int intervalMs = (currentState['interval_ms'] as num?)?.toInt() ?? 0;
    int lapseCount = (currentState['lapse_count'] as num?)?.toInt() ?? 0;

    final int nowMs = DateTime.now().millisecondsSinceEpoch;

    if (grade == 0) {
      reps = 0;
      intervalMs = 600000; // 遗忘：10分钟后重现
      easeFactor = (easeFactor - 0.2).clamp(1.3, 3.5);
      lapseCount += 1;
    } else {
      if (reps == 0) {
        intervalMs = 86400000; // 第一次记住，明天复习 (1天)
      } else if (reps == 1) {
        intervalMs = 518400000; // 第二次记住，6天后
      } else {
        double gradeMultiplier = grade == 1 ? 0.8 : (grade == 3 ? 1.3 : 1.0);
        intervalMs = (intervalMs * easeFactor * gradeMultiplier).round();
      }
      reps += 1;
      easeFactor =
          (easeFactor + (0.1 - (3 - grade) * (0.08 + (3 - grade) * 0.02)))
              .clamp(1.3, 3.5);
    }

    return {
      'reps': reps,
      'ease_factor': double.parse(easeFactor.toStringAsFixed(2)),
      'interval_ms': intervalMs,
      'last_review_time': nowMs,
      'next_review_time': nowMs + intervalMs,
      'lapse_count': lapseCount,
    };
  }

  /// 供 UI 按钮预测时间展示
  static String formatInterval(int ms) {
    if (ms <= 0) return '刚才';
    final Duration d = Duration(milliseconds: ms);
    if (d.inMinutes < 60) return '${d.inMinutes}分钟';
    if (d.inHours < 24) return '${d.inHours}小时';
    if (d.inDays < 30) return '${d.inDays}天';
    return '${(d.inDays / 30).toStringAsFixed(1)}月';
  }
}
