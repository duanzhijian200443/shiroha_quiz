import 'package:flutter/material.dart';
import '../../application/external/external_device_connection.dart';
import '../widgets/shiroha_settings_components.dart';

class ExternalDeviceSettings extends StatelessWidget {
  const ExternalDeviceSettings(
      {super.key,
      required this.connection,
      required this.onSelected,
      this.onRecover});
  final ExternalDeviceConnection connection;
  final ValueChanged<ExternalDeviceTarget>? onSelected;
  final VoidCallback? onRecover;
  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
      stream: connection.changes,
      builder: (context, _) {
        final selected = connection.selection.target;
        final choices = <ExternalDeviceTarget>{
          const ExternalDeviceTarget.unselected(),
          ...connection.targets,
          selected,
        };
        final state = connection.recovering
            ? '正在核对上次连接'
            : switch (connection.phase) {
                ExternalDevicePhase.disconnected =>
                  selected.kind == ExternalDeviceKind.unselected
                      ? '未选择设备'
                      : '未连接',
                ExternalDevicePhase.waitingAuthorization => '等待目标 App 授权',
                ExternalDevicePhase.connected => '已连接',
                ExternalDevicePhase.ending => '正在结束旧连接',
                ExternalDevicePhase.busy => '连接正被其他聊天占用',
                ExternalDevicePhase.needsAttention => '需要处理：上次连接清理未确认',
              };
        String label(ExternalDeviceTarget target) => switch (target.kind) {
              ExternalDeviceKind.unselected => '未选择',
              ExternalDeviceKind.windows => '本机 Windows',
              ExternalDeviceKind.android => '已配对的 Android 手机',
            };
        return ShirohaSettingsCard(children: [
          ListTile(
              title: const Text('当前设备'),
              subtitle: DropdownButton<ExternalDeviceTarget>(
                  key: const Key('external-device-selector'),
                  value: selected,
                  isExpanded: true,
                  items: [
                    for (final target in choices)
                      DropdownMenuItem(
                          value: target, child: Text(label(target)))
                  ],
                  onChanged: onSelected == null ||
                          connection.changing ||
                          connection.phase == ExternalDevicePhase.needsAttention
                      ? null
                      : (target) {
                          if (target != null) onSelected?.call(target);
                        })),
          ListTile(
              key: const Key('external-device-status'),
              title: Text(state),
              subtitle: const Text('切换前会结束旧连接。切换后请在 Codex 中重新连接。')),
          if (connection.canRecover)
            Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                    key: const Key('external-device-recover'),
                    onPressed: onRecover,
                    child: const Text('核对并恢复上次连接'))),
          if (connection.recovering) const LinearProgressIndicator(),
        ]);
      });
}
