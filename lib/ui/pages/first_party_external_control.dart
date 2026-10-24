import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../application/external/first_party_external_access.dart';
import '../../application/external/external_trust_core.dart';
import '../../application/external/first_party_stage_approval.dart';
import '../../application/generated_question/generated_local_authority.dart';

final class FirstPartyExternalControl extends StatefulWidget {
  const FirstPartyExternalControl({super.key, required this.access});
  final FirstPartyExternalAccess access;
  @override
  State<FirstPartyExternalControl> createState() => _ControlState();
}

final class _ControlState extends State<FirstPartyExternalControl> {
  FirstPartyExternalStatus _status = const FirstPartyExternalStatus();
  final _submission = TextEditingController();
  bool _busy = false, _reading = false, _enabling = false, _cancelling = false;
  bool _cancelRequested = false;
  String? _error, _publicExport, _exportKey;
  int _minutes = 10, _generation = 0;
  Timer? _timer;
  FirstPartyStageApprovalView? _stageView;
  StreamSubscription<void>? _stageChanges;
  bool get _current => mounted && widget.access.isCurrent;
  bool get _locked =>
      _busy ||
      _reading ||
      _status.connectionPending ||
      _status.connectionSettling ||
      _cancelling;
  bool _same(FirstPartyExternalAccess access, int generation) =>
      mounted && identical(access, widget.access) && generation == _generation;

  /// Public copy identity. A changed Submission/digest/Revision invalidates any
  /// previously displayed export so stale public data cannot be re-imported.
  String? _pairingKey(FirstPartyExternalStatus status) {
    final display = status.pairingDisplay;
    if (display == null) return null;
    return '${display.submissionId ?? ''}|${display.digest ?? ''}|'
        '${display.revision ?? ''}';
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  void _watchStageApproval() {
    if (!_current || _stageView != null) return;
    final view = widget.access.openStageApprovalView();
    if (view == null) return;
    _stageView = view;
    _stageChanges = view.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _leave(FirstPartyExternalAccess access) {
    // The owning App barrier retains any failed drain; a disposed view cannot.
    unawaited(access.cancelPendingControls().catchError((Object _) {}));
  }

  @override
  void didUpdateWidget(FirstPartyExternalControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.access, widget.access)) {
      _leave(oldWidget.access);
      _generation++;
      _stageView?.close();
      unawaited(_stageChanges?.cancel());
      _stageView = null;
      _stageChanges = null;
      _status = const FirstPartyExternalStatus();
      _busy = _reading = _enabling = _cancelling = _cancelRequested = false;
      _error = _publicExport = _exportKey = null;
      _submission.clear();
      _refresh();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stageView?.close();
    unawaited(_stageChanges?.cancel());
    _leave(widget.access);
    _submission.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool afterAction = false}) async {
    if (!mounted) return;
    if (!_current) {
      setState(() {
        _status = const FirstPartyExternalStatus();
        _publicExport = _exportKey = null;
      });
      return;
    }
    _watchStageApproval();
    if (_reading || (_busy && !_enabling && !afterAction)) return;
    final access = widget.access;
    final generation = _generation;
    _reading = true;
    try {
      final status = await access.status();
      if (_same(access, generation) && _current) {
        setState(() {
          _status = status;
          final key = _pairingKey(status);
          if (key != _exportKey) {
            _publicExport = null;
            _exportKey = null;
          }
        });
      }
    } catch (_) {
      if (_same(access, generation)) {
        setState(() {
          _status = const FirstPartyExternalStatus();
          _publicExport = _exportKey = null;
        });
      }
    } finally {
      if (_same(access, generation)) setState(() => _reading = false);
    }
  }

  Future<void> _action(Future<void> Function(FirstPartyExternalAccess) action,
      {bool enabling = false}) async {
    if (!_current || _locked) return;
    final access = widget.access;
    final generation = _generation;
    setState(() {
      _busy = true;
      _enabling = enabling;
      _error = null;
      if (enabling) _cancelRequested = false;
    });
    try {
      final work = action(access);
      if (enabling) unawaited(_refresh());
      await work;
    } catch (_) {
      if (_same(access, generation) && !(enabling && _cancelRequested)) {
        setState(() =>
            _error = '操作被拒绝：请核对当前连接、授权和原始 Submission；重复、外来、旧请求或过期数据不能重试。');
      }
    } finally {
      if (_same(access, generation)) {
        _busy = _enabling = false;
        await _refresh(afterAction: true);
        if (_same(access, generation)) setState(() {});
      }
    }
  }

  Future<void> _cancelConnection() async {
    if (!_current || _cancelling) return;
    final access = widget.access;
    final generation = _generation;
    setState(() {
      _cancelling = _cancelRequested = true;
      _error = null;
    });
    try {
      await access.disable();
      if (_same(access, generation)) {
        setState(() => _error = '连接等待已取消；再次连接需要显式限时启用。');
      }
    } catch (_) {
      if (_same(access, generation)) {
        setState(() => _error = '取消尚未确认，请等待原操作及所属运行时完成关闭。');
      }
    } finally {
      if (_same(access, generation)) {
        _cancelling = false;
        await _refresh(afterAction: true);
        if (_same(access, generation)) setState(() {});
      }
    }
  }

  Future<void> _select() => _action((access) async {
        final generation = _generation;
        String? after;
        do {
          final page = await access.profiles(afterId: after);
          if (!mounted || !_same(access, generation) || !_current) return;
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
          if (!mounted ||
              !_same(access, generation) ||
              !_current ||
              choice == null) {
            return;
          }
          if (choice.isNotEmpty) {
            await access.select(choice);
            _publicExport = _exportKey = null;
            return;
          }
          after = page.nextId;
        } while (after != null);
      });

  Future<void> _approvePairing() => _action((access) async {
        final generation = _generation;
        final display = _status.pairingDisplay;
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('确认客户端配对'),
                    content: SingleChildScrollView(
                        child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                            '请在独立 Bridge 本地界面比较完整摘要并单独确认。App 批准不等于 Bridge 确认，也不授予访问权限。'),
                        if (display?.submissionId != null)
                          SelectableText(display!.submissionId!),
                        if (display?.digest != null)
                          SelectableText(display!.digest!),
                      ],
                    )),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('批准配对'))
                    ]));
        if (_same(access, generation) && _current && confirmed == true) {
          await access.approvePairing();
        }
      });

  Future<void> _export(bool completion) => _action((access) async {
        final generation = _generation;
        final value = completion
            ? await access.exportPairingCompletion()
            : await access.exportPairingTrust();
        if (_same(access, generation) && _current) {
          setState(() {
            _publicExport = value;
            _exportKey = _pairingKey(_status);
          });
        }
      });

  Future<void> _approve() => _action((access) async {
        final generation = _generation;
        final choices = await access.targets();
        if (!mounted || !_same(access, generation) || !_current) return;
        final choice = await showDialog<GeneratedReviewTargetChoice>(
            context: context,
            builder: (context) =>
                SimpleDialog(title: const Text('选择 STAGE 目标题库'), children: [
                  for (final choice in choices)
                    SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, choice),
                        child: Text(choice.label))
                ]));
        if (!mounted ||
            !_same(access, generation) ||
            !_current ||
            choice == null) {
          return;
        }
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
        if (_same(access, generation) && _current && confirmed == true) {
          await access.approveTarget(choice);
        }
      });

  Future<void> _approveRequest(
      FirstPartyStageApprovalView view, FirstPartyStageRequest request) async {
    try {
      await view.confirm(request);
    } catch (_) {
      if (mounted && identical(view, _stageView)) {
        setState(() => _error = '本次暂存审批已失效。');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _current && _status.enabled;
    final pending = _current ? _stageView?.pending : null;
    final connecting = _current && (_status.connectionPending || _enabling);
    final settling = _current && (_status.connectionSettling || _cancelling);
    final pairingPending = _status.pairing == PairingState.requestPending ||
        _status.pairing == PairingState.approvedPendingProof;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('MCP vNext 访问控制'),
                Text(_status.connected && _current
                    ? '可信连接已认证'
                    : _status.pairingAvailable && _current
                        ? '尚未认证业务连接；配对完成后需单独验证连接凭据'
                        : '未连接 / 不可用：生产认证与传输尚未准入'),
                if (!_status.pairingAvailable) const Text('配对不可用：尚无已准入的凭据服务'),
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
                if (_status.publicPairingAvailable &&
                    _status.pairing == PairingState.unpaired)
                  TextField(
                    key: const Key('external-submission-id'),
                    controller: _submission,
                    enabled: !_locked && !_status.pairingFailed,
                    maxLength: 32,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                        labelText: '粘贴 Bridge 原 Submission ID（32 位小写十六进制）'),
                  ),
                if (_status.pairingDisplay?.submissionId != null)
                  SelectableText(
                      '原 Submission ID：${_status.pairingDisplay!.submissionId}'),
                if (_status.pairingDisplay?.digest != null)
                  SelectableText('配对核对摘要：${_status.pairingDisplay!.digest}'),
                if (_status.pairingDisplay?.revision != null)
                  Text('已确认凭据版本：${_status.pairingDisplay!.revision}'),
                if (_status.pairingFailed)
                  const Text('配对未确认、已取消或已失效。请关闭并重新建立可信配对环境；不会自动重试。'),
                if (_status.publicPairingAvailable &&
                    !_status.pairingFailed &&
                    _status.pairingDisplay != null)
                  Wrap(spacing: 12, children: [
                    OutlinedButton(
                        onPressed: _locked ? null : () => _export(false),
                        child: const Text('导出 Trust 公共数据')),
                    OutlinedButton(
                        onPressed:
                            _locked || _status.pairingDisplay!.revision == null
                                ? null
                                : () => _export(true),
                        child: const Text('导出 Completion 公共数据')),
                    if (pairingPending)
                      TextButton(
                          onPressed: _locked
                              ? null
                              : () => _action((access) async {
                                    await access.cancelPairing();
                                    _publicExport = _exportKey = null;
                                  }),
                          child: const Text('取消配对并关闭运行时')),
                  ]),
                if (_publicExport != null) ...[
                  const Text('仅公共交接数据；请在独立 Bridge 界面导入，导入不会批准配对。'),
                  SelectableText(_publicExport!,
                      key: const Key('external-public-export'), maxLines: 5),
                  TextButton(
                      onPressed: _locked
                          ? null
                          : () => _action((_) async {
                                await Clipboard.setData(
                                    ClipboardData(text: _publicExport!));
                              }),
                      child: const Text('复制公共数据')),
                ],
                Text(enabled
                    ? '本次运行已启用 · 已批准目标 ${_status.approvedTargets}'
                    : '访问已禁用'),
                if (settling)
                  const Text('正在取消连接，等待原操作收敛；不会提前释放运行时。')
                else if (connecting)
                  const Text('正在等待独立 Bridge 连接；可以禁用并取消等待。'),
                if (connecting || settling) const LinearProgressIndicator(),
                if (_status.connectionFailed)
                  const Text('连接失败、已过期或授权已撤销；不会自动重试，请检查后显式重新启用。'),
                if ((enabled || connecting || settling) &&
                    _status.expiresAt != null) ...[
                  Text('到期时间：${_status.expiresAt!.toLocal()}'),
                  if (_status.remainingSeconds != null)
                    Text('剩余有效期：${_status.remainingSeconds} 秒'),
                ],
                const Text('仅允许按授权读取和暂存草稿。内容将交给外部客户端；已释放内容无法撤回。'),
                if (_error != null) Text(_error!),
                if (pending != null)
                  Column(
                    key: const Key('external-stage-approval'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('待批准的 STAGE 请求'),
                      Text('Profile：${pending.profileId}'),
                      Text(pending.targetLabel),
                      Text(
                          '剩余 ${pending.remainingSeconds} 秒；仅暂存待审核草稿，正式保存仍需 Review 确认。'),
                      Wrap(spacing: 12, children: [
                        TextButton(
                            onPressed: () => _stageView!.reject(pending),
                            child: const Text('拒绝本次暂存')),
                        FilledButton(
                            onPressed: () =>
                                _approveRequest(_stageView!, pending),
                            child: const Text('批准本次暂存')),
                      ]),
                    ],
                  ),
                Wrap(spacing: 12, runSpacing: 8, children: [
                  OutlinedButton(
                      onPressed: !_current || _locked || pairingPending
                          ? null
                          : _select,
                      child: const Text('选择连接 Profile')),
                  OutlinedButton(
                      onPressed: !_current ||
                              _locked ||
                              !_status.pairingAvailable ||
                              _status.pairingFailed ||
                              _status.pairing != PairingState.unpaired
                          ? null
                          : () => _action((access) => access.requestPairing(
                              submissionId: _status.publicPairingAvailable
                                  ? _submission.text
                                  : null)),
                      child: const Text('请求配对')),
                  OutlinedButton(
                      onPressed: !_current ||
                              _locked ||
                              !_status.pairingAvailable ||
                              _status.pairingFailed ||
                              _status.pairing != PairingState.requestPending
                          ? null
                          : _approvePairing,
                      child: const Text('确认配对')),
                  OutlinedButton(
                      onPressed: !_current ||
                              _locked ||
                              !_status.pairingAvailable ||
                              _status.pairingFailed ||
                              _status.pairing !=
                                  PairingState.approvedPendingProof
                          ? null
                          : () => _action((access) => access.completePairing()),
                      child: const Text('验证配对证明')),
                  DropdownButton<int>(
                      value: _minutes,
                      items: [
                        for (final m in [5, 10, 30])
                          DropdownMenuItem(value: m, child: Text('$m 分钟'))
                      ],
                      onChanged: _locked || enabled
                          ? null
                          : (value) => setState(() => _minutes = value!)),
                  FilledButton(
                      onPressed: !_current ||
                              _locked ||
                              enabled ||
                              (!_status.connected &&
                                  !_status.pairingAvailable) ||
                              _status.pairingFailed ||
                              _status.pairing != PairingState.pairedDisabled
                          ? null
                          : () => _action(
                              (access) =>
                                  access.enable(Duration(minutes: _minutes)),
                              enabling: true),
                      child: const Text('限时启用')),
                  OutlinedButton(
                      onPressed: !enabled || _locked ? null : _approve,
                      child: const Text('确认 STAGE 目标')),
                  OutlinedButton(
                      onPressed: !_current || settling
                          ? null
                          : _status.connectionPending &&
                                  _status.connectionCancellationAvailable
                              ? _cancelConnection
                              : enabled && !_locked
                                  ? () => _action((access) => access.disable())
                                  : null,
                      child: Text(connecting || settling ? '禁用并取消等待' : '禁用访问')),
                ]),
              ],
            )));
  }
}
