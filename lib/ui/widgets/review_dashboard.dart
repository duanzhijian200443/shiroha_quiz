import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/review_dashboard_data.dart';

typedef ReviewDashboardLoader = Future<ReviewDashboardData> Function(
    String bankName);

class ReviewDashboard extends StatefulWidget {
  final String bankName;
  final ReviewDashboardLoader? dataLoader;

  const ReviewDashboard({
    super.key,
    required this.bankName,
    this.dataLoader,
  });

  @override
  State<ReviewDashboard> createState() => _ReviewDashboardState();
}

class _ReviewDashboardState extends State<ReviewDashboard> {
  bool _isLoading = false;
  ReviewDashboardData? _data;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void didUpdateWidget(covariant ReviewDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bankName != widget.bankName) {
      _loadData();
    }
  }

  Future<void> _loadData() async {
    if (widget.bankName == '点击修改选择题库' || widget.bankName.isEmpty) {
      if (mounted) {
        setState(() {
          _data = null;
          _isLoading = false;
        });
      }
      return;
    }

    if (mounted) setState(() => _isLoading = true);

    try {
      final loader =
          widget.dataLoader ?? ReviewEngineService().getReviewDashboardData;
      final data = await loader(widget.bankName);
      if (mounted) {
        setState(() {
          _data = data;
        });
      }
    } catch (e) {
      debugPrint("Error loading dashboard data: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.cardTheme.color ?? theme.colorScheme.surface;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.white54 : Colors.black54;

    if (widget.bankName == '点击修改选择题库' || widget.bankName.isEmpty) {
      return _buildEmptyState(cardColor, subTextColor, "暂无复习数据\n请先选择题库");
    }

    if (_isLoading) {
      return Container(
        height: 200,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      );
    }

    if (_data == null || _data!.total == 0) {
      return _buildEmptyState(cardColor, subTextColor, "暂无复习数据\n先导入题库开始学习吧");
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('知识掌握率',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w900, color: textColor)),
        const SizedBox(height: 16),
        _buildMasteryChart(cardColor, textColor, subTextColor),
        const SizedBox(height: 32),
        Text('未来 7 天复习压力',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w900, color: textColor)),
        const SizedBox(height: 16),
        _buildForecastChart(cardColor, textColor, subTextColor),
      ],
    );
  }

  Widget _buildEmptyState(Color cardColor, Color subTextColor, String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.pie_chart_outline_rounded,
              size: 48, color: subTextColor.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(message,
              textAlign: TextAlign.center,
              style: TextStyle(color: subTextColor, fontSize: 14, height: 1.5)),
        ],
      ),
    );
  }

  Widget _buildMasteryChart(
      Color cardColor, Color textColor, Color subTextColor) {
    final int total = _data!.total;
    final int mastered = _data!.masteredCount;
    final int scheduled = _data!.scheduledCount;
    final int review = _data!.dueReviewCount;
    final int newCount = _data!.newCount;

    final double masteredPct = total > 0 ? (mastered / total * 100) : 0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            height: 140,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  PieChartData(
                    sectionsSpace: 2,
                    centerSpaceRadius: 50,
                    startDegreeOffset: -90,
                    sections: [
                      PieChartSectionData(
                        color: const Color(0xFF2EAA70), // Mastered: Green
                        value: mastered.toDouble(),
                        title: '',
                        radius: 12,
                      ),
                      PieChartSectionData(
                        color: const Color(0xFF4C6ED7), // Scheduled: Blue
                        value: scheduled.toDouble(),
                        title: '',
                        radius: 12,
                      ),
                      PieChartSectionData(
                        color: const Color(0xFFF57C00), // Due: Orange
                        value: review.toDouble(),
                        title: '',
                        radius: 12,
                      ),
                      PieChartSectionData(
                        color: const Color(0xFF9E9E9E), // New: Grey
                        value: newCount.toDouble(),
                        title: '',
                        radius: 12,
                      ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${masteredPct.toStringAsFixed(0)}%',
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          color: textColor),
                    ),
                    Text('已掌握',
                        style: TextStyle(fontSize: 12, color: subTextColor)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildLegendItem(const Color(0xFF2EAA70), '已掌握', mastered,
                    total, textColor, subTextColor),
                const SizedBox(height: 8),
                _buildLegendItem(const Color(0xFF4C6ED7), '当前稳定', scheduled,
                    total, textColor, subTextColor),
                const SizedBox(height: 8),
                _buildLegendItem(const Color(0xFFF57C00), '待复习', review, total,
                    textColor, subTextColor),
                const SizedBox(height: 8),
                _buildLegendItem(const Color(0xFF9E9E9E), '新学', newCount, total,
                    textColor, subTextColor),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildLegendItem(Color color, String label, int value, int total,
      Color textColor, Color subTextColor) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child:
              Text(label, style: TextStyle(color: subTextColor, fontSize: 13)),
        ),
        Text(value.toString(),
            style: TextStyle(
                color: textColor, fontSize: 13, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildForecastChart(
      Color cardColor, Color textColor, Color subTextColor) {
    if (_data == null || _data!.forecast.isEmpty) {
      return const SizedBox();
    }

    final forecast = _data!.forecast;
    int maxCount = 0;
    for (var f in forecast) {
      if (f.count > maxCount) maxCount = f.count;
    }

    if (maxCount == 0) maxCount = 10; // default ceiling

    final now = DateTime.now();
    final tomorrow =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));

    return Container(
      padding: const EdgeInsets.only(top: 20, right: 20, left: 10, bottom: 10),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      height: 220,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: (maxCount * 1.2).toDouble(), // 20% padding top
          barTouchData: BarTouchData(
            enabled: true,
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (group) => Colors.black87,
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                return BarTooltipItem(
                  '${rod.toY.round()} 题',
                  const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                );
              },
            ),
          ),
          titlesData: FlTitlesData(
            show: true,
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (double value, TitleMeta meta) {
                  final int index = value.toInt();
                  if (index < 0 || index >= forecast.length) {
                    return const SizedBox();
                  }
                  final dt = forecast[index].date;
                  final isToday = dt.year == now.year &&
                      dt.month == now.month &&
                      dt.day == now.day;
                  final isTomorrow = dt.year == tomorrow.year &&
                      dt.month == tomorrow.month &&
                      dt.day == tomorrow.day;

                  String label = '';
                  if (isToday) {
                    label = '今天';
                  } else if (isTomorrow) {
                    label = '明天';
                  } else {
                    final weekday = [
                      '周一',
                      '周二',
                      '周三',
                      '周四',
                      '周五',
                      '周六',
                      '周日'
                    ][dt.weekday - 1];
                    label = weekday;
                  }

                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      label,
                      style: TextStyle(color: subTextColor, fontSize: 11),
                    ),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval:
                (maxCount / 4).clamp(1.0, double.infinity).toDouble(),
            getDrawingHorizontalLine: (value) => FlLine(
              color: subTextColor.withValues(alpha: 0.1),
              strokeWidth: 1,
              dashArray: [4, 4],
            ),
          ),
          borderData: FlBorderData(show: false),
          barGroups: forecast.asMap().entries.map((entry) {
            final index = entry.key;
            final count = entry.value.count;
            return BarChartGroupData(
              x: index,
              barRods: [
                BarChartRodData(
                  toY: count.toDouble(),
                  color: const Color(0xFF4C6ED7),
                  width: 16,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(6)),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }
}
