import 'package:flutter/material.dart';
import '../../application/capabilities/capability.dart';
import '../../application/external/external_authorization.dart';
import '../../application/external/local_authorization_service.dart';
import '../dependencies/first_party_external_scope.dart';
import 'first_party_external_control.dart';
import '../generated_question/generated_proposal_inbox_screen.dart';

const externalPolicyNotice = '此处配置访问规则。保存规则不会完成配对或启用业务访问。';

final class ExternalAuthorizationScreen extends StatefulWidget {
  const ExternalAuthorizationScreen({super.key, required this.service});
  final LocalAuthorizationService service;
  @override
  State<ExternalAuthorizationScreen> createState() =>
      _ExternalAuthorizationScreenState();
}

final class _ExternalAuthorizationScreenState
    extends State<ExternalAuthorizationScreen> {
  LocalAuthorizationView? _view;
  final _name = TextEditingController();
  final _profiles = <ExternalClientProfile>[];
  List<LocalAuthorizationTarget> _targets = const [];
  ExternalProfileReference? _selected;
  ExternalAuthorizationRecord? _record;
  String? _nextId, _error;
  bool _busy = false;
  bool _advanced = false;
  final _permissions = <CapabilityPermission>{};
  final _categories = <ExternalContentCategory>{};
  final _scopes = <ExternalGrantScope>{};

  bool get _current => mounted && (_view?.isCurrent ?? false);
  bool get _canCreate =>
      !_busy && _current && (_error == null || _record != null);
  bool get _editable =>
      !_busy &&
      _current &&
      _record != null &&
      _record!.profile.revokedAtUtcMs == null;

  bool get _policySaved {
    final grant = _record?.grant;
    if (grant == null || grant.revokedAtUtcMs != null) return false;
    bool same<T>(Set<T> a, Iterable<T> b) =>
        a.length == b.length && a.containsAll(b);
    return same(_permissions, grant.policy.permissions) &&
        same(_categories, grant.policy.categories) &&
        same(_scopes, grant.policy.scopes);
  }

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(ExternalAuthorizationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      _view?.close();
      _record = null;
      _selected = null;
      _profiles.clear();
      _targets = const [];
      _nextId = null;
      _error = null;
      _permissions.clear();
      _categories.clear();
      _scopes.clear();
      _busy = false;
      _open();
    }
  }

  @override
  void dispose() {
    _view?.close();
    _name.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      _view = widget.service.openView();
    } on ExternalAuthException {
      _error = '管理视图已失效，请重新打开页面。';
      return;
    }
    await _action((view) async {
      final page = await view.profiles();
      final targets = await view.targets();
      if (!_current || !identical(view, _view)) return;
      _profiles
        ..clear()
        ..addAll(page.items);
      _nextId = page.nextId;
      _targets = targets;
      if (page.items.length == 1 &&
          page.nextId == null &&
          page.items.single.revokedAtUtcMs == null) {
        final ref = await view.select(page.items.single.clientProfileId);
        await _loadSelected(ref, view);
      }
    });
  }

  String _failure(ExternalAuthFailure failure) => switch (failure) {
        ExternalAuthFailure.invalidInput =>
          '输入无效：请选择 READ 或 STAGE，Scope 最多 128 项。',
        ExternalAuthFailure.unauthorized => '管理视图或目标已失效，请重新打开页面并核对选择。',
        ExternalAuthFailure.staleRevision => '策略已被其他管理视图修改，已重新读取；请重新编辑并确认。',
        ExternalAuthFailure.corruptState => '授权数据损坏，已安全拒绝编辑。',
        ExternalAuthFailure.persistenceFailed => '授权数据暂不可用，请重新读取。',
      };

  Future<void> _action(
      Future<void> Function(LocalAuthorizationView) action) async {
    if (_busy || !_current) return;
    final view = _view!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(view);
    } on ExternalAuthException catch (e) {
      if (!mounted || !identical(view, _view)) return;
      // Never leave a stale/corrupt editor writable after a failed operation.
      _record = null;
      if (e.failure == ExternalAuthFailure.staleRevision &&
          _current &&
          _selected != null) {
        try {
          await _loadSelected(_selected!, view);
          if (!mounted || !identical(view, _view)) return;
        } on ExternalAuthException catch (reload) {
          if (!mounted || !identical(view, _view)) return;
          _record = null;
          _error = _failure(reload.failure);
        }
      }
      _error ??= _failure(e.failure);
    } catch (_) {
      if (mounted && identical(view, _view)) {
        _record = null;
        _error = '授权数据暂不可用，已拒绝编辑。';
      }
    } finally {
      if (mounted && identical(view, _view)) {
        setState(() {
          _busy = false;
          if (!_current) {
            _record = null;
            _error = '管理视图已失效，请重新打开页面。';
          }
        });
      }
    }
  }

  Future<void> _loadSelected(
      ExternalProfileReference ref, LocalAuthorizationView view) async {
    final record = await view.read(ref);
    final targets = await view.targets();
    if (!_current || !identical(view, _view)) return;
    _selected = ref;
    _record = record;
    _targets = targets;
    final policy = record.grant?.policy;
    _permissions
      ..clear()
      ..addAll(policy?.permissions ?? const []);
    _categories
      ..clear()
      ..addAll(policy?.categories ?? const []);
    _scopes
      ..clear()
      ..addAll(policy?.scopes ?? const []);
    final index =
        _profiles.indexWhere((p) => p.clientProfileId == ref.profileId);
    if (index >= 0) {
      _profiles[index] = record.profile;
    } else {
      _profiles.insert(0, record.profile);
    }
  }

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(title),
                content: Text(text),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确认')),
                ],
              )) ??
      false;

  Future<void> _mutate(String operation) => _action((view) async {
        final ref = _selected!;
        final revision = _record!.profile.grantRevision;
        final permissions = Set<CapabilityPermission>.of(_permissions);
        final categories = Set<ExternalContentCategory>.of(_categories);
        final targets =
            _targets.where((t) => _scopes.contains(t.scope)).toList();
        if (operation == 'save' && targets.length != _scopes.length) {
          throw const ExternalAuthException(ExternalAuthFailure.unauthorized);
        }
        final title = switch (operation) {
          'save' => '保存访问规则',
          'grant' => '撤销 Grant',
          _ => '撤销 Profile'
        };
        final text = switch (operation) {
          'save' => '保存到“${_record!.profile.displayName}”（Revision $revision）：\n'
              '${permissions.map((p) => p == CapabilityPermission.read ? '读取内容' : '提交待审核练习').join(' / ')}\n\n'
              '仅以下 ${targets.length} 个目标：\n${targets.map((t) => t.label + (t.scope.kind == ExternalTargetKind.file ? ' [${t.scope.targetId}]' : '')).join('\n')}\n\n'
              '允许外发：${categories.map(_categoryLabel).join(' / ')}。\n'
              '内容将发送给这个客户端。保存后仍需单独允许本次访问；正式入库仍需审核。',
          'grant' => '撤销当前访问规则。此操作不修改已保存的配对凭据。',
          _ => '永久撤销此 Profile，之后不能重新授权或激活。',
        };
        if (!await _confirm(title, text) ||
            !_current ||
            !identical(view, _view)) {
          return;
        }
        switch (operation) {
          case 'save':
            await view.save(ref, revision,
                permissions: permissions,
                targets: targets,
                categories: categories);
          case 'grant':
            await view.revokeGrant(ref, revision);
          default:
            await view.revokeProfile(ref, revision);
        }
        await _loadSelected(ref, view);
      });

  String _categoryLabel(ExternalContentCategory value) => switch (value) {
        ExternalContentCategory.questionContent => '所选题库的题目内容',
        ExternalContentCategory.fileContent => '所选资料的正文',
        ExternalContentCategory.proposalMetadata => '草稿状态与数量',
      };

  void _chooseTarget(LocalAuthorizationTarget target, bool selected) {
    setState(() {
      if (selected) {
        _scopes.add(target.scope);
        if (!_advanced) {
          _permissions.add(CapabilityPermission.read);
          _categories.add(target.scope.kind == ExternalTargetKind.file
              ? ExternalContentCategory.fileContent
              : ExternalContentCategory.questionContent);
        }
      } else {
        _scopes.remove(target.scope);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final record = _record;
    final missing =
        _scopes.where((scope) => !_targets.any((t) => t.scope == scope));
    return Scaffold(
      appBar: AppBar(title: const Text('外部 Agent 授权')),
      body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: ListView(padding: const EdgeInsets.all(16), children: [
                if (FirstPartyExternalScope.maybeOf(context) case final access?)
                  FirstPartyExternalControl(
                      key: ObjectKey(access),
                      access: access,
                      guided: true,
                      policySaved: _policySaved,
                      profileId: _selected?.profileId,
                      profileName: _record?.profile.displayName),
                const SizedBox(height: 12),
                Text('2. 选择可访问的内容',
                    style: Theme.of(context).textTheme.titleLarge),
                const Text('选择题库或资料，表示允许向该客户端发送对应内容。只读取你明确选择的范围。'),
                const Card(
                    child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(externalPolicyNotice))),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Text(_error!, key: const Key('authorization-error')),
                OutlinedButton(
                    onPressed: _busy || !_current
                        ? null
                        : () => _action((view) async {
                              final page = await view.profiles();
                              if (!_current || !identical(view, _view)) return;
                              _profiles
                                ..clear()
                                ..addAll(page.items);
                              _nextId = page.nextId;
                              if (_selected != null) {
                                await _loadSelected(_selected!, view);
                              }
                            }),
                    child: const Text('重新读取')),
                if (_profiles.isEmpty || _advanced) ...[
                  TextField(
                      controller: _name,
                      enabled: _canCreate,
                      maxLength: 80,
                      decoration: const InputDecoration(
                          labelText: 'Profile 显示名称（不证明身份）')),
                  FilledButton(
                      onPressed: !_canCreate
                          ? null
                          : () => _action((view) async {
                                final ref = await view.create(_name.text);
                                await _loadSelected(ref, view);
                                if (_current) _name.clear();
                              }),
                      child: const Text('新建 Profile')),
                ],
                for (final profile in _profiles)
                  ListTile(
                    key: ValueKey(profile.clientProfileId),
                    title: Text(profile.displayName),
                    subtitle: Text('访问配置 · Revision ${profile.grantRevision} · '
                        '${profile.revokedAtUtcMs == null ? '可用' : '已撤销'}'),
                    selected: _selected?.profileId == profile.clientProfileId,
                    onTap: _busy || !_current
                        ? null
                        : () => _action((view) async {
                              final ref =
                                  await view.select(profile.clientProfileId);
                              await _loadSelected(ref, view);
                            }),
                  ),
                if (_nextId != null)
                  OutlinedButton(
                      onPressed: _busy || !_current
                          ? null
                          : () => _action((view) async {
                                final page =
                                    await view.profiles(afterId: _nextId);
                                if (!_current || !identical(view, _view)) {
                                  return;
                                }
                                for (final item in page.items) {
                                  if (!_profiles.any((p) =>
                                      p.clientProfileId ==
                                      item.clientProfileId)) {
                                    _profiles.add(item);
                                  }
                                }
                                _nextId = page.nextId;
                              }),
                      child: const Text('更多 Profile')),
                if (record != null) ...[
                  const Divider(),
                  if (_advanced) ...[
                    Text('Profile ID：${record.profile.clientProfileId}'),
                    Text(
                        '创建时间：${DateTime.fromMillisecondsSinceEpoch(record.profile.createdAtUtcMs, isUtc: true).toIso8601String()}'),
                  ],
                  Text('当前 Revision：${record.profile.grantRevision}'),
                  Text(record.profile.revokedAtUtcMs != null
                      ? 'Profile 已撤销（不可重新激活）'
                      : record.grant == null
                          ? '无 Grant'
                          : record.grant!.revokedAtUtcMs != null
                              ? 'Grant 已撤销'
                              : '已保存访问规则'),
                  if (!_advanced)
                    CheckboxListTile(
                        title: const Text('允许提交待审核练习'),
                        subtitle: const Text('只暂存草稿并查询状态；正式保存由你在 Review 决定。'),
                        value:
                            _permissions.contains(CapabilityPermission.stage),
                        onChanged: !_editable
                            ? null
                            : (value) => setState(() {
                                  if (value!) {
                                    _permissions.addAll([
                                      CapabilityPermission.read,
                                      CapabilityPermission.stage
                                    ]);
                                    _categories.add(ExternalContentCategory
                                        .proposalMetadata);
                                  } else {
                                    _permissions
                                        .remove(CapabilityPermission.stage);
                                  }
                                })),
                  if (_advanced) ...[
                    const Text('Permission（不包含正式提交或删除权限）'),
                    for (final permission in [
                      CapabilityPermission.read,
                      CapabilityPermission.stage
                    ])
                      CheckboxListTile(
                          title: Text(permission.name.toUpperCase()),
                          value: _permissions.contains(permission),
                          onChanged: !_editable
                              ? null
                              : (value) => setState(() {
                                    value!
                                        ? _permissions.add(permission)
                                        : _permissions.remove(permission);
                                  })),
                  ],
                  const Text('题库与资料：未选中的内容不会授权。'),
                  if (_scopes.any((file) =>
                      file.kind == ExternalTargetKind.file &&
                      !_scopes.any((bank) =>
                          bank.kind == ExternalTargetKind.bank &&
                          bank.projectId == file.projectId)))
                    const Text('阅读资料还需要选择同一空间的题库作为上下文；不会自动选择或扩大题库范围。'),
                  for (final target in _targets)
                    CheckboxListTile(
                        title: Text(target.label),
                        subtitle: _advanced
                            ? Text(
                                'Target：${target.scope.targetId} · Project：${target.scope.projectId ?? '本地'}')
                            : target.scope.kind == ExternalTargetKind.file
                                ? Text(
                                    '读取此资料正文 · 标识 ${target.scope.targetId.substring(target.scope.targetId.length > 8 ? target.scope.targetId.length - 8 : 0)}')
                                : const Text('读取题目内容；可作为已批准练习的目标题库'),
                        value: _scopes.contains(target.scope),
                        onChanged: !_editable
                            ? null
                            : (value) => _chooseTarget(target, value!)),
                  for (final scope in missing)
                    ListTile(
                        title: const Text('目标已失效：请明确移除'),
                        subtitle: Text(
                            '${scope.kind.name} · ${scope.targetId} · ${scope.projectId ?? '本地'}'),
                        trailing: TextButton(
                            onPressed: !_editable
                                ? null
                                : () => setState(() => _scopes.remove(scope)),
                            child: const Text('移除失效目标'))),
                  if (!_advanced &&
                      _scopes.any((s) => s.kind == ExternalTargetKind.file) &&
                      (!_categories
                              .contains(ExternalContentCategory.fileContent) ||
                          !_permissions.contains(CapabilityPermission.read)))
                    ListTile(
                        title: const Text('所选资料尚未允许正文读取'),
                        subtitle: const Text('旧规则保留了文件选择，但没有正文出站权限。'),
                        trailing: TextButton(
                            onPressed: !_editable
                                ? null
                                : () => setState(() {
                                      _permissions
                                          .add(CapabilityPermission.read);
                                      _categories.add(
                                          ExternalContentCategory.fileContent);
                                    }),
                            child: const Text('允许读取所选资料'))),
                  if (_advanced) ...[
                    const Text('Egress：独立选择允许向该 Client 外发的内容；READ 不自动允许外发。'),
                    for (final category in ExternalContentCategory.values)
                      CheckboxListTile(
                          title: Text(category.name),
                          value: _categories.contains(category),
                          onChanged: !_editable
                              ? null
                              : (value) => setState(() {
                                    value!
                                        ? _categories.add(category)
                                        : _categories.remove(category);
                                  })),
                  ],
                  Text(
                      '保存后允许外发：${_categories.map(_categoryLabel).join(' / ')}'),
                  FilledButton(
                      onPressed: !_editable ||
                              _permissions.isEmpty ||
                              missing.isNotEmpty ||
                              _scopes.length > ExternalAuthLimits.maxScopes
                          ? null
                          : () => _mutate('save'),
                      child: const Text('保存策略')),
                  OutlinedButton(
                      onPressed: !_editable ||
                              record.grant == null ||
                              record.grant!.revokedAtUtcMs != null
                          ? null
                          : () => _mutate('grant'),
                      child: const Text('撤销 Grant')),
                  if (_advanced)
                    OutlinedButton(
                        onPressed: !_editable ? null : () => _mutate('profile'),
                        child: const Text('撤销 Profile')),
                ],
                SwitchListTile(
                    title: const Text('高级权限字段'),
                    subtitle: const Text('管理配置、独立权限与诊断字段'),
                    value: _advanced,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _advanced = value)),
                const SizedBox(height: 24),
                Text('3. 待审核与正式入库',
                    style: Theme.of(context).textTheme.titleLarge),
                const Text('只有已批准暂存且成功发布的草稿才会出现。这里的批准或拒绝是另一项独立决定。'),
                const SizedBox(height: 8),
                const GeneratedProposalWorkspaceAction(label: '打开待审核题目'),
              ]))),
    );
  }
}
