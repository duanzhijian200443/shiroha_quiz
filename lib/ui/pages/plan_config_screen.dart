import 'package:flutter/material.dart';
import '../../core/database/database_helper.dart';
import '../../core/review_engine_service.dart';

class PlanConfigScreen extends StatefulWidget {
    final String currentBank;
    const PlanConfigScreen({super.key, required this.currentBank});

    @override
    State<PlanConfigScreen> createState() => _PlanConfigScreenState();
}

class _PlanConfigScreenState extends State<PlanConfigScreen> with SingleTickerProviderStateMixin {
    late TabController _tabController;
    List<Map<String, dynamic>> _allBanks = [];
    bool _isLoading = true;
    int _selectedQuota = 40;

    @override
    void initState() {
        super.initState();
        _tabController = TabController(length: 2, vsync: this);
        _loadData();
    }

    @override
    void dispose() {
        _tabController.dispose();
        super.dispose();
    }

    Future<void> _loadData() async {
        final banks = await ReviewEngineService().getAllBankStats();
        final quotaStr = await DatabaseHelper.instance.getSetting('${widget.currentBank}_daily_quota');
        if (mounted) {
            setState(() {
                _allBanks = banks;
                _selectedQuota = int.tryParse(quotaStr ?? '40') ?? 40;
                _isLoading = false;
            });
        }
    }

    Future<void> _savePlan() async {
        await DatabaseHelper.instance.saveSetting('${widget.currentBank}_daily_quota', _selectedQuota.toString());
        if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('计划保存成功')));
            Navigator.pop(context);
        }
    }

    Future<void> _switchBank(String bankName) async {
        await DatabaseHelper.instance.saveSetting('current_bank', bankName);
        if (mounted) {
            Navigator.pop(context);
        }
    }

    @override
    Widget build(BuildContext context) {
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;
        final bgColor = isDark ? const Color(0xFF121214) : const Color(0xFFF5F7FA);

        return Scaffold(
            backgroundColor: bgColor,
            appBar: AppBar(
                backgroundColor: bgColor,
                elevation: 0,
                leading: IconButton(icon: Icon(Icons.arrow_back_ios, color: theme.textTheme.bodyLarge?.color), onPressed: () => Navigator.pop(context)),
                bottom: TabBar(
                    controller: _tabController,
                    indicatorColor: theme.primaryColor,
                    labelColor: theme.primaryColor,
                    unselectedLabelColor: Colors.grey,
                    tabs: const [Tab(text: '修改计划'), Tab(text: '更换题库')],
                ),
            ),
            body: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: [
                        _buildPlanTab(theme, isDark),
                        _buildSwitchTab(theme, isDark),
                    ],
                  ),
        );
    }

    Widget _buildPlanTab(ThemeData theme, bool isDark) {
        final cardColor = isDark ? (theme.cardTheme.color ?? theme.cardColor) : Colors.white;
        final currentStats = _allBanks.firstWhere((b) => b['bank_name'] == widget.currentBank, orElse: () => <String, dynamic>{});
        if (currentStats.isEmpty) return const Center(child: Text('当前题库无数据'));

        return ListView(
            padding: const EdgeInsets.all(16),
            children: [
                _buildBookCard(currentStats, cardColor, theme, isCurrent: true),
                const SizedBox(height: 24),
                Text('每日刷题量 (题)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: theme.textTheme.bodyLarge?.color)),
                const SizedBox(height: 16),
                Container(
                    decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(16)),
                    child: Column(
                        children: [1, 5, 10, 15, 20, 30, 40, 50, 60].map((quota) {
                            final isSelected = _selectedQuota == quota;
                            return ListTile(
                                title: Text('$quota 题', style: TextStyle(color: isSelected ? theme.primaryColor : Colors.grey, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                                trailing: isSelected ? Icon(Icons.check_circle, color: theme.primaryColor) : null,
                                onTap: () => setState(() => _selectedQuota = quota),
                            );
                        }).toList(),
                    ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                    height: 54,
                    child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: theme.primaryColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: _savePlan,
                        child: const Text('保存计划', style: TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                )
            ],
        );
    }

    Widget _buildSwitchTab(ThemeData theme, bool isDark) {
      final cardColor = isDark ? theme.cardTheme.color! : Colors.white;
      
      // 1. 将一维数组按学科文件夹重组为二维 Map
      Map<String, List<Map<String, dynamic>>> groupedBanks = {};
      for (var bank in _allBanks) {
        String folder = bank['folder_name'] as String? ?? '📁 未分类题库';
        if (!groupedBanks.containsKey(folder)) {
          groupedBanks[folder] = [];
        }
        groupedBanks[folder]!.add(bank);
      }

      // 2. 渲染带有 ExpansionTile 的树状嵌套列表
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: groupedBanks.length,
        itemBuilder: (context, index) {
          String folderName = groupedBanks.keys.elementAt(index);
          List<Map<String, dynamic>> banks = groupedBanks[folderName]!;
          
          // 智能交互：如果该分类下包含当前正在学习的题库，默认展开
          bool isExpanded = banks.any((b) => b['bank_name'] == widget.currentBank) || index == 0;

          return Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 12),
            color: isDark ? theme.scaffoldBackgroundColor : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: isDark ? Colors.white10 : theme.primaryColor.withValues(alpha: 0.2)),
            ),
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: isExpanded,
                iconColor: theme.primaryColor,
                textColor: theme.primaryColor,
                // 核心新增：为学科分类注入极客风拟物图标 (缩小版丛书)
                leading: Container(
                  width: 60, height: 80,
                  decoration: BoxDecoration(color: const Color(0xFF2EAA70), borderRadius: BorderRadius.circular(6)),
                  alignment: Alignment.center,
                  child: const Text('Book', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                title: Text(folderName, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: theme.primaryColor)),
                children: banks.map((bank) {
                  final isCurrent = bank['bank_name'] == widget.currentBank;
                  return GestureDetector(
                    onTap: () => _switchBank(bank['bank_name']),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
                      child: _buildBookCard(bank, cardColor, theme, isCurrent: isCurrent),
                    ),
                  );
                }).toList(),
              ),
            ),
          );
        },
      );
    }

    Widget _buildBookCard(Map<String, dynamic> bank, Color cardColor, ThemeData theme, {bool isCurrent = false}) {
      final total = bank['total'] as int? ?? 1;
      final mastered = bank['mastered'] as int? ?? 0;
      final progress = (mastered / (total == 0 ? 1 : total)).clamp(0.0, 1.0);

      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          border: isCurrent ? Border.all(color: theme.primaryColor.withValues(alpha: 0.5), width: 2) : Border.all(color: Colors.grey.withValues(alpha: 0.1)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 8)],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 核心修复：恢复原先 60x80 大小的绿皮书 -> 现在缩小为 45x60
            Container(
              width: 45, height: 60,
              decoration: BoxDecoration(color: const Color(0xFF2EAA70), borderRadius: BorderRadius.circular(6)),
              alignment: Alignment.center,
              child: const Text('Book', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: Text(bank['bank_name'], style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold), maxLines: 1)),
                      if (isCurrent) Text('当前在学', style: TextStyle(color: theme.primaryColor, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('每日 ${bank['daily_quota']} 题，剩余 ${bank['days_left']} 天', style: const TextStyle(color: Colors.grey, fontSize: 13)),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(value: progress, backgroundColor: Colors.grey.shade200, valueColor: AlwaysStoppedAnimation<Color>(theme.primaryColor), minHeight: 4),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('已学 $mastered', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      Text('$total 题', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    ],
                  )
                ],
              ),
            )
          ],
        ),
      );
    }
}
