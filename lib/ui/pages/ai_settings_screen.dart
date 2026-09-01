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
  final Map<_AiCapability, _AiCapabilitySummary> _summaries = {
    for (final capability in _AiCapability.values)
      capability: const _AiCapabilitySummary.loading(),
  };

  @override
  void initState() {
    super.initState();
    _loadActiveSummary();
  }

  Future<void> _loadActiveSummary() async {
    await Future.wait(
      _AiCapability.values.map(_loadCapabilitySummary),
    );
  }

  Future<void> _loadCapabilitySummary(_AiCapability capability) async {
    try {
      final engine = switch (capability) {
        _AiCapability.text =>
          await widget.engineRepository.getActiveTextEngine(),
        _AiCapability.vision =>
          await widget.engineRepository.getActiveVisionEngine(),
        _AiCapability.ocr => await widget.engineRepository.getActiveOcrEngine(),
      };
      if (!mounted) return;
      setState(() {
        _summaries[capability] = _AiCapabilitySummary.loaded(engine?.name);
      });
    } catch (error) {
      debugPrint(
        'AI ${capability.name} summary load failed: ${error.runtimeType}',
      );
      if (!mounted) return;
      setState(() {
        _summaries[capability] = const _AiCapabilitySummary.failed();
      });
    }
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
            _buildCard([
              _AiServiceRow(
                key: const ValueKey<String>('ai-service-text-row'),
                icon: Icons.text_fields_rounded,
                title: '文本模型',
                subtitle: _summaries[_AiCapability.text]!.subtitle,
                accentColor: theme.colorScheme.primary,
                onTap: () => _openEngine('text'),
              ),
              _AiServiceRow(
                key: const ValueKey<String>('ai-service-vision-row'),
                icon: Icons.image_outlined,
                title: '图片理解',
                subtitle: _summaries[_AiCapability.vision]!.subtitle,
                accentColor: theme.colorScheme.secondary,
                onTap: () => _openEngine('vision'),
              ),
              _AiServiceRow(
                key: const ValueKey<String>('ai-service-ocr-row'),
                icon: Icons.document_scanner_outlined,
                title: '文档识别',
                subtitle: _summaries[_AiCapability.ocr]!.subtitle,
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

enum _AiCapability { text, vision, ocr }

class _AiCapabilitySummary {
  const _AiCapabilitySummary.loading()
      : name = null,
        failed = false,
        loading = true;

  const _AiCapabilitySummary.loaded(this.name)
      : failed = false,
        loading = false;

  const _AiCapabilitySummary.failed()
      : name = null,
        failed = true,
        loading = false;

  final String? name;
  final bool failed;
  final bool loading;

  String get subtitle {
    if (loading) return '正在读取…';
    if (failed) return '暂时无法读取 · 点击配置';
    return name ?? '点击配置';
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
