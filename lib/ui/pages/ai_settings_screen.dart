import 'package:flutter/material.dart';

import '../../data/repositories/ai_engine_repository.dart';
import 'ai_engine_management_screen.dart';

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({
    super.key,
    required this.engineRepository,
  });

  final AiEngineRepository engineRepository;

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  static const Color _pageBackground = Color(0xFFF4F7FB);
  static const Color _primaryText = Color(0xFF17233D);
  static const Color _secondaryText = Color(0xFF73809A);
  static const Color _brandBlue = Color(0xFF4C6ED7);
  static const Color _divider = Color(0xFFE8EEF7);

  String _textEngineName = '未配置';
  String _visionEngineName = '未配置';
  String _ocrEngineName = '未配置';

  @override
  void initState() {
    super.initState();
    _loadActiveSummary();
  }

  Future<void> _loadActiveSummary() async {
    final textEngine = await widget.engineRepository.getActiveTextEngine();
    final visionEngine = await widget.engineRepository.getActiveVisionEngine();
    final ocrEngine = await widget.engineRepository.getActiveOcrEngine();
    if (!mounted) return;
    setState(() {
      _textEngineName = textEngine?.name ?? '点击配置';
      _visionEngineName = visionEngine?.name ?? '点击配置';
      _ocrEngineName = ocrEngine?.name ?? '点击配置';
    });
  }

  void _openEngine(String engineType) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => AiEngineManagementScreen(
              engineType: engineType,
              engineRepository: widget.engineRepository,
            ),
          ),
        )
        .then((_) => _loadActiveSummary());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? theme.scaffoldBackgroundColor : _pageBackground,
      appBar: AppBar(
        centerTitle: true,
        title: const Text(
          'AI 服务',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                '配置用于学习辅助的 AI 服务',
                style: TextStyle(
                  color: isDark ? Colors.white60 : _secondaryText,
                  fontSize: 13,
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : const Color(0xFFE9EEF6),
                ),
                boxShadow: isDark
                    ? const []
                    : [
                        BoxShadow(
                          color:
                              const Color(0xFF375078).withValues(alpha: 0.06),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Column(
                  children: [
                    _AiServiceRow(
                      icon: Icons.text_fields_rounded,
                      title: '文本解答模型',
                      subtitle: _textEngineName,
                      onTap: () => _openEngine('text'),
                    ),
                    const Divider(
                      height: 1,
                      thickness: 1,
                      indent: 64,
                      color: _divider,
                    ),
                    _AiServiceRow(
                      icon: Icons.image_outlined,
                      title: '图片理解模型',
                      subtitle: _visionEngineName,
                      onTap: () => _openEngine('vision'),
                    ),
                    const Divider(
                      height: 1,
                      thickness: 1,
                      indent: 64,
                      color: _divider,
                    ),
                    _AiServiceRow(
                      icon: Icons.document_scanner_outlined,
                      title: '文档识别服务',
                      subtitle: _ocrEngineName,
                      onTap: () => _openEngine('ocr'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiServiceRow extends StatelessWidget {
  const _AiServiceRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: isDark
              ? _AiSettingsScreenState._brandBlue.withValues(alpha: 0.18)
              : const Color(0xFFEEF3FF),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(
          icon,
          size: 21,
          color: isDark
              ? Theme.of(context).colorScheme.primary
              : _AiSettingsScreenState._brandBlue,
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isDark ? Colors.white : _AiSettingsScreenState._primaryText,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color:
              isDark ? Colors.white60 : _AiSettingsScreenState._secondaryText,
          fontSize: 12,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: isDark ? Colors.white38 : const Color(0xFFA5AFC0),
      ),
      onTap: onTap,
    );
  }
}
