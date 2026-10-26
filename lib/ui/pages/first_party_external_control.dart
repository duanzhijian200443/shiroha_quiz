import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../application/external/first_party_external_access.dart';
import '../../application/external/first_party_development_access.dart';
import '../../application/external/first_party_external_credentials.dart';
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
  FirstPartyDevelopmentStatus? _development;
  FirstPartyExistingCredentialDisplay? _existing;
  final _submission = TextEditingController();
  bool _busy = false, _reading = false, _enabling = false, _cancelling = false;
  bool _cancelRequested = false;
  String? _error, _publicExport, _exportKey, _exportKind, _copyMessage;
  Completer<void>? _readingDone;
  int _minutes = 10, _generation = 0;
  Timer? _timer;
  FirstPartyStageApprovalView? _stageView;
  StreamSubscription<void>? _stageChanges;
  bool get _current => mounted && widget.access.isCurrent;
  bool get _operationPending =>
      _busy ||
      _status.connectionPending ||
      _status.connectionSettling ||
      _cancelling;
  bool get _locked => _operationPending || _reading;
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

  void _clearPublicExport() {
    _publicExport = _exportKey = _exportKind = _copyMessage = null;
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
      _development = null;
      _existing = null;
      _busy = _reading = _enabling = _cancelling = _cancelRequested = false;
      _error = null;
      _clearPublicExport();
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
    if (!mounted || _reading || (_busy && !_enabling && !afterAction)) return;
    final access = widget.access;
    final generation = _generation;
    _reading = true;
    final readingDone = _readingDone = Completer<void>();
    try {
      if (!access.isCurrent) {
        _stageView?.close();
        unawaited(_stageChanges?.cancel());
        _stageView = null;
        _stageChanges = null;
        setState(() {
          _status = const FirstPartyExternalStatus();
          _development = access.development == null
              ? null
              : const FirstPartyDevelopmentStatus(
                  phase: FirstPartyDevelopmentPhase.unavailable);
          _existing = null;
          _clearPublicExport();
        });
      }
      var status = const FirstPartyExternalStatus();
      var businessRead = false;
      if (access.isCurrent) {
        _watchStageApproval();
        try {
          status = await access.status();
          businessRead = true;
        } catch (_) {/* Withdraw the failed business observation. */}
      }
      if (!_same(access, generation)) return;
      FirstPartyDevelopmentStatus? development;
      var developmentRead = true;
      try {
        development = await access.development?.status();
      } catch (_) {
        developmentRead = false;
        development = const FirstPartyDevelopmentStatus(
            phase: FirstPartyDevelopmentPhase.unavailable);
      }
      if (_same(access, generation)) {
        final current = access.isCurrent;
        if (!current) {
          _stageView?.close();
          unawaited(_stageChanges?.cancel());
          _stageView = null;
          _stageChanges = null;
          status = const FirstPartyExternalStatus();
          if (development != null &&
              development.phase != FirstPartyDevelopmentPhase.closed &&
              development.phase != FirstPartyDevelopmentPhase.failed) {
            development = const FirstPartyDevelopmentStatus(
                phase: FirstPartyDevelopmentPhase.unavailable);
          }
        }
        setState(() {
          _status = status;
          _development = development;
          _existing = current && businessRead && developmentRead
              ? access.existingCredentialDisplay
              : null;
          final key = _pairingKey(status);
          if (!current || !businessRead || key != _exportKey) {
            _clearPublicExport();
          }
        });
      }
    } catch (_) {
      if (_same(access, generation)) {
        setState(() {
          _status = const FirstPartyExternalStatus();
          _development = access.development == null
              ? null
              : const FirstPartyDevelopmentStatus(
                  phase: FirstPartyDevelopmentPhase.unavailable);
          _existing = null;
          _clearPublicExport();
        });
      }
    } finally {
      if (_same(access, generation)) setState(() => _reading = false);
      if (identical(_readingDone, readingDone)) _readingDone = null;
      readingDone.complete();
    }
  }

  Future<void> _copyPublicExport() async {
    if (!_current || _operationPending) return;
    final access = widget.access;
    final generation = _generation;
    final text = _publicExport, key = _exportKey, kind = _exportKind;
    if (text == null || key == null || kind == null) return;
    bool currentExport() =>
        _same(access, generation) &&
        _current &&
        _publicExport == text &&
        _exportKey == key &&
        _exportKind == kind &&
        _pairingKey(_status) == key &&
        !_status.pairingFailed;
    setState(() {
      _busy = true;
      _copyMessage = '正在核对并复制 $kind 公共数据…';
    });
    try {
      // A visible copy click joins the in-flight observation instead of being
      // silently discarded by _action's read lock. No approval is queued.
      await _readingDone?.future;
      if (!currentExport()) throw StateError('Public export changed');
      final fresh = kind == 'Completion'
          ? await access.exportPairingCompletion()
          : await access.exportPairingTrust();
      if (!currentExport() || fresh != text) {
        throw StateError('Public export changed');
      }
      await Clipboard.setData(ClipboardData(text: fresh));
      if (_same(access, generation)) {
        setState(() => _copyMessage =
            currentExport() ? '已复制 $kind 公共数据。' : '复制已执行，但配对状态已变化；请勿使用这份数据。');
      }
    } catch (_) {
      if (_same(access, generation)) {
        setState(() => _copyMessage = '复制未确认，请勿使用剪贴板中的旧数据。');
      }
    } finally {
      if (_same(access, generation)) {
        _busy = false;
        await _refresh(afterAction: true);
        if (_same(access, generation)) setState(() {});
      }
    }
  }

  Future<void> _pasteSubmission() async {
    if (!_current || _operationPending) return;
    final access = widget.access;
    final generation = _generation;
    final value = await Clipboard.getData(Clipboard.kTextPlain);
    if (!_same(access, generation) ||
        !_current ||
        _operationPending ||
        _status.pairing != PairingState.unpaired) {
      return;
    }
    final text = value?.text;
    if (text == null || !RegExp(r'^[0-9a-f]{32}$').hasMatch(text)) {
      setState(() => _error = '剪贴板不是本次 Submission ID，请在 Bridge 重新复制。');
      return;
    }
    setState(() => _submission.text = text);
  }

  Future<void> _exportAndCopy() async {
    if (!_current || _operationPending) return;
    final access = widget.access;
    final generation = _generation;
    await _readingDone?.future;
    if (!_same(access, generation) || !_current || _locked) return;
    final completion = _status.pairingDisplay?.revision != null;
    await _export(completion);
    if (_same(access, generation) && _current) await _copyPublicExport();
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

  Future<void> _revokeAssociation() => _action((access) async {
        final generation = _generation;
        final displayed = await access.inspectAssociationForRevocation();
        if (!mounted || !_same(access, generation) || !access.isCurrent) {
          access.cancelAssociationRecovery();
          return;
        }
        try {
          final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                    title: const Text('核对并撤销开发配对关联'),
                    content: SingleChildScrollView(
                        child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Profile：${displayed.profileName}'),
                        SelectableText('Profile ID：${displayed.profileId}'),
                        SelectableText('身份：${displayed.credentialIdentity}'),
                        SelectableText('安装标识：${displayed.installationId}'),
                        Text(
                            '关联 Revision：${displayed.revision}；已撤销：${displayed.revoked}'),
                        const Text('仅撤销所示关联并保留原撤销记录；不修改 Profile、Grant、'
                            'App issuer/server 或 Bridge Pin。原运行时关闭后，需正常重启 App，'
                            '再通过新的 Bridge 完成原配对的两次人工比较。'),
                      ],
                    )),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: displayed.revoked
                              ? null
                              : () => Navigator.pop(context, true),
                          child: const Text('撤销此关联并关闭开发连接')),
                    ],
                  ));
          if (confirmed == true && _same(access, generation)) {
            await access.confirmAssociationRevocation(displayed);
          }
        } finally {
          access.cancelAssociationRecovery();
        }
      });

  Future<void> _initializeDevelopmentCredentials() async {
    if (!_current || _locked) return;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('首次配置本机开发凭据'),
                content: const Text('仅在 App issuer 与 server 都缺失时创建一组受保护凭据；'
                    '现有完整凭据只验证复用。部分、损坏或结果未确认时停止，不恢复、覆盖或轮换。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确认首次配置'))
                ]));
    if (accepted == true && mounted) {
      await _action(
          (access) async => access.development!.initializeCredentials());
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
            _clearPublicExport();
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
            _exportKind = completion ? 'Completion' : 'Trust';
            _copyMessage = null;
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

  Future<void> _beginExisting() => _action((access) async {
        await access.beginExistingCredentialConfirmation();
        try {
          await access.development!.openPairingWindow();
        } catch (_) {
          await access.cancelExistingCredentialConfirmation();
          rethrow;
        }
      });

  Future<void> _confirmExisting() => _action((access) async {
        final displayed = _existing;
        if (displayed?.credentialIdentity == null) return;
        final approved = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('确认本次 Bridge 身份'),
                    content: SelectableText('Profile：${displayed!.profileId}\n'
                        '安装：${displayed.installationId}\n'
                        '凭据指纹：${displayed.credentialIdentity}\n'
                        '关联版本：${displayed.revision}\n'
                        '仅确认这次运行的既有身份；之后仍需单独限时启用。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('确认本次身份'))
                    ]));
        if (approved == true && _current) {
          await access.confirmExistingCredential(displayed!);
        }
      });

  @override
  Widget build(BuildContext context) {
    final appPairing = widget.access.pairingObservation;
    final revocation = widget.access.revocationObservation;
    final initialization = _development?.initialization;
    final child = _development?.pairingChild;
    final business = _development?.businessChild;
    final failure = business?.businessPrimary ?? child?.businessPrimary;
    final stop = _development?.stopObservation;
    final enabled = _current && _status.enabled;
    final relay =
        _current ? _status.relay.phase : FirstPartyRelayPhase.unavailable;
    final pending = _current ? _stageView?.pending : null;
    final connecting = _current && (_status.connectionPending || _enabling);
    final settling = _current && (_status.connectionSettling || _cancelling);
    final pairingPending = _status.pairing == PairingState.requestPending ||
        _status.pairing == PairingState.approvedPendingProof;
    final initialPairing = _development?.bridgePinMissing != false;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('连接 Codex', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(enabled
                    ? '已允许按当前规则读取与申请暂存。每次请求仍会验证身份。'
                    : _status.pairing == PairingState.pairedDisabled
                        ? '身份已确认。选择访问时长，再点“限时启用”。'
                        : _development?.phase !=
                                FirstPartyDevelopmentPhase.active
                            ? '先开启开发连接，再选择本次使用的 Profile。'
                            : _status.profileId == null
                                ? '选择已配置的 Profile，继续确认身份。'
                                : _development?.bridgePinMissing == false
                                    ? '已有配对凭据：点“验证既有 Bridge 凭据”，只需确认本次身份。'
                                    : '首次配对：App 与 Bridge 会并排显示，按下面的步骤完成两次核对。'),
                if (failure != null)
                  Text(
                      '业务连接失败：${failure.stage.name} / ${failure.code.name}。请展开连接诊断；不会自动重试。',
                      key: const Key('external-business-failure')),
                const SizedBox(height: 12),
                if (_development != null) ...[
                  Text('开发连接：${switch (_development!.phase) {
                    FirstPartyDevelopmentPhase.unavailable =>
                      '不可用（需从桌面 Explorer 启动正常 Debug App）',
                    FirstPartyDevelopmentPhase.inactive => '未启用',
                    FirstPartyDevelopmentPhase.starting => '正在验证既有凭据并启动',
                    FirstPartyDevelopmentPhase.active => '已显式启用，最多 30 分钟',
                    FirstPartyDevelopmentPhase.closed => '已关闭，需正常重启 App',
                    FirstPartyDevelopmentPhase.failed => '失败，需保留证据并正常重启 App',
                  }}'),
                  if (_development!.issuerMissing == true ||
                      _development!.serverMissing == true)
                    const Text('缺少 App credential：请显式完成首次配置。'),
                  if (_development!.bridgePinMissing == true)
                    const Text('缺少 Bridge Pin：请在独立配对窗口完成两次人工比较。'),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton(
                        onPressed: !_locked &&
                                widget.access.associationRecoveryAvailable &&
                                _development!.phase ==
                                    FirstPartyDevelopmentPhase.active &&
                                _development!.bridgePinMissing == true &&
                                !_development!.pairingWindowOpen &&
                                _status.pairing == PairingState.unpaired
                            ? _revokeAssociation
                            : null,
                        child: const Text('核对配对残留关联')),
                    OutlinedButton(
                        onPressed: _current &&
                                !_locked &&
                                _development!.phase ==
                                    FirstPartyDevelopmentPhase.inactive
                            ? _initializeDevelopmentCredentials
                            : null,
                        child: const Text('首次配置 App 凭据')),
                    FilledButton(
                        onPressed: _current &&
                                !_locked &&
                                _development!.phase ==
                                    FirstPartyDevelopmentPhase.inactive
                            ? () =>
                                _action((access) => access.development!.start())
                            : null,
                        child: const Text('启用 30 分钟开发连接')),
                    OutlinedButton(
                        onPressed: _current &&
                                !_locked &&
                                _development!.phase ==
                                    FirstPartyDevelopmentPhase.active &&
                                _development!.bridgePinMissing == true &&
                                !_development!.pairingWindowOpen
                            ? () => _action((access) =>
                                access.development!.openPairingWindow())
                            : null,
                        child: const Text('打开独立 Bridge 配对窗口')),
                    TextButton(
                        onPressed: _current &&
                                !_locked &&
                                _development!.phase ==
                                    FirstPartyDevelopmentPhase.active
                            ? () =>
                                _action((access) => access.development!.stop())
                            : null,
                        child: const Text('关闭开发连接')),
                  ]),
                ],
                Text('Codex 本地通道：${switch (relay) {
                  FirstPartyRelayPhase.unavailable => '不可用',
                  FirstPartyRelayPhase.listening => '等待连接',
                  FirstPartyRelayPhase.connected => '已连通（不代表业务授权）',
                  FirstPartyRelayPhase.settling => '正在关闭，等待原操作收敛',
                  FirstPartyRelayPhase.closed => '已关闭',
                  FirstPartyRelayPhase.unsettled => '关闭未确认，不能重新连接',
                }}'),
                Text(_status.connected && _current
                    ? '可信连接已认证'
                    : widget.access.requestScopedStageApproval && _current
                        ? '业务身份会在每次工具调用时单独验证。'
                        : _status.pairingAvailable && _current
                            ? '尚未认证业务连接；配对完成后需单独验证连接凭据'
                            : '未连接 / 不可用：生产认证与传输尚未准入'),
                if (_development?.phase == FirstPartyDevelopmentPhase.active &&
                    _development?.bridgePinMissing == false) ...[
                  OutlinedButton(
                      onPressed: _current &&
                              !_locked &&
                              _existing == null &&
                              !_development!.pairingWindowOpen &&
                              _status.pairing == PairingState.unpaired
                          ? _beginExisting
                          : null,
                      child: const Text('验证既有 Bridge 凭据')),
                  if (_existing != null) ...[
                    Text(_existing!.settling
                        ? '正在关闭身份验证，等待原连接收敛。'
                        : _existing!.credentialIdentity == null
                            ? '正在等待既有凭据的独立连接，最多 30 秒。'
                            : '本次身份等待确认，剩余 ${_existing!.remainingSeconds} 秒。'),
                    if (_existing!.credentialIdentity != null)
                      SelectableText('凭据指纹：${_existing!.credentialIdentity}'),
                    Wrap(spacing: 8, children: [
                      FilledButton(
                          onPressed: _current &&
                                  !_locked &&
                                  !_existing!.settling &&
                                  _existing!.credentialIdentity != null
                              ? _confirmExisting
                              : null,
                          child: const Text('确认本次身份')),
                      TextButton(
                          onPressed: _current && !_locked
                              ? () => _action((access) =>
                                  access.cancelExistingCredentialConfirmation())
                              : null,
                          child: const Text('取消身份验证')),
                    ]),
                  ],
                ],
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
                if (initialPairing &&
                    _status.publicPairingAvailable &&
                    _status.pairing == PairingState.unpaired) ...[
                  const Text('1. 在右侧 Bridge 开始配对并复制 Submission ID，回这里粘贴。'),
                  TextButton.icon(
                    onPressed: _locked || _status.pairingFailed
                        ? null
                        : _pasteSubmission,
                    icon: const Icon(Icons.paste),
                    label: const Text('粘贴 Submission ID'),
                  ),
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
                ],
                if (_status.pairingDisplay?.submissionId != null)
                  SelectableText(
                      '原 Submission ID：${_status.pairingDisplay!.submissionId}'),
                if (_status.pairingDisplay?.digest != null) ...[
                  Text(_status.pairingDisplay!.revision == null
                      ? '2. 复制 Trust 到右侧 Bridge，比较两边完整摘要后，在 Bridge 确认。'
                      : '4. 复制 Completion 到右侧 Bridge，再比较完成摘要和 Revision 后保存。'),
                  SelectableText('配对核对摘要：${_status.pairingDisplay!.digest}',
                      style: const TextStyle(fontFamily: 'monospace')),
                ],
                if (_status.pairingDisplay?.revision != null)
                  Text('已确认凭据版本：${_status.pairingDisplay!.revision}'),
                if (_status.pairingFailed)
                  const Text('配对未确认、已取消或已失效。请关闭并重新建立可信配对环境；不会自动重试。'),
                if (_status.publicPairingAvailable &&
                    !_status.pairingFailed &&
                    _status.pairingDisplay != null)
                  Wrap(spacing: 12, children: [
                    FilledButton.icon(
                        onPressed: _operationPending ? null : _exportAndCopy,
                        icon: const Icon(Icons.copy),
                        label: Text(
                            '复制当前 ${_status.pairingDisplay!.revision == null ? 'Trust' : 'Completion'}')),
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
                                    _clearPublicExport();
                                  }),
                          child: const Text('取消配对并关闭运行时')),
                  ]),
                if (_publicExport != null) ...[
                  Text('当前公共数据：$_exportKind'),
                  const Text('仅公共交接数据；请在独立 Bridge 界面导入，导入不会批准配对。'),
                  ExpansionTile(
                    title: const Text('查看公共交接数据'),
                    children: [
                      SelectableText(_publicExport!,
                          key: const Key('external-public-export'),
                          maxLines: 5),
                    ],
                  ),
                  TextButton(
                      onPressed: _operationPending ? null : _copyPublicExport,
                      child: Text('复制 $_exportKind 公共数据')),
                ],
                if (_copyMessage != null)
                  Text(_copyMessage!,
                      key: const Key('external-public-copy-result')),
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
                  if (initialPairing) ...[
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
                            : () =>
                                _action((access) => access.completePairing()),
                        child: const Text('验证配对证明')),
                  ],
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
                  if (!widget.access.requestScopedStageApproval)
                    OutlinedButton(
                        onPressed: !enabled ||
                                _locked ||
                                widget.access.requestScopedStageApproval
                            ? null
                            : _approve,
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
                ExpansionTile(
                  key: const Key('external-connection-diagnostics'),
                  title: const Text('连接诊断'),
                  subtitle: const Text('阶段、原进程与关闭结果；不代表授权或操作成功'),
                  children: [
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (appPairing != null) ...[
                            Text(
                                'App 配对阶段：${appPairing.phase.name}；原结果 ${appPairing.result.name}'),
                            Text(
                                'App 配对首个失败：${appPairing.firstFailure == null ? '未记录' : '${appPairing.firstFailure!.phase.name}/${appPairing.firstFailure!.failure.code}'}'),
                          ],
                          if (revocation != null) ...[
                            Text('关联撤销：原 Host 结果 ${revocation.revoke.name}；'
                                '后续关闭 ${revocation.close.name}'),
                            Text('撤销失败：${revocation.failure?.code ?? '未记录'}；'
                                '关闭失败：${revocation.closeFailure?.code ?? '未记录'}'),
                            Text(revocation.revoke ==
                                        FirstPartyObservedResult.returned &&
                                    revocation.close ==
                                        FirstPartyObservedResult.returned
                                ? '关联已撤销，原运行时已关闭。请正常重启 App 后重新配对。'
                                : '结果仅记录原操作；进入撤销后，失败或未知不表示回滚。'),
                          ],
                          if (initialization != null) ...[
                            Text(
                                '首次配置诊断：${_initializationStage(initialization.stage)}'),
                            Text(
                                'Owner：${initialization.ownerReturned ? '已实际返回' : '未返回，取得结果未确认'}'),
                            Text(
                                '原 close：${switch (initialization.closeResult) {
                              FirstPartyInitializationCloseResult
                                    .notAttempted =>
                                '未调用',
                              FirstPartyInitializationCloseResult.pending =>
                                '尚未返回',
                              FirstPartyInitializationCloseResult.returned =>
                                '已返回',
                              FirstPartyInitializationCloseResult.failed =>
                                '失败，保留原退出屏障',
                            }}'),
                            Text(
                                '主失败：${_initializationFailure(initialization.primaryFailure)}'),
                            Text(
                                '清理失败：${_initializationFailure(initialization.cleanupFailure)}'),
                            const Text('诊断仅记录原操作结果，不证明回滚或零副作用。'),
                          ],
                          if (child != null) ...[
                            Text('独立 Bridge 原退出码：${child.exitCode ?? '尚未观察到'}'),
                            Text(
                                '原进程结算：${child.parts[FirstPartyChildPart.settlement]?.name ?? 'unobserved'}'),
                            Text('原 stdin / stdout / stderr：'
                                '${child.parts[FirstPartyChildPart.stdin]?.name} / '
                                '${child.parts[FirstPartyChildPart.stdout]?.name} / '
                                '${child.parts[FirstPartyChildPart.stderr]?.name}'),
                            Text(
                                '子进程报告阶段：${child.reportedStage?.name ?? '未收到'}'),
                            Text(
                                '子进程主失败：${child.primaryFailure == null ? '未记录' : '${child.primaryFailure!.stage.name}/${child.primaryFailure!.code.name}'}'),
                            Text(
                                '子进程清理失败：${child.cleanupFailure == null ? '未记录' : '${child.cleanupFailure!.stage.name}/${child.cleanupFailure!.code.name}'}'),
                            const Text('子进程报告仅供诊断；退出码 0 不证明 Pin 已保存或业务获准。'),
                          ],
                          if (stop != null)
                            Text(
                                '开发关闭：触发 ${stop.cause.name}；原结果 ${stop.result.name}；'
                                '清理失败 ${stop.failure?.name ?? '未记录'}'),
                          if (business != null) ...[
                            Text(
                                '业务 Bridge 阶段：${business.businessStage?.name ?? '未收到'}'),
                            Text(
                                '业务首个失败：${_businessFailure(business.businessPrimary)}'),
                            Text(
                                '业务清理失败：${_businessFailure(business.businessCleanup)}'),
                            Text(
                                '业务 Bridge 原退出码：${business.exitCode ?? '尚未观察到'}'),
                            for (final part in FirstPartyChildPart.values)
                              Text(
                                  '业务 ${part.name}：${business.parts[part]?.name ?? 'unobserved'}'),
                          ],
                          if (child?.businessStage != null) ...[
                            Text('既有凭据连接阶段：${child!.businessStage!.name}'),
                            Text(
                                '既有凭据首个失败：${_businessFailure(child.businessPrimary)}'),
                            Text(
                                '既有凭据清理失败：${_businessFailure(child.businessCleanup)}'),
                          ],
                          const Text('文件存在和进程退出不证明凭据有效或业务获准；未知结果不表示回滚。'),
                        ]),
                  ],
                ),
                if (widget.access.requestScopedStageApproval)
                  const Text(
                      '开发连接按每次请求认证。STAGE 目标请在请求到达后的“批准本次暂存”中确认；限时启用不代表已有认证连接。'),
              ],
            )));
  }
}

String _initializationStage(FirstPartyInitializationStage stage) =>
    switch (stage) {
      FirstPartyInitializationStage.load => '加载 Native（load）',
      FirstPartyInitializationStage.acquire => '取得 Owner（acquire）',
      FirstPartyInitializationStage.p25 => '初始化凭据（P25）',
      FirstPartyInitializationStage.postAdmission => '准入复核（postAdmission）',
      FirstPartyInitializationStage.close => '关闭 Owner（close）',
    };

String _initializationFailure(FirstPartyInitializationFailure? failure) =>
    failure == null
        ? '未记录'
        : '${_initializationStage(failure.stage)} / ${failure.code.name}';

String _businessFailure(FirstPartyBusinessFailure? failure) =>
    failure == null ? '未记录' : '${failure.stage.name}/${failure.code.name}';
