import 'package:flutter/material.dart';

import '../../application/agent/agent_config_service.dart';
import '../../application/ai_config/ai_config_service.dart';
import '../../domain/ai_config/ai_config_contracts.dart';
import '../theme/design_tokens.dart';
import '../widgets/shiroha_settings_components.dart';
import 'agent_settings_screen.dart';
import 'ai_model_selector_screen.dart';
import 'ai_provider_settings_screen.dart';

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({
    super.key,
    required this.configService,
    this.agentSettingsService,
  });

  final AiConfigPresentationService configService;
  final AgentSettingsService? agentSettingsService;

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  final Map<AiCapabilitySlot, _AiCapabilitySummary> _summaries = {
    for (final slot in AiCapabilitySlot.values)
      slot: const _AiCapabilitySummary.loading(),
  };

  @override
  void initState() {
    super.initState();
    _loadActiveSummary();
  }

  Future<void> _loadActiveSummary() async {
    await Future.wait(AiCapabilitySlot.values.map(_loadCapabilitySummary));
  }

  Future<void> _loadCapabilitySummary(AiCapabilitySlot slot) async {
    try {
      final summary = await widget.configService.bindingSummary(slot);
      if (!mounted) return;
      setState(() {
        _summaries[slot] = _AiCapabilitySummary.loaded(
          summary?.model.displayName,
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _summaries[slot] = const _AiCapabilitySummary.failed();
      });
    }
  }

  Future<void> _openModelSelector(AiCapabilitySlot slot) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AiModelSelectorScreen(
          service: widget.configService,
          slot: slot,
        ),
      ),
    );
    if (mounted) await _loadActiveSummary();
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

  void _openProviderSettings() {
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute<void>(
            builder: (_) => AiProviderSettingsScreen(
              service: widget.configService,
            ),
          ),
        )
        .then((_) => _loadActiveSummary());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('AI 服务')),
      body: ShirohaPageBody(
        children: <Widget>[
          const ShirohaSectionLabel('能力配置'),
          const SizedBox(height: 8),
          ShirohaSettingsCard(
            children: <Widget>[
              _AiServiceRow(
                key: const ValueKey<String>('ai-service-text-row'),
                icon: Icons.text_fields_rounded,
                title: '文本模型',
                subtitle: _summaries[AiCapabilitySlot.textModel]!.subtitle,
                accentColor: theme.colorScheme.primary,
                onTap: () => _openModelSelector(AiCapabilitySlot.textModel),
              ),
              _AiServiceRow(
                key: const ValueKey<String>('ai-service-vision-row'),
                icon: Icons.image_outlined,
                title: '图片理解',
                subtitle:
                    _summaries[AiCapabilitySlot.imageUnderstanding]!.subtitle,
                accentColor: theme.colorScheme.secondary,
                onTap: () =>
                    _openModelSelector(AiCapabilitySlot.imageUnderstanding),
              ),
              _AiServiceRow(
                key: const ValueKey<String>('ai-service-ocr-row'),
                icon: Icons.document_scanner_outlined,
                title: '文档识别',
                subtitle:
                    _summaries[AiCapabilitySlot.documentRecognition]!.subtitle,
                accentColor: theme.colorScheme.secondary,
                onTap: () => _openModelSelector(
                  AiCapabilitySlot.documentRecognition,
                ),
              ),
            ],
          ),
          if (widget.agentSettingsService != null) ...<Widget>[
            const SizedBox(height: DesignTokens.sectionGap),
            const ShirohaSectionLabel('Agent'),
            const SizedBox(height: 8),
            ShirohaSettingsCard(
              children: <Widget>[
                _AiServiceRow(
                  key: const ValueKey<String>(
                    'ai-service-agent-settings-row',
                  ),
                  icon: Icons.auto_awesome_outlined,
                  title: 'Shiroha Agent 设置',
                  subtitle: '联网、温度、推理强度等',
                  accentColor: theme.colorScheme.secondary,
                  onTap: _openAgentSettings,
                ),
              ],
            ),
          ],
          const SizedBox(height: DesignTokens.sectionGap),
          const ShirohaSectionLabel('基础设置'),
          const SizedBox(height: 8),
          ShirohaSettingsCard(
            children: <Widget>[
              _AiServiceRow(
                key: const ValueKey<String>('ai-service-provider-row'),
                icon: Icons.key_outlined,
                title: 'API 提供商与密钥',
                subtitle: '管理 Provider、连接状态与模型同步',
                accentColor: theme.colorScheme.primary,
                onTap: _openProviderSettings,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '能力模型与 API 凭据分开管理；密钥不会显示在模型选择页面。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

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
    if (failed) return '暂时无法读取 · 点击选择';
    return name ?? '尚未绑定模型';
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
          borderRadius: BorderRadius.circular(
            DesignTokens.compactIconContainerRadius,
          ),
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
