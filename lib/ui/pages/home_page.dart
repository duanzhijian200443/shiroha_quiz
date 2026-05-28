import 'package:flutter/material.dart';
import 'bank_detail_screen.dart';
import 'plan_config_screen.dart';
import 'task_center_screen.dart';
import '../../core/database/database_helper.dart';
import '../../core/review_engine_service.dart';
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
        // 1. 仅依赖题库名，彻底抛弃可能导致脑裂的 folder 缓存
        final bank = await DatabaseHelper.instance.getSetting('current_bank');
        
        String targetBank = bank ?? '点击修改选择题库';
        String targetFolder = '请选择学科';

        int newC = 0, reviewC = 0, totalC = 0, masteredC = 0;

        if (targetBank != '点击修改选择题库') {
          // 2. 实时去底层数据库寻址该题库的最新文件夹映射
          targetFolder = await DatabaseHelper.instance.getFolderForBank(targetBank);
          
          // 3. 拉取 FSRS 统计数据
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
    
    // 动态色彩映射
    final bgColor = theme.scaffoldBackgroundColor;
    final cardColor = theme.cardTheme.color ?? theme.colorScheme.surface;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.white54 : Colors.black54;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: const Text('Shiroha Quiz', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.5)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor,
        // 1. 左上角：任务传输中心 (动态监听 TaskManager)
        leading: AnimatedBuilder(
          animation: TaskManager.instance,
          builder: (context, child) {
            final count = TaskManager.instance.processingCount;
            return IconButton(
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(Icons.swap_vert_rounded, color: theme.textTheme.bodyLarge?.color),
                  if (count > 0)
                    Positioned(
                      right: -2, top: -2,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
                        constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                        child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                      ),
                    )
                ],
              ),
              onPressed: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const TaskCenterScreen()));
              },
            );
          },
        ),
        // 2. 右上角：通知中心
        actions: [
          IconButton(
            icon: Icon(Icons.notifications_none_rounded, color: theme.textTheme.bodyLarge?.color),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('消息中心待下一阶段接入')));
            },
          )
        ],
      ),
      body: _isLoading 
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(20.0),
                children: [
                  // 书本卡片
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 4))],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 绿皮书 Icon 模拟
                        Container(
                          width: 60,
                          height: 80,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2EAA70),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          alignment: Alignment.center,
                          child: const Text('Book', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      '$_currentFolder - $_currentBank', 
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: textColor),
                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(builder: (_) => PlanConfigScreen(currentBank: _currentBank)),
                                      ).then((_) => _loadContext());
                                    },
                                    child: Text('修改 >', style: TextStyle(color: subTextColor, fontSize: 13)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              // 进度条
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: _totalCount == 0 ? 0.0 : (_masteredCount / _totalCount).clamp(0.0, 1.0),
                                  backgroundColor: Colors.grey.shade200,
                                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF4C6ED7)),
                                  minHeight: 6,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(_totalCount == 0 ? '暂无数据' : (_masteredCount == _totalCount ? '已全部掌握' : '正在攻克'), style: TextStyle(color: subTextColor, fontSize: 12)),
                                  Text('已掌握 $_masteredCount / $_totalCount', style: TextStyle(color: subTextColor, fontSize: 12)),
                                ],
                              )
                            ],
                          ),
                        )
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  Text('今日计划', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: textColor)),
                  const SizedBox(height: 24),
                  
                  Row(
                    children: [
                      Expanded(child: _buildStatColumn('待新学', '$_newCount', '$_totalCount', textColor, subTextColor)),
                      Expanded(child: _buildStatColumn('待复习', '$_reviewCount', '$_totalCount', textColor, subTextColor)),
                    ],
                  ),
                  
                  const SizedBox(height: 40),
                  
                  // 3. 底部双开按钮
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 54,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4C6ED7),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              elevation: 0,
                            ),
                            onPressed: () => _gotoPractice(),
                            child: const Text('新学', style: TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: SizedBox(
                          height: 54,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4C6ED7),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              elevation: 0,
                            ),
                            onPressed: () => _gotoPractice(),
                            child: const Text('复习', style: TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildStatColumn(String label, String value, String total, Color textColor, Color subTextColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: subTextColor, fontSize: 14)),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value, style: TextStyle(fontSize: 48, fontWeight: FontWeight.w900, height: 1.0, color: textColor)),
            Text(' / $total', style: TextStyle(fontSize: 16, color: subTextColor, fontWeight: FontWeight.w500)),
          ],
        )
      ],
    );
  }

  void _gotoPractice() {
    if (_currentBank == '点击修改选择题库') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先选择题库')));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BankDetailScreen(bankName: _currentBank)),
    ).then((_) => _loadContext());
  }
}
