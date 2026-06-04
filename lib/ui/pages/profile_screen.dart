import 'package:flutter/material.dart';
import '../../core/database/database_helper.dart';
import '../../data/repositories/ai_engine_repository.dart';
import '../../main.dart';
import 'ai_engine_management_screen.dart';
import 'knowledge_base_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _textEngineName = '未配置';
  String _visionEngineName = '未配置';
  Map<DateTime, int> _heatmapData = {};
  int _totalReviewed = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final textEngine =
          await AiEngineRepository.instance.getActiveTextEngine();
      final visionEngine =
          await AiEngineRepository.instance.getActiveVisionEngine();
      final heatmap = await DatabaseHelper.instance.getHeatmapData();

      int total = 0;
      heatmap.forEach((k, v) => total += v);

      if (mounted) {
        setState(() {
          _textEngineName = textEngine?.name ?? '点击去配置';
          _visionEngineName = visionEngine?.name ?? '点击去配置';
          _heatmapData = heatmap;
          _totalReviewed = total;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Profile 数据加载失败: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 核心算法：手工 GitHub 极客热力图
  Widget _buildHeatmap(ThemeData theme) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // 往前推 83 天
    final startDate = today.subtract(const Duration(days: 83));

    List<Widget> columns = [];
    for (int w = 0; w < 12; w++) {
      List<Widget> cells = [];
      for (int d = 0; d < 7; d++) {
        final currentDate = startDate.add(Duration(days: w * 7 + d));
        final count = _heatmapData[currentDate] ?? 0;

        // 动态色彩映射：根据刷题量加深主题色透明度
        Color cellColor;
        if (count == 0) {
          cellColor = theme.brightness == Brightness.dark
              ? Colors.white10
              : Colors.black.withValues(alpha: 0.05);
        } else if (count < 10) {
          cellColor = theme.primaryColor.withValues(alpha: 0.3);
        } else if (count < 30) {
          cellColor = theme.primaryColor.withValues(alpha: 0.6);
        } else if (count < 60) {
          cellColor = theme.primaryColor.withValues(alpha: 0.8);
        } else {
          cellColor = theme.primaryColor;
        }

        cells.add(Container(
          width: 14,
          height: 14,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
              color: cellColor, borderRadius: BorderRadius.circular(3)),
        ));
      }
      columns.add(Column(children: cells));
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: columns,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
          title: const Text('我的控制台',
              style: TextStyle(fontWeight: FontWeight.bold))),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                // 1. 极客名片与热力墙
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                          color: Colors.grey.withValues(alpha: 0.1))),
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const CircleAvatar(
                                radius: 30,
                                backgroundColor: Color(0xFFE0E5F9),
                                child: Icon(Icons.face_retouching_natural,
                                    size: 35, color: Color(0xFF4C6ED7))),
                            const SizedBox(width: 16),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Shiroha 学员',
                                    style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                Text('累计消灭 $_totalReviewed 道题',
                                    style: const TextStyle(
                                        color: Colors.grey, fontSize: 13)),
                              ],
                            )
                          ],
                        ),
                        const SizedBox(height: 24),
                        const Align(
                            alignment: Alignment.centerLeft,
                            child: Text('最近 12 周记忆热力图',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                    fontWeight: FontWeight.bold))),
                        const SizedBox(height: 12),
                        _buildHeatmap(theme),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),

                // 2. RAG 专属知识库管理
                const Padding(
                    padding: EdgeInsets.only(left: 8, bottom: 8),
                    child: Text('知识引擎',
                        style: TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                            fontWeight: FontWeight.bold))),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                          color: Colors.grey.withValues(alpha: 0.1))),
                  child: ListTile(
                    leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                            color: Colors.blueAccent,
                            borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.auto_stories,
                            color: Colors.white)),
                    title: const Text('管理 RAG 专属知识库',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('导入私有笔记，AI 出题绝对零幻觉',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    trailing: const Icon(Icons.arrow_forward_ios_rounded,
                        size: 14, color: Colors.grey),
                    onTap: () {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const KnowledgeBaseScreen()));
                    },
                  ),
                ),
                const SizedBox(height: 32),

                // 3. AI 引擎配置栏
                const Padding(
                    padding: EdgeInsets.only(left: 8, bottom: 8),
                    child: Text('AI 分布式核心配置',
                        style: TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                            fontWeight: FontWeight.bold))),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                          color: Colors.grey.withValues(alpha: 0.1))),
                  child: Column(
                    children: [
                      ListTile(
                        leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.text_fields_rounded,
                                color: Colors.blueAccent)),
                        title: const Text('文本与逻辑中枢',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(_textEngineName,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.blueAccent)),
                        trailing: const Icon(Icons.arrow_forward_ios_rounded,
                            size: 14, color: Colors.grey),
                        onTap: () {
                          Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AiEngineManagementScreen(
                                              engineType: 'text')))
                              .then((_) => _loadData());
                        },
                      ),
                      const Divider(height: 1, indent: 64),
                      ListTile(
                        leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                                color: Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.remove_red_eye_rounded,
                                color: Colors.orangeAccent)),
                        title: const Text('视觉与多模态矩阵',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(_visionEngineName,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.orange)),
                        trailing: const Icon(Icons.arrow_forward_ios_rounded,
                            size: 14, color: Colors.grey),
                        onTap: () {
                          Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AiEngineManagementScreen(
                                              engineType: 'vision')))
                              .then((_) => _loadData());
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),

                // 3. 个性化装扮
                const Padding(
                    padding: EdgeInsets.only(left: 8, bottom: 8),
                    child: Text('个性化装扮',
                        style: TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                            fontWeight: FontWeight.bold))),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                          color: Colors.grey.withValues(alpha: 0.1))),
                  child: ValueListenableBuilder<String>(
                    valueListenable: globalThemeNotifier,
                    builder: (context, currentTheme, child) {
                      return ListTile(
                        leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                                color: Colors.purple.shade50,
                                borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.palette_rounded,
                                color: Colors.purpleAccent)),
                        title: const Text('界面皮肤引擎',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        trailing: DropdownButton<String>(
                          value: currentTheme,
                          underline: const SizedBox(),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded,
                              color: Colors.purpleAccent),
                          items: const [
                            DropdownMenuItem(
                                value: 'light', child: Text('极简白板 / 日间')),
                            DropdownMenuItem(
                                value: 'dark', child: Text('深空极客 / 暗黑')),
                          ],
                          onChanged: (value) async {
                            if (value != null) {
                              globalThemeNotifier.value = value;
                              await DatabaseHelper.instance
                                  .saveSetting('app_theme', value);
                            }
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
