import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/external/android_foreground_access.dart';
import '../../application/external/android_http_access.dart';
import '../../application/external/external_authorization.dart';
import '../../application/external/local_authorization_service.dart';

final class AndroidHttpAccessPanel extends StatefulWidget {
  const AndroidHttpAccessPanel({
    super.key,
    required this.access,
    required this.service,
  });

  final AndroidHttpAccess access;
  final LocalAuthorizationService service;

  @override
  State<AndroidHttpAccessPanel> createState() => _AndroidHttpAccessPanelState();
}

enum _ClientAction { grant, reissue, revoke }

class _AndroidHttpAccessPanelState extends State<AndroidHttpAccessPanel> {
  late final StreamSubscription<void> _changes;
  late final Timer _clock;
  List<ExternalClientProfile> _clients = const [];
  var _duration = AndroidAccessDuration.fifteenMinutes;
  var _background = false;
  var _locked = false;
  var _busy = false;
  String? _error;

  static const _shortDurations = [
    AndroidAccessDuration.fiveMinutes,
    AndroidAccessDuration.fifteenMinutes,
    AndroidAccessDuration.thirtyMinutes,
  ];

  @override
  void initState() {
    super.initState();
    _changes = widget.access.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.access.state.remaining != null) setState(() {});
    });
    unawaited(_run(() async {
      await widget.access.inspect();
      await _loadClients();
    }));
  }

  @override
  void dispose() {
    _clock.cancel();
    unawaited(_changes.cancel());
    unawaited(widget.access.cancelPending());
    super.dispose();
  }

  Future<void> _loadClients() async {
    final view = widget.service.openView();
    try {
      String? cursor;
      final clients = <ExternalClientProfile>[];
      do {
        final page = await view.profiles(afterId: cursor);
        clients.addAll(page.items.where((profile) =>
            profile.adapter == androidHttpAdapter &&
            profile.protocol == androidHttpProtocol &&
            profile.revokedAtUtcMs == null));
        cursor = page.nextId;
      } while (cursor != null);
      if (mounted) setState(() => _clients = clients);
    } finally {
      view.close();
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on AndroidHttpAccessException catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请检查连接或重新打开此页。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(AndroidHttpAccessException error) => switch (error.code) {
        'notification_permission_required' ||
        'notification_not_ready' ||
        'service_start_failed' =>
          '后台通知未就绪。请检查通知设置，再开启访问。',
        'wifi_required' => '请连接私有 Wi-Fi。',
        'foreground_required' => '请保持 App 在前台且设备已解锁。',
        'enable_cancelled' => '访问未开启。请检查 Wi-Fi 和 App 状态后重试。',
        'no_eligible_clients' => '当前没有符合此访问模式的客户端授权。',
        'resourceLimit' => '客户端凭据已达上限。',
        'credential_recovery' => '凭据操作需要恢复。请保留该客户端记录并尝试撤销。'
            '\n客户端 ID ${error.recoveryProfileId}',
        _ => '操作未完成，请检查连接或重新打开此页。',
      };

  Future<void> _export() => _run(() async {
        final bytes = await widget.access.exportRootCertificate();
        if (!mounted) return;
        final destination = await FilePicker.platform.saveFile(
          dialogTitle: '导出根 CA 证书',
          fileName: 'shiroha-android-root-ca.pem',
          bytes: bytes,
        );
        if (destination != null && mounted) _snack('根 CA 证书已导出');
      });

  void _snack(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _copy(String value, String confirmation) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) _snack(confirmation);
  }

  Future<void> _newClient() => _run(() async {
        var name = '';
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('添加客户端'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  autofocus: true,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: '客户端名称'),
                  onChanged: (value) => name = value.trim(),
                ),
                const Text('初始授权为全部题库的题目只读。统计和文件正文需单独授权。'),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(context, name.isNotEmpty),
                child: const Text('签发 Token'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        try {
          await _showToken(await widget.access.addClient(name));
        } finally {
          await _loadClients();
        }
      });

  Future<void> _showToken(String token) async {
    if (!mounted) return;
    final access = widget.access;
    await showDialog<void>(
      context: context,
      builder: (context) => _IssuedTokenDialog(
        token: token,
        copyToken: () => access.copyIssuedToken(token),
      ),
    );
  }

  Future<void> _clientAction(
          ExternalClientProfile client, _ClientAction action) =>
      _run(() async {
        if (action == _ClientAction.grant) {
          await _editGrant(client);
          return;
        }
        final reissue = action == _ClientAction.reissue;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(reissue ? '重新签发 Token' : '撤销客户端'),
            content: Text(reissue
                ? '「${client.displayName}」的旧 Token 将失效。请用新 Token 更新客户端配置。'
                : '「${client.displayName}」的 Token 和当前会话将失效。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(reissue ? '重新签发' : '撤销'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        try {
          if (reissue) {
            await _showToken(
                await widget.access.reissueClient(client.clientProfileId));
          } else {
            await widget.access.revokeClient(client.clientProfileId);
          }
        } finally {
          await _loadClients();
        }
      });

  Future<void> _editGrant(ExternalClientProfile client) async {
    final view = widget.service.openView();
    try {
      final ref = await view.select(client.clientProfileId);
      final record = await view.read(ref);
      final targets = await view.targets();
      if (!mounted || !view.isCurrent) return;
      final policy = record.grant?.policy;
      var all = policy?.allContent ?? false;
      var file =
          policy?.categories.contains(ExternalContentCategory.fileContent) ??
              false;
      var statistics = policy?.categories
              .contains(ExternalContentCategory.studyStatistics) ??
          false;
      final selected = targets
          .where((target) => policy?.scopes.contains(target.scope) ?? false)
          .toSet();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            scrollable: true,
            title: Text('${client.displayName}的只读授权'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CheckboxListTile(
                  title: const Text('全部范围（含今后新增）'),
                  value: all,
                  onChanged: (value) => update(() => all = value!),
                ),
                CheckboxListTile(
                  title: const Text('学习统计'),
                  value: statistics,
                  onChanged: (value) => update(() => statistics = value!),
                ),
                CheckboxListTile(
                  title: const Text('文件正文'),
                  value: file,
                  onChanged: (value) => update(() => file = value!),
                ),
                if (file || statistics) const Text('此客户端适用前台访问模式。'),
                if (!all)
                  for (final target in targets)
                    if (file || target.scope.kind == ExternalTargetKind.bank)
                      CheckboxListTile(
                        title: Text(target.label),
                        value: selected.contains(target),
                        onChanged: (value) => update(() {
                          if (value == true) {
                            selected.add(target);
                          } else {
                            selected.remove(target);
                          }
                        }),
                      ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('保存')),
            ],
          ),
        ),
      );
      if (confirmed == true && mounted) {
        await view.saveAndroidHttpRead(
          ref,
          record.profile.grantRevision,
          allContent: all,
          targets: selected.where(
              (target) => file || target.scope.kind == ExternalTargetKind.bank),
          fileContent: file,
          studyStatistics: statistics,
        );
        if (mounted) _snack('已保存只读授权');
      }
    } finally {
      view.close();
    }
  }

  Future<void> _configuration(Uri? endpoint) async {
    final template = '[mcp_servers.shiroha_android]\n'
        'url = "${endpoint ?? '<App 中的 HTTPS URL>'}"\n'
        'bearer_token_env_var = "SHIROHA_ANDROID_MCP_TOKEN"';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Codex 配置'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                '让电脑和 Android 设备连接同一私有 Wi-Fi。把根 CA 的 PEM 文件和单次显示的 Token 传到电脑。'),
            const SizedBox(height: 12),
            const Text('将下方配置添加到 ~/.codex/config.toml。'),
            SelectableText(template),
            const SizedBox(height: 12),
            const Text(
                '在启动 Codex 的环境中，将 CODEX_CA_CERTIFICATE 设为 PEM 文件的绝对路径，将 SHIROHA_ANDROID_MCP_TOKEN 设为当前 Token，然后重启 Codex。'
                '\n如果本机代理拦截了私有地址，将设备 IP 加入 NO_PROXY。'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('完成')),
          if (endpoint != null)
            FilledButton(
              onPressed: () => unawaited(_copy(template, '已复制 Codex 配置')),
              child: const Text('复制配置'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final access = widget.access;
    final state = access.state;
    final ready = state.endpoint != null;
    final off = state.phase == AndroidAccessPhase.off;
    final background = ready ? state.background : _background;
    final locked = ready ? state.continueWhileLocked : _locked;
    final duration = ready ? state.duration ?? _duration : _duration;
    final canEdit = !_busy && state.available;
    final canEnable = canEdit &&
        off &&
        state.privateWifi &&
        _clients.isNotEmpty &&
        (!_background || state.notificationsAllowed);
    final status = switch (state.phase) {
      AndroidAccessPhase.ready when ready => state.remaining == null
          ? '访问已开启 · App 停止时关闭'
          : '访问已开启 · 剩余 ${(state.remaining!.inSeconds + 59) ~/ 60} 分钟',
      AndroidAccessPhase.preparing || AndroidAccessPhase.ready => '正在开启访问…',
      AndroidAccessPhase.draining || AndroidAccessPhase.suspended => '正在关闭访问…',
      AndroidAccessPhase.recovery => '访问已关闭，原资源收尾待确认',
      AndroidAccessPhase.off =>
        state.available ? '访问已关闭' : '此安装无法使用 Android HTTP MCP',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('外部 Agent')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('允许局域网只读访问'),
            subtitle: Text(status),
            value: ready,
            onChanged: ready
                ? (_) => unawaited(access.disable())
                : canEnable
                    ? (_) => unawaited(_run(() => access.enable(_duration,
                        background: _background, continueWhileLocked: _locked)))
                    : null,
          ),
          if (!state.privateWifi && state.available)
            const ListTile(title: Text('请连接私有 Wi-Fi 后开启访问。')),
          if (state.phase == AndroidAccessPhase.preparing)
            TextButton(
                onPressed: () => unawaited(access.cancelPending()),
                child: const Text('取消开启')),
          ListTile(
            title: const Text('授权时长'),
            trailing: DropdownButton<AndroidAccessDuration>(
              value: duration,
              items: [
                for (final value in background
                    ? AndroidAccessDuration.values
                    : _shortDurations)
                  DropdownMenuItem(
                      value: value, child: Text(_durationLabel(value))),
              ],
              onChanged: canEdit && off
                  ? (value) => setState(() => _duration = value!)
                  : null,
            ),
          ),
          SwitchListTile(
            title: const Text('后台运行'),
            subtitle: const Text('仅适用于题目只读授权，运行期间显示系统通知。'),
            value: background,
            onChanged: canEdit && off
                ? (value) => setState(() {
                      _background = value;
                      if (!value) {
                        _locked = false;
                        if (!_shortDurations.contains(_duration)) {
                          _duration = AndroidAccessDuration.fifteenMinutes;
                        }
                      }
                    })
                : null,
          ),
          if (background) ...[
            SwitchListTile(
              title: const Text('锁屏后继续读取'),
              subtitle: const Text('仅限本次访问中已在解锁时认证的客户端。'),
              value: locked,
              onChanged: canEdit && off
                  ? (value) => setState(() => _locked = value)
                  : null,
            ),
            if (!state.notificationsAllowed)
              ListTile(
                title: const Text('允许只读访问通知'),
                trailing: const Icon(Icons.notifications_outlined),
                onTap: canEdit && off
                    ? () => unawaited(_run(access.requestNotifications))
                    : null,
              ),
          ],
          if (_error != null)
            ListTile(
                title: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          const Divider(),
          if (state.endpoint case final endpoint?)
            ListTile(
              title: SelectableText(endpoint.toString()),
              trailing: IconButton(
                tooltip: '复制 HTTPS URL',
                icon: const Icon(Icons.copy_outlined),
                onPressed: () =>
                    unawaited(_copy(endpoint.toString(), '已复制 HTTPS URL')),
              ),
            ),
          ListTile(
            title: const Text('导出根 CA 证书'),
            subtitle: state.caFingerprint == null
                ? null
                : SelectableText('SHA-256 ${state.caFingerprint}'),
            trailing: const Icon(Icons.file_download_outlined),
            onTap: canEdit ? _export : null,
          ),
          ListTile(
            title: const Text('Codex 配置模板'),
            subtitle: const Text('首轮支持 · 免 USB 局域网配置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(_configuration(state.endpoint)),
          ),
          const ListTile(
            title: Text('其他客户端'),
            subtitle: Text('WorkBuddy：实验性，部分流程已验证。\nQoder：实验性，仅握手已验证。'),
          ),
          const Divider(),
          ListTile(
            title: const Text('客户端'),
            subtitle: _clients.isEmpty ? const Text('添加客户端后开启访问。') : null,
            trailing: FilledButton.tonalIcon(
              onPressed: canEdit ? _newClient : null,
              icon: const Icon(Icons.add),
              label: const Text('添加'),
            ),
          ),
          for (final client in _clients)
            ListTile(
              title: Text(client.displayName),
              trailing: PopupMenuButton<_ClientAction>(
                enabled: canEdit,
                tooltip: '管理 ${client.displayName}',
                onSelected: (action) =>
                    unawaited(_clientAction(client, action)),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: _ClientAction.grant, child: Text('授权范围')),
                  PopupMenuItem(
                      value: _ClientAction.reissue, child: Text('重新签发 Token')),
                  PopupMenuItem(
                      value: _ClientAction.revoke, child: Text('撤销客户端')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _durationLabel(AndroidAccessDuration value) => switch (value) {
      AndroidAccessDuration.fiveMinutes => '5 分钟',
      AndroidAccessDuration.fifteenMinutes => '15 分钟',
      AndroidAccessDuration.thirtyMinutes => '30 分钟',
      AndroidAccessDuration.oneHour => '1 小时',
      AndroidAccessDuration.twoHours => '2 小时',
      AndroidAccessDuration.fourHours => '4 小时',
      AndroidAccessDuration.eightHours => '8 小时',
      AndroidAccessDuration.untilAppStops => '直到 App 停止',
    };

class _IssuedTokenDialog extends StatefulWidget {
  const _IssuedTokenDialog({required this.token, required this.copyToken});
  final String token;
  final Future<void> Function() copyToken;

  @override
  State<_IssuedTokenDialog> createState() => _IssuedTokenDialogState();
}

class _IssuedTokenDialogState extends State<_IssuedTokenDialog> {
  late final AppLifecycleListener _lifecycle;
  bool _visible = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: (state) {
      if (state != AppLifecycleState.resumed && _visible) {
        setState(() => _visible = false);
      }
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: const Text('客户端 Token 已签发'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Token 只在此处显示一次。请通过你信任的私密渠道传给客户端。'),
            if (_visible)
              Text(widget.token,
                  style: const TextStyle(fontFamily: 'monospace')),
            TextButton(
              onPressed: () => setState(() => _visible = !_visible),
              child: Text(_visible ? '隐藏 Token' : '显示 Token'),
            ),
            if (_status case final status?) Text(status),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('完成')),
          FilledButton(
            onPressed: () async {
              var message = '已复制 Token';
              try {
                await widget.copyToken();
              } catch (_) {
                message = '复制未完成，请保持 App 在前台后重试。';
              }
              if (mounted) setState(() => _status = message);
            },
            child: const Text('复制 Token'),
          ),
        ],
      );
}
