import 'package:flutter/material.dart';
import '../../data/repositories/ai_engine_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../main.dart'; // 获取 globalThemeNotifier
import 'ai_engine_management_screen.dart';

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});
  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  String _textEngineName = '未配置';
  String _visionEngineName = '未配置';
  String _ocrEngineName = '未配置';

  @override
  void initState() {
    super.initState();
    _loadActiveSummary();
  }

  Future<void> _loadActiveSummary() async {
    final textEngine = await AiEngineRepository.instance.getActiveTextEngine();
    final visionEngine =
        await AiEngineRepository.instance.getActiveVisionEngine();
    final ocrEngine = await AiEngineRepository.instance.getActiveOcrEngine();
    if (mounted) {
      setState(() {
        _textEngineName = textEngine?.name ?? '点击去配置';
        _visionEngineName = visionEngine?.name ?? '点击去配置';
        _ocrEngineName = ocrEngine?.name ?? '点击去配置';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
          title: const Text('系统偏好与 AI 引擎',
              style: TextStyle(fontWeight: FontWeight.bold))),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
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
                side: BorderSide(color: Colors.grey.withValues(alpha: 0.1))),
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
                                builder: (_) => const AiEngineManagementScreen(
                                    engineType: 'text')))
                        .then((_) => _loadActiveSummary());
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
                      style:
                          const TextStyle(fontSize: 12, color: Colors.orange)),
                  trailing: const Icon(Icons.arrow_forward_ios_rounded,
                      size: 14, color: Colors.grey),
                  onTap: () {
                    Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const AiEngineManagementScreen(
                                    engineType: 'vision')))
                        .then((_) => _loadActiveSummary());
                  },
                ),
                const Divider(height: 1, indent: 64),
                ListTile(
                  leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: Colors.teal.shade50,
                          borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.document_scanner_rounded,
                          color: Colors.teal)),
                  title: const Text('文档 OCR 解析引擎',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(_ocrEngineName,
                      style: const TextStyle(fontSize: 12, color: Colors.teal)),
                  trailing: const Icon(Icons.arrow_forward_ios_rounded,
                      size: 14, color: Colors.grey),
                  onTap: () {
                    Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const AiEngineManagementScreen(
                                    engineType: 'ocr')))
                        .then((_) => _loadActiveSummary());
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
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
                side: BorderSide(color: Colors.grey.withValues(alpha: 0.1))),
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
                      DropdownMenuItem(value: 'dark', child: Text('深空极客 / 暗黑')),
                    ],
                    onChanged: (value) async {
                      if (value != null) {
                        globalThemeNotifier.value = value;
                        await SettingsRepository.instance.setAppTheme(value);
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
