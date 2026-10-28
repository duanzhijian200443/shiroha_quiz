import 'dart:async';
import 'package:flutter/material.dart';
import '../../application/external/android_device_access.dart';
import '../../application/external/android_foreground_access.dart';
import '../widgets/shiroha_settings_components.dart';

final class AndroidDeviceAccessPanel extends StatefulWidget {
  const AndroidDeviceAccessPanel({super.key, required this.access});
  final AndroidDeviceAccess access;
  @override
  State<AndroidDeviceAccessPanel> createState() => _AndroidPanelState();
}

final class _AndroidPanelState extends State<AndroidDeviceAccessPanel> {
  StreamSubscription<void>? _changes;
  @override
  void initState() {
    super.initState();
    _changes = widget.access.changes.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(widget.access.inspect());
  }

  void _run(Future<void> Function() work) {
    unawaited(work().catchError((Object _) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('操作未完成，请检查设备连接状态。')));
      }
    }));
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    unawaited(widget.access.cancelPending());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.access.state;
    final off = state.phase == AndroidAccessPhase.off;
    final status = switch (state.phase) {
      AndroidAccessPhase.off => '访问已关闭',
      AndroidAccessPhase.preparing =>
        state.listening ? '等待电脑 · 请运行桌面连接助手' : '正在准备本机连接',
      AndroidAccessPhase.ready =>
        state.connected ? 'Codex 已连接 · 只读访问' : '已允许只读访问 · 可启动或重启 Codex 连接',
      AndroidAccessPhase.suspended => '已暂停 · 返回前台后重启 Codex 连接',
      AndroidAccessPhase.draining => '正在结算原连接',
      AndroidAccessPhase.recovery => '结算需要检查 · 访问保持关闭',
    };
    return Scaffold(
        appBar: AppBar(title: const Text('外部 Agent')),
        body: ShirohaPageBody(children: [
          ShirohaSettingsCard(children: [
            ListTile(
                leading: const Icon(Icons.phone_android),
                title: const Text('Codex · 当前手机'),
                subtitle:
                    Text(state.available ? status : '当前安装未开放 Android 连接')),
            const ListTile(
                title: Text('本机题库 · 仅只读'),
                subtitle: Text('本次开启 30 分钟。题目与必要元数据可经 Codex 发送给模型服务。')),
            if (state.available && !state.paired)
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                      key: const Key('android-pair'),
                      onPressed: off ? () => _run(widget.access.pair) : null,
                      child: const Text('首次连接电脑'))),
            if (state.paired)
              SwitchListTile.adaptive(
                  key: const Key('android-enable'),
                  title: const Text('允许 Codex 读取'),
                  value: !off && state.phase != AndroidAccessPhase.recovery,
                  onChanged: state.available &&
                          state.phase != AndroidAccessPhase.draining &&
                          state.phase != AndroidAccessPhase.recovery
                      ? (enabled) => _run(enabled
                          ? widget.access.enable
                          : widget.access.disable)
                      : null),
            if (!off)
              TextButton(
                  onPressed: () => _run(widget.access.disable),
                  child: const Text('关闭访问')),
            if (state.expiresAt != null)
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                      '到期时间：${state.expiresAt!.toLocal().toIso8601String().substring(11, 19)}')),
          ]),
          if (state.awaitingConfirmation)
            ShirohaSettingsCard(children: [
              const ListTile(
                  title: Text('确认这台电脑'),
                  subtitle: Text('请对照电脑助手显示的完整客户端证书指纹。确认后只完成配对，访问仍关闭。')),
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(state.clientDigest ?? '')),
              FilledButton(
                  key: const Key('android-confirm-pair'),
                  onPressed: widget.access.confirmPairing,
                  child: const Text('指纹一致，确认配对')),
            ]),
          if (state.error != null)
            Padding(
                padding: const EdgeInsets.all(16), child: Text(state.error!)),
          ShirohaSettingsCard(children: [
            ExpansionTile(title: const Text('连接信息'), children: [
              ListTile(
                  title: const Text('局域网地址'),
                  subtitle: SelectableText('${state.address ?? "不可用"}:46443')),
              ListTile(
                  title: const Text('设备公钥指纹'),
                  subtitle: SelectableText(state.deviceId ?? '首次连接时读取')),
              ListTile(
                  title: const Text('设备证书指纹'),
                  subtitle:
                      SelectableText(state.certificateDigest ?? '首次连接时读取')),
              if (state.profileId != null)
                ListTile(
                    title: const Text('手机配置'),
                    subtitle: SelectableText(state.profileId!)),
            ])
          ]),
        ]));
  }
}
