part of 'first_party_external_control.dart';

/// Presentation of the existing first-party owners, not another access state.
extension _GuidedExternalControl on _ControlState {
  Widget _guidedControl(BuildContext context) {
    final sameProfile =
        widget.profileId != null && widget.profileId == _status.profileId;
    final enabled = _current && sameProfile && _status.enabled;
    final development = _development;
    final pending = _current ? _stageView?.pending : null;
    final existing = sameProfile ? _existing : null;
    final paired =
        sameProfile && _status.pairing == PairingState.pairedDisabled;
    final childBusy = development?.pairingWindowOpen == true;
    final canPrepare = _current &&
        !_locked &&
        widget.profileId != null &&
        widget.policySaved &&
        existing == null &&
        !childBusy &&
        (development?.phase == FirstPartyDevelopmentPhase.inactive ||
            development?.phase == FirstPartyDevelopmentPhase.active) &&
        development?.bridgePinMissing == false;
    final deadline = enabled ? _status.expiresAt : development?.expiresAt;
    final failed = development?.phase == FirstPartyDevelopmentPhase.failed ||
        _status.relay.phase == FirstPartyRelayPhase.unsettled ||
        _status.connectionFailed;
    final colors = Theme.of(context).colorScheme;
    final statusForeground = enabled
        ? colors.onPrimaryContainer
        : failed
            ? colors.onErrorContainer
            : colors.onSurface;
    final statusBackground = enabled
        ? colors.primaryContainer
        : failed
            ? colors.errorContainer
            : colors.surfaceContainerHighest;
    final statusTitle = enabled
        ? '已允许访问'
        : failed
            ? '连接需要检查'
            : paired
                ? '身份已确认，等待允许访问'
                : existing != null
                    ? '正在核对本次连接身份'
                    : '尚未允许访问';
    final statusIcon = enabled
        ? Icons.lock_open_outlined
        : failed
            ? Icons.error_outline
            : paired
                ? Icons.verified_user_outlined
                : existing != null
                    ? Icons.fingerprint
                    : Icons.link_off_outlined;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          key: const Key('external-connection-guide'),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.link,
                          color: colors.onPrimaryContainer, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Codex 访问',
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text(
                            widget.profileName == null
                                ? '先在下方选择或创建一份访问配置。'
                                : '访问配置：${widget.profileName}',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (!widget.policySaved)
                  const _GuidedMessage(
                    icon: Icons.save_outlined,
                    child: Text('请先保存下方访问规则。已有连接仍按原来的已保存规则运行。'),
                  ),
                if (_current && !sameProfile && _status.enabled) ...[
                  const _GuidedMessage(
                    icon: Icons.account_tree_outlined,
                    child: Text('当前连接仍在使用另一份配置；选择下方配置不会变更已有访问。'),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed:
                          _locked ? null : () => _action((a) => a.disable()),
                      child: const Text('停止原配置访问'),
                    ),
                  ),
                ],
                Container(
                  key: const Key('external-connection-status'),
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: statusBackground,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(statusIcon, color: statusForeground),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              statusTitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    color: statusForeground,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              switch (_status.relay.phase) {
                                FirstPartyRelayPhase.connected =>
                                  '客户端通道已连接；每次请求仍单独验证身份与权限。',
                                FirstPartyRelayPhase.settling =>
                                  '正在等待上一条连接完成清理。',
                                FirstPartyRelayPhase.unsettled =>
                                  '上一条连接清理未确认，不能重新连接。',
                                _ => 'Codex 下一次工具调用时连接；连接本身不会授予访问权限。',
                              },
                              style: TextStyle(color: statusForeground),
                            ),
                            if (deadline != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '${enabled ? '本次访问截止' : '开发连接截止'}：'
                                  '${deadline.toLocal().toString().split('.').first}',
                                  style: TextStyle(color: statusForeground),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (development?.phase == FirstPartyDevelopmentPhase.closed)
                  const _GuidedMessage(
                    icon: Icons.restart_alt,
                    child: Text('本次开发连接已结束。正常重开 App 后，可复用已有凭据连接。'),
                  ),
                if (development?.bridgePinMissing == true)
                  const _GuidedMessage(
                    icon: Icons.phonelink_setup_outlined,
                    child: Text('此设备尚未完成首次配对。请展开“首次配对与连接诊断”完成一次配置。'),
                  ),
                if (failed)
                  const _GuidedMessage(
                    icon: Icons.error_outline,
                    error: true,
                    child: Text('连接失败。请展开下方诊断；不会自动重试或覆盖凭据。'),
                  ),
                if (_error != null)
                  _GuidedMessage(
                    icon: Icons.error_outline,
                    error: true,
                    child:
                        Text(_error!, key: const Key('external-guide-error')),
                  ),
                if (_operationPending ||
                    existing?.settling == true ||
                    childBusy)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(),
                  ),
                if (existing != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    existing.credentialIdentity == null
                        ? '正在通过已有凭据验证。无需重新配对。'
                        : '请核对下方身份，剩余 ${existing.remainingSeconds} 秒。',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (existing.credentialIdentity != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child:
                          SelectableText('凭据指纹：${existing.credentialIdentity}'),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      if (existing.credentialIdentity != null)
                        FilledButton(
                          onPressed: _current && !_locked && !existing.settling
                              ? _confirmExisting
                              : null,
                          child: const Text('确认本次身份'),
                        ),
                      TextButton(
                        onPressed: _current && !_locked
                            ? () => _action(
                                (a) => a.cancelExistingCredentialConfirmation())
                            : null,
                        child: const Text('取消身份验证'),
                      ),
                    ],
                  ),
                ] else if (!enabled) ...[
                  const SizedBox(height: 16),
                  if (paired)
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        DropdownButton<int>(
                          value: _durationValue,
                          hint: const Text('请选择访问时长'),
                          items: [
                            for (final value in _durationOptions)
                              DropdownMenuItem(
                                  value: value,
                                  child: Text(_durationLabel(value))),
                          ],
                          onChanged: !_durationAvailable || _locked
                              ? null
                              : (value) => _selectDuration(value!),
                        ),
                        FilledButton.icon(
                          onPressed: _durationAvailable &&
                                  _durationValue != null &&
                                  !_locked &&
                                  !childBusy &&
                                  widget.policySaved
                              ? () => _action(
                                  (a) => a.enable(Duration(minutes: _minutes)),
                                  enabling: true)
                              : null,
                          icon: const Icon(Icons.lock_open_outlined),
                          label: const Text('允许本次访问'),
                        ),
                      ],
                    )
                  else
                    FilledButton.icon(
                      onPressed: canPrepare
                          ? () async {
                              final profileId = widget.profileId!;
                              final generation = _generation;
                              await _action((a) => a.prepareExistingConnection(
                                  profileId,
                                  available: () =>
                                      _same(a, generation) &&
                                      _current &&
                                      widget.profileId == profileId &&
                                      widget.policySaved));
                            }
                          : null,
                      icon: const Icon(Icons.link),
                      label: const Text('连接 Codex'),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '身份确认后，再明确允许本次访问。保存规则不会自动启用。',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ] else ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed:
                        _locked ? null : () => _action((a) => a.disable()),
                    icon: const Icon(Icons.pause_circle_outline),
                    label: const Text('停止访问'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.playlist_add_check_circle_outlined,
                        color: colors.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('暂存确认',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Codex 请求出题时，先在这里允许暂存。成功发布后才会出现在“待审核题目”；暂存不会入库。',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                if (pending == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('当前没有等待你确认的暂存请求。'),
                  )
                else
                  Container(
                    key: const Key('external-stage-approval'),
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '需要你确认：暂存草稿',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: colors.onPrimaryContainer),
                        ),
                        const SizedBox(height: 4),
                        Text(pending.targetLabel),
                        Text(
                            '剩余 ${pending.remainingSeconds} 秒。正式入库仍需后续 Review。'),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            FilledButton(
                              onPressed: () =>
                                  _approveRequest(_stageView!, pending),
                              child: const Text('批准本次暂存'),
                            ),
                            TextButton(
                              onPressed: () => _stageView!.reject(pending),
                              child: const Text('拒绝本次暂存'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text('首次配对与连接诊断'),
            subtitle: const Text('仅首次配置、故障或高级管理时使用'),
            children: [_technicalControl(context)],
          ),
        ),
      ],
    );
  }
}

class _GuidedMessage extends StatelessWidget {
  const _GuidedMessage({
    required this.icon,
    required this.child,
    this.error = false,
  });

  final IconData icon;
  final Widget child;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground =
        error ? colors.onErrorContainer : colors.onSurfaceVariant;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: error ? colors.errorContainer : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: DefaultTextStyle.merge(
              style: TextStyle(color: foreground),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}
