import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../widgets/shiroha_settings_components.dart';

enum ExternalAgentAccessPhase { setup, disabled, connecting, enabled, failed }

/// Presentation only; the owning Application service supplies access decisions.
class ExternalAgentSettingsBody extends StatelessWidget {
  const ExternalAgentSettingsBody({
    super.key,
    required this.clientName,
    required this.phase,
    required this.directWriteEnabled,
    required this.onOpenReview,
    this.allContentConfigured = true,
    this.pendingCount,
    this.onConnect,
    this.onAccessChanged,
    this.onDirectWriteChanged,
    this.studyStatisticsAllowed = false,
    this.onStudyStatisticsChanged,
    this.error,
    this.connectionSettings,
    this.deviceSettings,
    this.remoteTarget = false,
  });

  final String clientName;
  final ExternalAgentAccessPhase phase;
  final bool directWriteEnabled;
  final bool allContentConfigured;
  final int? pendingCount;
  final VoidCallback? onConnect;
  final ValueChanged<bool>? onAccessChanged;
  final ValueChanged<bool>? onDirectWriteChanged;
  final bool studyStatisticsAllowed;
  final ValueChanged<bool>? onStudyStatisticsChanged;
  final VoidCallback onOpenReview;
  final String? error;
  final Widget? connectionSettings;
  final Widget? deviceSettings;
  final bool remoteTarget;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (remoteTarget) {
      return ShirohaPageBody(children: [
        if (deviceSettings != null) deviceSettings!,
        const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
                '请在手机 Shiroha 中开启访问。手机独立决定题库、资料、学习统计权限和题目保存方式。Windows Shiroha 需保持运行。')),
        if (error != null) Text(error!, style: TextStyle(color: colors.error)),
      ]);
    }
    final enabled = phase == ExternalAgentAccessPhase.enabled;
    final connecting = phase == ExternalAgentAccessPhase.connecting;
    final status = switch (phase) {
      ExternalAgentAccessPhase.setup => '尚未开启访问',
      ExternalAgentAccessPhase.disabled => '访问已关闭',
      ExternalAgentAccessPhase.connecting => '正在连接…',
      ExternalAgentAccessPhase.enabled => '已允许访问',
      ExternalAgentAccessPhase.failed => '连接需要检查',
    };
    return ShirohaPageBody(children: [
      if (deviceSettings != null) ...[
        deviceSettings!,
        const SizedBox(height: 16)
      ],
      ShirohaSettingsCard(children: [
        SwitchListTile.adaptive(
          key: const Key('external-access-switch'),
          secondary: Icon(Icons.link, color: colors.primary),
          title: Text(clientName),
          subtitle: Text(status),
          value: enabled || connecting,
          onChanged:
              phase == ExternalAgentAccessPhase.setup ? null : onAccessChanged,
        ),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('全部题库与资料'),
          subtitle: Text(enabled && !allContentConfigured
              ? '旧配置仍生效，重新开启后更新'
              : '开启后允许外部 Agent 读取'),
        ),
        if (phase == ExternalAgentAccessPhase.setup)
          Padding(
            padding: const EdgeInsets.all(DesignTokens.cardInternalPadding),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('external-connect'),
                onPressed: onConnect,
                child: const Text('连接并开启访问'),
              ),
            ),
          ),
        SwitchListTile.adaptive(
          key: const Key('external-study-statistics'),
          secondary: const Icon(Icons.insights_outlined),
          title: const Text('允许读取学习统计'),
          subtitle: const Text('按已授权题库查询进度、待复习与薄弱题。修改后旧上下文失效，需重新连接。'),
          value: studyStatisticsAllowed,
          onChanged: onStudyStatisticsChanged,
        ),
      ]),
      if (connecting)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: LinearProgressIndicator(),
        ),
      if (error case final message?)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(message,
              key: const Key('external-access-error'),
              style: TextStyle(color: colors.error)),
        ),
      const SizedBox(height: DesignTokens.sectionGap),
      const ShirohaSectionLabel('题目保存方式'),
      const SizedBox(height: 8),
      ShirohaSettingsCard(children: [
        SwitchListTile.adaptive(
          key: const Key('external-direct-write-switch'),
          secondary: const Icon(Icons.save_outlined),
          title: const Text('允许直接写入题库'),
          subtitle: Text(!enabled
              ? '开启访问后可设置'
              : directWriteEnabled
                  ? '新生成题目直接入库，无需审核'
                  : '默认生成待审核草稿'),
          value: directWriteEnabled,
          onChanged: enabled ? onDirectWriteChanged : null,
        ),
      ]),
      const SizedBox(height: DesignTokens.sectionGap),
      ShirohaSettingsCard(children: [
        ListTile(
          key: const Key('external-open-review'),
          leading: const Icon(Icons.fact_check_outlined),
          title: Text(pendingCount == null ? '待审核草稿' : '待审核草稿 · $pendingCount'),
          subtitle: Text(directWriteEnabled ? '已有草稿仍需审核' : '确认后才会正式入库'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onOpenReview,
        ),
      ]),
      if (connectionSettings case final settings?) ...[
        const SizedBox(height: DesignTokens.sectionGap),
        ShirohaSettingsCard(children: [
          ExpansionTile(
            key: const Key('external-connection-settings'),
            leading: const Icon(Icons.tune),
            title: const Text('连接设置'),
            children: [settings],
          ),
        ]),
      ],
    ]);
  }
}
