import 'package:flutter/material.dart';
import 'bank_detail_screen.dart';
import 'plan_config_screen.dart';
import 'task_center_screen.dart';
import '../../core/review_engine_service.dart';
import '../../data/repositories/question_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/task_manager.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _currentFolder = '请选择学科';
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
      String targetFolder = '请选择学科';

      int newC = 0, reviewC = 0, totalC = 0, masteredC = 0;

      if (targetBank != '点击修改选择题库') {
        targetFolder =
            await QuestionRepository.instance.getFolderForBank(targetBank);

        final stats = await ReviewEngineService().getBankStats(targetBank);
        totalC = stats['total'] ?? 0;
        newC = stats['new_count'] ?? 0;
        reviewC = stats['review_count'] ?? 0;
        masteredC = stats['mastered_count'] ?? 0;
      }

      if (mounted) {
        setState(() {
          _currentFolder = targetFolder;
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
        isDark ? theme.scaffoldBackgroundColor : const Color(0xFFF8F9FE);
    final cardColor = isDark
        ? theme.cardTheme.color ?? theme.colorScheme.surface
        : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF1E222B);
    final subTextColor = isDark ? Colors.white54 : const Color(0xFF8B92A1);
    final primaryColor =
        const Color(0xFF5B8DF8); // Deeper blue matching the play button

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          "Shiroha Quiz",
          style: TextStyle(
            color: textColor,
            fontSize: 20,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: bgColor,
        leading: AnimatedBuilder(
          animation: TaskManager.instance,
          builder: (context, child) {
            final count = TaskManager.instance.processingCount;
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
                            color: Colors.redAccent, shape: BoxShape.circle),
                        constraints:
                            const BoxConstraints(minWidth: 16, minHeight: 16),
                        child: Text('$count',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center),
                      ),
                    )
                ],
              ),
              onPressed: () {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const TaskCenterScreen()));
              },
            );
          },
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.settings_outlined, color: textColor, size: 26),
            onPressed: () {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('设置中心待接入')));
            },
          )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20.0, vertical: 12.0),
                children: [
                  // 顶部卡片
                  _buildBankCard(
                      cardColor, textColor, subTextColor, primaryColor),

                  const SizedBox(height: 32),
                  Text('今日计划',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: textColor)),
                  const SizedBox(height: 16),

                  // 今日新学卡片
                  _buildPlanCard(
                    title: '今日新学',
                    count: _newCount,
                    unit: '个知识点',
                    iconData: Icons.menu_book_rounded,
                    cardColor: cardColor,
                    textColor: textColor,
                    subTextColor: subTextColor,
                    primaryColor: primaryColor,
                    onTap: _gotoPractice,
                  ),

                  const SizedBox(height: 16),

                  // 今日复习卡片
                  _buildPlanCard(
                    title: '今日复习',
                    count: _reviewCount,
                    unit: '个待复习',
                    iconData: Icons.assignment_outlined, // 换成剪贴板
                    cardColor: cardColor,
                    textColor: textColor,
                    subTextColor: subTextColor,
                    primaryColor: primaryColor,
                    onTap: _gotoPractice,
                  ),

                  const SizedBox(height: 48),

                  // 底部插图
                  if (_currentBank == '点击修改选择题库' || _totalCount == 0)
                    Column(
                      children: [
                        Icon(Icons.desk,
                            size: 80, color: primaryColor.withOpacity(0.4)),
                        const SizedBox(height: 16),
                        Text('暂无复习数据',
                            style: TextStyle(
                                color: subTextColor,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Text('请先选择题库',
                            style: TextStyle(
                                color: subTextColor.withOpacity(0.8),
                                fontSize: 14)),
                      ],
                    )
                  else
                    Column(
                      children: [
                        Icon(Icons.auto_awesome,
                            size: 80, color: primaryColor.withOpacity(0.4)),
                        const SizedBox(height: 16),
                        Text('继续保持学习！',
                            style: TextStyle(
                                color: subTextColor,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),

                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }

  Widget _buildBankCard(Color cardColor, Color textColor, Color subTextColor,
      Color primaryColor) {
    String title = _currentBank == '点击修改选择题库' ? '考研政治' : _currentBank;
    if (_currentBank != '点击修改选择题库') {
      title = _currentBank;
    }
    String statusText = _totalCount == 0
        ? '暂无数据'
        : (_masteredCount == _totalCount ? '已全部掌握' : '正在攻克');

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
              color: primaryColor.withOpacity(0.08),
              blurRadius: 24,
              offset: const Offset(0, 8))
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start, // 顶部对齐以适配图中的样式
        children: [
          // 左侧蓝色书本图标容器
          Container(
            width: 64,
            height: 72,
            decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF8BADE8), Color(0xFF6B92D4)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                      color: primaryColor.withOpacity(0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 4))
                ]),
            child: const Center(
              child: Icon(Icons.menu_book, color: Colors.white, size: 36),
            ),
          ),
          const SizedBox(width: 20),
          // 右侧信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: textColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  PlanConfigScreen(currentBank: _currentBank)),
                        ).then((_) => _loadContext());
                      },
                      child: Text('修改 >',
                          style: TextStyle(
                              color: subTextColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w500)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _totalCount == 0
                        ? 0.0
                        : (_masteredCount / _totalCount).clamp(0.0, 1.0),
                    backgroundColor: primaryColor.withOpacity(0.15),
                    valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(statusText,
                        style: TextStyle(
                            color: subTextColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w500)),
                    Text('已掌握 $_masteredCount / $_totalCount',
                        style: TextStyle(
                            color: subTextColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w500)),
                  ],
                )
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildPlanCard({
    required String title,
    required int count,
    required String unit,
    required IconData iconData,
    required Color cardColor,
    required Color textColor,
    required Color subTextColor,
    required Color primaryColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 16,
                offset: const Offset(0, 6))
          ],
        ),
        child: Row(
          children: [
            // 左侧图标
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F6FF),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(iconData, color: primaryColor, size: 28),
            ),
            const SizedBox(width: 16),
            // 文字
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          color: textColor)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        count == 0 ? Icons.check_circle : Icons.schedule,
                        color: count == 0
                            ? const Color(0xFF52C41A)
                            : Colors.orange,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Text('$count $unit',
                          style: TextStyle(
                              fontSize: 13,
                              color: subTextColor,
                              fontWeight: FontWeight.w500)),
                    ],
                  )
                ],
              ),
            ),
            // 右侧播放按钮
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: primaryColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: primaryColor.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2))
                  ]),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 24),
            )
          ],
        ),
      ),
    );
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
