import 'package:flutter/material.dart';

import '../../application/agent/agent_config_service.dart';
import '../../data/repositories/ai_engine_repository.dart';
import 'agent_settings_screen.dart';
import 'ai_engine_management_screen.dart';

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({
    super.key,
    required this.engineRepository,
    this.agentSettingsService,
  });

  final AiEngineRepository engineRepository;
  final AgentSettingsService? agentSettingsService;

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  String _textEngineName = '未配置';
  String _visionEngineName = '未配置';
  String _ocrEngineName = '未配置';
  bool _isSummaryLoading = true;
  String? _summaryLoadError;

  @override
  void initState() {
    super.initState();
    _loadActiveSummary();
  }

  Future<void> _loadActiveSummary() async {
    try {
      final textEngine = await widget.engineRepository.getActiveTextEngine();
      final visionEngine =
          await widget.engineRepository.getActiveVisionEngine();
      final ocrEngine = await widget.engineRepository.getActiveOcrEngine();
      if (!mounted) return;
      setState(() {
        _textEngineName = textEngine?.name ?? '点击配置';
        _visionEngineName = visionEngine?.name ?? '点击配置';
        _ocrEngineName = ocrEngine?.name ?? '点击配置';
        _isSummaryLoading = false;
        _summaryLoadError = null;
      });
    } catch (error) {
      debugPrint('AI service summary load failed: ${error.runtimeType}');
      if (!mounted) return;
      setState(() {
        _isSummaryLoading = false;
        _summaryLoadError = '暂时无法读取 AI 服务状态';
      });
    }
  }

  void _retryActiveSummary() {
    setState(() {
      _isSummaryLoading = true;
      _summaryLoadError = null;
    });
    _loadActiveSummary();
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

  void _openAgentSettings() {
    final settingsService = widget.agentSettingsService;
    if (settingsService == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentSettingsScreen(
          settingsService: settingsService,
          onOpenProfileSettings: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  Widget _buildCard(List<Widget> children) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: theme.brightness == Brightness.dark
            ? const []
            : [
                BoxShadow(
                  color: const Color(0xFF375078).withValues(alpha: 0.06),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 64,
                  color: theme.colorScheme.outlineVariant,
                ),
              children[index],
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
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
            const _AiSectionLabel('能力配置'),
            const SizedBox(height: 8),
            if (_isSummaryLoading)
              _buildCard([
                const Padding(
                  key: ValueKey<String>('ai-service-summary-loading'),
                  padding: EdgeInsets.all(20),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 12),
                      Text('正在读取 AI 服务状态…'),
                    ],
                  ),
                ),
              ])
            else if (_summaryLoadError case final message?)
              _buildCard([
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(message)),
                      TextButton(
                        key: const ValueKey<String>(
                          'ai-service-summary-retry',
                        ),
                        onPressed: _retryActiveSummary,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ])
            else
              _buildCard([
                _AiServiceRow(
                  icon: Icons.text_fields_rounded,
                  title: '文本模型',
                  subtitle: _textEngineName,
                  accentColor: theme.colorScheme.primary,
                  onTap: () => _openEngine('text'),
                ),
                _AiServiceRow(
                  icon: Icons.image_outlined,
                  title: '图片理解',
                  subtitle: _visionEngineName,
                  accentColor: theme.colorScheme.secondary,
                  onTap: () => _openEngine('vision'),
                ),
                _AiServiceRow(
                  icon: Icons.document_scanner_outlined,
                  title: '文档识别',
                  subtitle: _ocrEngineName,
                  accentColor: theme.colorScheme.secondary,
                  onTap: () => _openEngine('ocr'),
                ),
              ]),
            if (widget.agentSettingsService != null) ...[
              const SizedBox(height: 24),
              const _AiSectionLabel('Agent'),
              const SizedBox(height: 8),
              _buildCard([
                _AiServiceRow(
                  key: const ValueKey<String>('ai-service-agent-settings-row'),
                  icon: Icons.auto_awesome_outlined,
                  title: 'Shiroha Agent 设置',
                  subtitle: '联网、温度、推理强度等',
                  accentColor: theme.colorScheme.secondary,
                  onTap: _openAgentSettings,
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

class _AiServiceRow extends StatelessWidget {
  const _AiServiceRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.accentColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ListTile(
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: accentColor.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.18 : 0.1,
          ),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, size: 21, color: accentColor),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.onSurface,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: colors.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}

class _AiSectionLabel extends StatelessWidget {
  const _AiSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
