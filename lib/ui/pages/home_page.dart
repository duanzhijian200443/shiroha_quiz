import 'package:flutter/material.dart';
import 'bank_detail_screen.dart';
import 'plan_config_screen.dart';
import 'task_center_screen.dart';
import '../../core/review_engine_service.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/task_manager.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.taskManager,
    this.onSwitchBank,
    this.onPracticeRequested,
  });

  final TaskManager? taskManager;
  final VoidCallback? onSwitchBank;
  final VoidCallback? onPracticeRequested;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _currentBank = '点击修改选择题库';
  int _newCount = 0;
  int _reviewCount = 0;
  int _totalCount = 0;
  int _masteredCount = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadContext();
  }

  Future<void> _loadContext() async {
    setState(() => _isLoading = true);
    try {
      final bank = await SettingsRepository.instance.getCurrentBank();

      String targetBank = bank ?? '点击修改选择题库';

      int newC = 0, reviewC = 0, totalC = 0, masteredC = 0;

      if (targetBank != '点击修改选择题库') {
        final stats = await ReviewEngineService().getBankStats(targetBank);
        totalC = stats['total'] ?? 0;
        newC = stats['new_count'] ?? 0;
        reviewC = stats['review_count'] ?? 0;
        masteredC = stats['mastered_count'] ?? 0;
      }

      if (mounted) {
        setState(() {
          _currentBank = targetBank;
          _totalCount = totalC;
          _newCount = newC;
          _reviewCount = reviewC;
          _masteredCount = masteredC;
        });
      }
    } catch (e) {
      debugPrint('首页状态加载失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor =
        isDark ? theme.scaffoldBackgroundColor : const Color(0xFFF4F6FC);
    final cardColor = theme.cardTheme.color ?? theme.colorScheme.surface;
    final textColor = isDark ? Colors.white : const Color(0xFF18213A);
    final subTextColor = isDark ? Colors.white60 : const Color(0xFF78839A);
    final primaryColor = theme.colorScheme.primary;
    final taskManager = widget.taskManager ?? TaskManager.instance;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text.rich(
          key: const ValueKey<String>('home-brand-title'),
          TextSpan(
            children: [
              TextSpan(
                text: 'Shiroha',
                style: TextStyle(color: textColor),
              ),
              TextSpan(
                text: ' Quiz',
                style: TextStyle(color: primaryColor),
              ),
            ],
          ),
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: bgColor,
        surfaceTintColor: Colors.transparent,
        leading: AnimatedBuilder(
          animation: taskManager,
          builder: (context, child) {
            final count = taskManager.processingCount;
            return IconButton(
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(Icons.swap_vert_rounded, color: textColor, size: 28),
                  if (count > 0)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 16,
                          minHeight: 16,
                        ),
                        child: Text(
                          '$count',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                ],
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const TaskCenterScreen(),
                  ),
                );
              },
            );
          },
        ),
        actions: const [SizedBox(width: 56)],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              top: false,
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    sliver: SliverList.list(
                      children: [
                        _buildBankCard(
                          cardColor,
                          textColor,
                          subTextColor,
                          primaryColor,
                        ),
                        const SizedBox(height: 18),
                        _buildTrainingCard(
                          cardColor,
                          textColor,
                          subTextColor,
                          primaryColor,
                        ),
                      ],
                    ),
                  ),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
                      child: _buildReviewState(
                        textColor,
                        subTextColor,
                        primaryColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildBankCard(
    Color cardColor,
    Color textColor,
    Color subTextColor,
    Color primaryColor,
  ) {
    final hasSelectedBank = _currentBank != '点击修改选择题库';
    final title = hasSelectedBank ? _currentBank : '请选择题库';
    final statusText = _totalCount == 0
        ? '暂无学习记录'
        : (_masteredCount == _totalCount ? '已完成本题库' : '学习进行中');

    return Container(
      key: const ValueKey<String>('home-bank-card'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: primaryColor.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 58,
            height: 68,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  primaryColor.withValues(alpha: 0.82),
                  primaryColor,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: primaryColor.withValues(alpha: 0.22),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: const Center(
              child: Icon(
                Icons.menu_book_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      key: const ValueKey<String>('home-switch-bank'),
                      onPressed: _handleSwitchBank,
                      style: TextButton.styleFrom(
                        foregroundColor: subTextColor,
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '切换',
                            style: TextStyle(
                              color: subTextColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: subTextColor,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: _totalCount == 0
                        ? 0
                        : (_masteredCount / _totalCount).clamp(0, 1),
                    backgroundColor: primaryColor.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    minHeight: 7,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  runSpacing: 4,
                  spacing: 12,
                  children: [
                    Text(
                      statusText,
                      style: TextStyle(
                        color: subTextColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      '已掌握 $_masteredCount / $_totalCount',
                      style: TextStyle(
                        color: subTextColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrainingCard(
    Color cardColor,
    Color textColor,
    Color subTextColor,
    Color primaryColor,
  ) {
    return Container(
      key: const ValueKey<String>('home-training-card'),
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: primaryColor.withValues(alpha: 0.07),
        ),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withValues(alpha: 0.07),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '今日训练',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: textColor,
            ),
          ),
          const SizedBox(height: 16),
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: Ink(
              height: 56,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    primaryColor,
                    themeSafeLerp(primaryColor, Colors.lightBlue, 0.2),
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.25),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: InkWell(
                key: const ValueKey<String>('home-start-training'),
                onTap: _handlePracticeRequest,
                borderRadius: BorderRadius.circular(16),
                child: const Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '开始今日训练',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _buildTaskEntry(
                    key: const ValueKey<String>('home-new-task'),
                    title: '新题挑战',
                    countText: '$_newCount 道新题',
                    icon: Icons.auto_stories_rounded,
                    accentColor: const Color(0xFF4CAFC8),
                    accentBackground: const Color(0xFFE8F8FC),
                    textColor: textColor,
                    subTextColor: subTextColor,
                    onTap: _handlePracticeRequest,
                  ),
                ),
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: subTextColor.withValues(alpha: 0.16),
                ),
                Expanded(
                  child: _buildTaskEntry(
                    key: const ValueKey<String>('home-review-task'),
                    title: '复习巩固',
                    countText: '$_reviewCount 道待复习',
                    icon: Icons.fact_check_outlined,
                    accentColor: const Color(0xFFE99042),
                    accentBackground: const Color(0xFFFFF1E5),
                    textColor: textColor,
                    subTextColor: subTextColor,
                    onTap: _handlePracticeRequest,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskEntry({
    required Key key,
    required String title,
    required String countText,
    required IconData icon,
    required Color accentColor,
    required Color accentBackground,
    required Color textColor,
    required Color subTextColor,
    required VoidCallback onTap,
  }) {
    return Material(
      key: key,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: accentBackground,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: accentColor, size: 23),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        countText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: subTextColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReviewState(
    Color textColor,
    Color subTextColor,
    Color primaryColor,
  ) {
    if (_reviewCount > 0) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 62,
              color: primaryColor.withValues(alpha: 0.48),
            ),
            const SizedBox(height: 14),
            Text(
              '继续保持学习！',
              style: TextStyle(
                color: textColor,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '今日有 $_reviewCount 道题等待复习',
              textAlign: TextAlign.center,
              style: TextStyle(color: subTextColor, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 100,
            height: 84,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.menu_book_rounded,
                  size: 68,
                  color: primaryColor.withValues(alpha: 0.28),
                ),
                Positioned(
                  right: 7,
                  top: 5,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: primaryColor.withValues(alpha: 0.26),
                      ),
                    ),
                    child: Icon(
                      Icons.schedule_rounded,
                      size: 24,
                      color: primaryColor.withValues(alpha: 0.62),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '暂无待复习题目',
            style: TextStyle(
              color: textColor,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            '完成新题或产生错题后，将自动生成复习任务',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: subTextColor,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openBankSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlanConfigScreen(currentBank: _currentBank),
      ),
    );
    await _loadContext();
  }

  void _handleSwitchBank() {
    final callback = widget.onSwitchBank;
    if (callback != null) {
      callback();
      return;
    }
    _openBankSettings();
  }

  void _handlePracticeRequest() {
    final callback = widget.onPracticeRequested;
    if (callback != null) {
      callback();
      return;
    }
    _gotoPractice();
  }

  Color themeSafeLerp(Color from, Color to, double amount) {
    return Color.lerp(from, to, amount) ?? from;
  }

  void _gotoPractice() {
    if (_currentBank == '点击修改选择题库') {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先选择题库')));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => BankDetailScreen(bankName: _currentBank)),
    ).then((_) => _loadContext());
  }
}
