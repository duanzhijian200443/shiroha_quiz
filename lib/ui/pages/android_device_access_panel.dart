import 'dart:async';
import 'package:flutter/material.dart';
import '../../application/external/android_device_access.dart';
import '../../application/external/android_foreground_access.dart';
import '../../application/external/external_authorization.dart';
import '../../application/external/first_party_stage_approval.dart';
import '../widgets/shiroha_settings_components.dart';

final class AndroidDeviceAccessPanel extends StatefulWidget {
  const AndroidDeviceAccessPanel(
      {super.key, required this.access, this.onOpenReview});
  final AndroidDeviceAccess access;
  final VoidCallback? onOpenReview;
  @override
  State<AndroidDeviceAccessPanel> createState() => _AndroidPanelState();
}

final class _AndroidPanelState extends State<AndroidDeviceAccessPanel> {
  StreamSubscription<void>? _changes;
  StreamSubscription<void>? _stageChanges;
  FirstPartyStageApprovalView? _stageView;
  @override
  void initState() {
    super.initState();
    _changes = widget.access.changes.listen((_) {
      if (mounted) {
        _watchStage();
        setState(() {});
      }
    });
    unawaited(widget.access.inspect());
  }

  void _watchStage() {
    final state = widget.access.state;
    if (state.phase != AndroidAccessPhase.ready ||
        state.generationMode != ExternalGenerationMode.confirm) {
      _stageView?.close();
      _stageView = null;
      unawaited(_stageChanges?.cancel());
      _stageChanges = null;
      return;
    }
    if (_stageView != null) return;
    final view = _stageView = widget.access.openStageApprovalView();
    _stageChanges = view?.changes.listen((_) {
      if (mounted) setState(() {});
    });
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
    _stageView?.close();
    unawaited(_stageChanges?.cancel());
    unawaited(widget.access.cancelPending());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.access.state;
    final off = state.phase == AndroidAccessPhase.off;
    final generation = state.generationMode != null;
    final canChangePolicy = state.available &&
        state.paired &&
        state.policyReady &&
        !state.policyChanging &&
        (off || state.phase == AndroidAccessPhase.ready);
    final pendingStage = _stageView?.pending;
    final status = switch (state.phase) {
      AndroidAccessPhase.off => '访问已关闭',
      AndroidAccessPhase.preparing =>
        state.listening ? '等待电脑 · 请运行桌面连接助手' : '正在准备本机连接',
      AndroidAccessPhase.ready =>
        state.connected ? 'Codex 已连接' : '访问已开启 · 可启动或重启 Codex 连接',
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
            ListTile(
                title: Text(generation ? '本机题库 · 读取与生成' : '本机题库 · 仅只读'),
                subtitle: const Text(
                    '本次开启 30 分钟。授权范围内的题目与必要元数据可经 Codex 发送给模型服务。资料正文须单独允许。')),
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
                  title: const Text('允许 Codex 访问'),
                  value: !off && state.phase != AndroidAccessPhase.recovery,
                  onChanged: state.available &&
                          !state.policyChanging &&
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
          if (state.paired)
            ShirohaSettingsCard(children: [
              SwitchListTile.adaptive(
                  key: const Key('android-file-content'),
                  title: const Text('允许读取资料正文'),
                  subtitle: Text(
                      '${state.allContent ? "范围覆盖本安装中现有及之后加入的 File Library 资料。" : state.hasFileScope ? "仅覆盖原策略中明确授权的文件范围；不会扩大范围。" : "原策略没有文件范围，不能开启资料正文读取。"}'
                      '获准正文可经 Codex 发送给模型服务。保留题库权限和生成模式；变更会关闭旧访问，保存后需重新开启连接。'),
                  value: state.fileContentAllowed,
                  onChanged: canChangePolicy &&
                          (state.fileContentAllowed ||
                              state.allContent ||
                              state.hasFileScope)
                      ? (allowed) => _run(
                          () => widget.access.setFileContentAllowed(allowed))
                      : null),
              SwitchListTile.adaptive(
                  key: const Key('android-study-statistics'),
                  title: const Text('允许读取学习统计'),
                  subtitle:
                      const Text('仅限已授权题库的进度、待复习与薄弱题。修改会关闭旧访问，保存后需重新开启连接。'),
                  value: state.studyStatisticsAllowed,
                  onChanged: canChangePolicy
                      ? (allowed) => _run(() =>
                          widget.access.setStudyStatisticsAllowed(allowed))
                      : null),
              SwitchListTile.adaptive(
                  key: const Key('android-generation'),
                  title: const Text('允许生成题目与查询提案'),
                  subtitle: const Text(
                      '保留当前题库范围。首次开启保存为草稿，由你稍后审核。变更会关闭旧访问，保存后需重新开启连接。'),
                  value: generation,
                  onChanged: canChangePolicy
                      ? (enabled) => _run(() => widget.access.setGenerationMode(
                          enabled ? ExternalGenerationMode.review : null))
                      : null),
              if (state.generationMode == ExternalGenerationMode.confirm)
                ListTile(
                    title: const Text('保留逐次发布确认'),
                    subtitle: const Text('本模式须保持此页打开以确认发布；之后仍需本地 Review。'),
                    trailing: TextButton(
                        onPressed: canChangePolicy
                            ? () => _run(() => widget.access.setGenerationMode(
                                ExternalGenerationMode.review))
                            : null,
                        child: const Text('改为保存草稿'))),
              SwitchListTile.adaptive(
                  key: const Key('android-direct'),
                  title: const Text('允许直接写入题库'),
                  subtitle:
                      const Text('仅随后提交的新批次可通过原检查直接保存。已有草稿仍需审核；模式切换不会补入库。'),
                  value: state.generationMode == ExternalGenerationMode.direct,
                  onChanged: generation && canChangePolicy
                      ? (enabled) => _run(() => widget.access.setGenerationMode(
                          enabled
                              ? ExternalGenerationMode.direct
                              : ExternalGenerationMode.review))
                      : null),
              ListTile(
                  key: const Key('android-review'),
                  leading: const Icon(Icons.inbox_outlined),
                  title: const Text('生成题草稿'),
                  subtitle: const Text('访问关闭后仍可在手机审核和练习已保存的题目。'),
                  onTap: widget.onOpenReview),
            ]),
          if (pendingStage != null)
            ShirohaSettingsCard(children: [
              ListTile(
                  title: const Text('确认本次草稿发布'),
                  subtitle: Text('目标：${pendingStage.targetLabel}。发布后仍待本地审核。')),
              FilledButton(
                  onPressed: () =>
                      _run(() => _stageView!.confirm(pendingStage)),
                  child: const Text('允许发布草稿')),
              TextButton(
                  onPressed: () => _stageView!.reject(pendingStage),
                  child: const Text('拒绝本次发布')),
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
