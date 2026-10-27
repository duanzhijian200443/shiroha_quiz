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
        _status.relay.phase == FirstPartyRelayPhase.unsettled;
    return Card(
      key: const Key('external-connection-guide'),
      child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('1. 连接 Codex',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(widget.profileName == null
                  ? '先在下方选择或创建一份访问配置。'
                  : '访问配置：${widget.profileName}'),
              if (!widget.policySaved)
                const Text('请先保存下方访问规则。已有连接仍按原来的已保存规则运行。'),
              if (_current && !sameProfile && _status.enabled) ...[
                const Text('当前连接仍在使用另一份配置；选择下方配置不会变更已有访问。'),
                TextButton(
                    onPressed:
                        _locked ? null : () => _action((a) => a.disable()),
                    child: const Text('停止原配置访问')),
              ],
              const SizedBox(height: 12),
              Text(
                  enabled
                      ? '已允许访问'
                      : paired
                          ? '身份已确认，等待允许访问'
                          : existing != null
                              ? '正在核对本次连接身份'
                              : '尚未允许访问',
                  style: Theme.of(context).textTheme.titleMedium),
              Text(switch (_status.relay.phase) {
                FirstPartyRelayPhase.connected => '客户端通道已连接；每次请求仍单独验证身份与权限。',
                FirstPartyRelayPhase.settling => '正在等待上一条连接完成清理。',
                FirstPartyRelayPhase.unsettled => '上一条连接清理未确认，不能重新连接。',
                _ => 'Codex 下一次工具调用时连接；连接本身不会授予访问权限。',
              }),
              if (deadline != null)
                Text('${enabled ? '本次访问截止' : '开发连接截止'}：'
                    '${deadline.toLocal().toString().split('.').first}'),
              if (failed) const Text('连接失败。请展开下方诊断；不会自动重试或覆盖凭据。'),
              if (development?.phase == FirstPartyDevelopmentPhase.closed)
                const Text('本次开发连接已结束。正常重开 App 后，可复用已有凭据连接。'),
              if (development?.bridgePinMissing == true)
                const Text('此设备尚未完成首次配对。请展开“首次配对与连接诊断”完成一次配置。'),
              if (_error != null)
                Text(_error!, key: const Key('external-guide-error')),
              if (_operationPending || existing?.settling == true || childBusy)
                const LinearProgressIndicator(),
              if (existing != null) ...[
                const SizedBox(height: 12),
                Text(existing.credentialIdentity == null
                    ? '正在通过已有凭据验证。无需重新配对。'
                    : '请核对下方身份，剩余 ${existing.remainingSeconds} 秒。'),
                if (existing.credentialIdentity != null)
                  SelectableText('凭据指纹：${existing.credentialIdentity}'),
                Wrap(spacing: 12, children: [
                  if (existing.credentialIdentity != null)
                    FilledButton(
                        onPressed: _current && !_locked && !existing.settling
                            ? _confirmExisting
                            : null,
                        child: const Text('确认本次身份')),
                  TextButton(
                      onPressed: _current && !_locked
                          ? () => _action(
                              (a) => a.cancelExistingCredentialConfirmation())
                          : null,
                      child: const Text('取消身份验证')),
                ]),
              ] else if (!enabled) ...[
                const SizedBox(height: 12),
                if (paired)
                  Wrap(
                      spacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        DropdownButton<int>(
                            value: _minutes,
                            items: [
                              for (final value in _durationOptions)
                                DropdownMenuItem(
                                    value: value,
                                    child: Text(_durationLabel(value))),
                            ],
                            onChanged: _locked
                                ? null
                                : (value) => _selectDuration(value!)),
                        FilledButton.icon(
                            onPressed: _current &&
                                    !_locked &&
                                    !childBusy &&
                                    widget.policySaved
                                ? () => _action(
                                    (a) =>
                                        a.enable(Duration(minutes: _minutes)),
                                    enabling: true)
                                : null,
                            icon: const Icon(Icons.lock_open_outlined),
                            label: const Text('允许本次访问')),
                      ])
                else if (existing == null)
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
                      label: const Text('连接 Codex')),
                const Text('身份确认后，再明确允许本次访问。保存规则不会自动启用。'),
              ] else ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                    onPressed:
                        _locked ? null : () => _action((a) => a.disable()),
                    icon: const Icon(Icons.pause_circle_outline),
                    label: const Text('停止访问')),
              ],
              const SizedBox(height: 20),
              const Divider(),
              Text('暂存确认', style: Theme.of(context).textTheme.titleMedium),
              const Text('Codex 请求出题时，先在这里允许暂存。成功发布后才会出现在“待审核题目”；暂存不会入库。'),
              if (pending == null)
                const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('当前没有等待你确认的暂存请求。'))
              else
                Container(
                  key: const Key('external-stage-approval'),
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('需要你确认：暂存草稿',
                            style: Theme.of(context).textTheme.titleMedium),
                        Text(pending.targetLabel),
                        Text(
                            '剩余 ${pending.remainingSeconds} 秒。正式入库仍需后续 Review。'),
                        Wrap(spacing: 12, children: [
                          FilledButton(
                              onPressed: () =>
                                  _approveRequest(_stageView!, pending),
                              child: const Text('批准本次暂存')),
                          TextButton(
                              onPressed: () => _stageView!.reject(pending),
                              child: const Text('拒绝本次暂存')),
                        ]),
                      ]),
                ),
              const SizedBox(height: 12),
              ExpansionTile(
                  title: const Text('首次配对与连接诊断'),
                  subtitle: const Text('仅首次配置、故障或高级管理时使用'),
                  children: [_technicalControl(context)]),
            ],
          )),
    );
  }
}
