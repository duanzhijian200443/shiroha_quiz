import 'dart:async';
import 'package:flutter/material.dart';
import '../../application/external/first_party_external_access.dart';
import '../../application/external/external_trust_core.dart';
import '../../application/generated_question/generated_local_authority.dart';

/// Local control has no pairing simulation, credential input or external route.
final class FirstPartyExternalControl extends StatefulWidget {
  const FirstPartyExternalControl({super.key, required this.access});
  final FirstPartyExternalAccess access;
  @override
  State<FirstPartyExternalControl> createState() => _ControlState();
}

final class _ControlState extends State<FirstPartyExternalControl> {
  FirstPartyExternalStatus _status = const FirstPartyExternalStatus();
  bool _busy = false;
  String? _error;
  int _minutes = 10;
  Timer? _timer;
  bool get _current => mounted && widget.access.isCurrent;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted &&
        !_current &&
        (_status.profileId != null || _status.enabled || _status.connected)) {
      setState(() => _status = const FirstPartyExternalStatus());
    }
    if (!_current || _busy) return;
    await _action(() async {});
  }

  Future<void> _action(Future<void> Function() action) async {
    if (!_current || _busy) return;
    final access = widget.access;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      final status = await access.status();
      if (_current && identical(access, widget.access)) {
        setState(() => _status = status);
      }
    } catch (_) {
      if (_current) {
        setState(() {
          _status = const FirstPartyExternalStatus();
          _error = '操作不可用，请重新选择并检查当前连接与授权。';
        });
      }
    } finally {
      if (mounted && identical(access, widget.access)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _select() => _action(() async {
        String? after;
        do {
          final page = await widget.access.profiles(afterId: after);
          if (!mounted || !widget.access.isCurrent) return;
          final choice = await showDialog<String>(
              context: context,
              builder: (context) =>
                  SimpleDialog(title: const Text('选择授权 Profile'), children: [
                    for (final profile in page.items)
                      SimpleDialogOption(
                          onPressed: profile.revokedAtUtcMs != null
                              ? null
                              : () => Navigator.pop(
                                  context, profile.clientProfileId),
                          child: Text(profile.displayName)),
                    if (page.nextId != null)
                      SimpleDialogOption(
                          onPressed: () => Navigator.pop(context, ''),
                          child: const Text('更多 Profile')),
                  ]));
          if (!_current || choice == null) return;
          if (choice.isNotEmpty) {
            await widget.access.select(choice);
            return;
          }
          after = page.nextId;
        } while (after != null);
      });

  Future<void> _approve() => _action(() async {
        final choices = await widget.access.targets();
        if (!mounted || !widget.access.isCurrent) return;
        final choice = await showDialog<GeneratedReviewTargetChoice>(
            context: context,
            builder: (context) =>
                SimpleDialog(title: const Text('选择 STAGE 目标题库'), children: [
                  for (final choice in choices)
                    SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, choice),
                        child: Text(choice.label))
                ]));
        if (!mounted || !widget.access.isCurrent || choice == null) return;
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('确认草稿目标'),
                    content: Text(
                        '${choice.label}\n允许向此题库暂存待审核草稿。正式保存仍需第一方 Review 确认。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('批准目标'))
                    ]));
        if (_current && confirmed == true) {
          await widget.access.approveTarget(choice);
        }
      });

  @override
  Widget build(BuildContext context) {
    final enabled = _current && _status.enabled;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('MCP vNext 访问控制'),
              Text(_status.connected && _current
                  ? '可信连接已认证'
                  : '未连接 / 不可用：生产认证与传输尚未准入'),
              if (_status.profileId != null)
                Text('已选 Profile：${_status.profileId}'),
              if (_status.pairing != null)
                Text('配对状态：${switch (_status.pairing!) {
                  PairingState.unpaired => '未配对',
                  PairingState.requestPending => '等待批准配对',
                  PairingState.approvedPendingProof => '等待凭据验证',
                  PairingState.pairedDisabled => '已配对，访问已禁用',
                  PairingState.enabledForCurrentRuntime => '本次运行已启用',
                  PairingState.revoked => '已撤销',
                  PairingState.recoveryRequired => '需要重新恢复配对',
                }}'),
              Text(enabled
                  ? '本次运行已启用 · 已批准目标 ${_status.approvedTargets}'
                  : '访问已禁用'),
              if (enabled && _status.expiresAt != null)
                Text('到期时间：${_status.expiresAt!.toLocal()}'),
              const Text('仅允许按授权读取和暂存草稿。内容将交给外部客户端；已释放内容无法撤回。'),
              if (_error != null) Text(_error!),
              Wrap(spacing: 12, runSpacing: 8, children: [
                OutlinedButton(
                    onPressed: !_current || _busy ? null : _select,
                    child: const Text('选择连接 Profile')),
                DropdownButton<int>(
                    value: _minutes,
                    items: [
                      for (final m in [5, 10, 30])
                        DropdownMenuItem(value: m, child: Text('$m 分钟'))
                    ],
                    onChanged: _busy || enabled
                        ? null
                        : (value) => setState(() => _minutes = value!)),
                FilledButton(
                    onPressed: !_current ||
                            _busy ||
                            enabled ||
                            !_status.connected ||
                            _status.pairing != PairingState.pairedDisabled
                        ? null
                        : () => _action(() =>
                            widget.access.enable(Duration(minutes: _minutes))),
                    child: const Text('限时启用')),
                OutlinedButton(
                    onPressed: !enabled || _busy ? null : _approve,
                    child: const Text('确认 STAGE 目标')),
                OutlinedButton(
                    onPressed: !enabled || _busy
                        ? null
                        : () => _action(widget.access.disable),
                    child: const Text('禁用访问')),
              ])
            ])));
  }
}
