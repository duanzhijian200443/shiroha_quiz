import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/external/external_authorization.dart';
import '../../application/external/first_party_external_access.dart';
import '../../application/external/local_authorization_service.dart';
import '../../application/modules/module_composition.dart';
import '../dependencies/first_party_external_scope.dart';
import '../dependencies/generated_question_dependencies_scope.dart';
import '../generated_question/generated_proposal_inbox_screen.dart';
import 'external_agent_settings_body.dart';
import 'first_party_external_control.dart';

const externalPolicyNotice = '开启后允许外部 Agent 读取 Shiroha 内全部题库与资料。';

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
  FirstPartyExternalAccess? _access;
  ExternalProfileReference? _selected;
  ExternalAuthorizationRecord? _record;
  List<ExternalClientProfile> _profiles = const [];
  FirstPartyExternalStatus _status = const FirstPartyExternalStatus();
  Timer? _timer;
  bool _busy = false, _reading = false, _settingsOpen = false;
  bool _loading = true;
  Future<void>? _refreshing;
  int _operation = 0;
  String? _error;

  bool get _current => mounted && (_view?.isCurrent ?? false);
  bool get _configured =>
      _record?.profile.revokedAtUtcMs == null &&
      _record?.grant?.revokedAtUtcMs == null &&
      _record?.grant?.policy.allContent == true;
  bool get _enabled =>
      _status.enabled && _status.profileId == _selected?.profileId;
  bool get _direct =>
      _record?.grant?.policy.generationMode == ExternalGenerationMode.direct;

  @override
  void initState() {
    super.initState();
    _open();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final access = FirstPartyExternalScope.maybeOf(context);
    if (!identical(access, _access)) {
      _operation++;
      unawaited(_access?.cancelPendingControls().catchError((Object _) {}));
      _access = access;
      _status = const FirstPartyExternalStatus();
      _busy = false;
    }
  }

  @override
  void didUpdateWidget(ExternalAuthorizationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      _operation++;
      _view?.close();
      unawaited(_access?.cancelPendingControls().catchError((Object _) {}));
      _record = null;
      _selected = null;
      _profiles = const [];
      _status = const FirstPartyExternalStatus();
      _busy = false;
      _open();
    }
  }

  @override
  void dispose() {
    _operation++;
    _timer?.cancel();
    _view?.close();
    unawaited(_access?.cancelPendingControls().catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _open() async {
    _loading = true;
    LocalAuthorizationView? view;
    try {
      view = _view = widget.service.openView();
      final profiles = <ExternalClientProfile>[];
      String? cursor;
      do {
        final page = await view.profiles(afterId: cursor);
        if (!_current || !identical(view, _view)) return;
        profiles.addAll(page.items.where((p) => p.revokedAtUtcMs == null));
        cursor = page.nextId;
      } while (cursor != null);
      _profiles = profiles;
      if (profiles.isNotEmpty) {
        await _load(view, await view.select(profiles.first.clientProfileId));
      }
      if (_current && identical(view, _view)) setState(() {});
    } catch (_) {
      if (mounted && (view == null || identical(view, _view))) {
        view?.close();
        setState(() => _error = '授权设置暂不可用，请重新打开页面。');
      }
    } finally {
      if (mounted && (view == null || identical(view, _view))) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _load(
      LocalAuthorizationView view, ExternalProfileReference reference) async {
    final record = await view.read(reference);
    if (!_current || !identical(view, _view)) return;
    _selected = reference;
    _record = record;
  }

  Future<void> _refresh() {
    if (_refreshing case final pending?) return pending;
    final work = _readStatus();
    _refreshing = work;
    return work.whenComplete(() => _refreshing = null);
  }

  Future<void> _readStatus() async {
    if (!_current || _busy || _reading || _settingsOpen || _loading) return;
    _reading = true;
    final view = _view!;
    final access = _access;
    try {
      final status = await access?.status();
      if (_selected case final reference?) await _load(view, reference);
      if (_current && identical(view, _view) && identical(access, _access)) {
        setState(() => _status = status ?? const FirstPartyExternalStatus());
      }
    } catch (_) {
      if (mounted && identical(view, _view)) {
        setState(() {
          _status = const FirstPartyExternalStatus();
          _error = '访问状态暂不可用。';
        });
      }
    } finally {
      _reading = false;
    }
  }

  Future<void> _setAccess(bool enabled) async {
    final access = _access;
    if (!_current || access == null) return;
    if (!enabled) {
      final view = _view;
      final operation = ++_operation;
      bool current() =>
          _current &&
          identical(view, _view) &&
          identical(access, _access) &&
          operation == _operation;
      setState(() => _busy = true);
      try {
        await access.disable();
      } catch (_) {
        if (current()) setState(() => _error = '访问已撤回，连接仍需完成清理。');
      } finally {
        if (current()) {
          setState(() => _busy = false);
          await _refresh();
        }
      }
      return;
    }
    await _change((view, current) async {
      await access.allowConfiguredAccess(_selected?.profileId,
          available: current,
          pendingStatus: _refreshing, prepare: (current, withdraw) async {
        if (_selected == null) {
          final reference = await view.create('外部 Agent');
          if (!current()) return null;
          await _load(view, reference);
        }
        if (!current()) return null;
        if (!_configured) {
          await withdraw();
          if (!current()) return null;
          await view.saveAllContent(_selected!, _record!.profile.grantRevision,
              directWrite: false);
          if (!current()) return null;
          await _load(view, _selected!);
        }
        return current() ? _selected!.profileId : null;
      });
    }, waitForRefresh: false);
  }

  Future<void> _setDirectWrite(bool enabled) => _change((view, current) async {
        final access = _access;
        if (access == null || !_enabled || !_configured) return;
        await access.allowConfiguredAccess(_selected!.profileId,
            available: current,
            pendingStatus: _refreshing, prepare: (current, withdraw) async {
          final reference = _selected!;
          final revision = _record!.profile.grantRevision;
          // Withdraw old contexts inside this same cancellable action.
          await withdraw();
          if (!current()) return null;
          await view.saveAllContent(reference, revision, directWrite: enabled);
          if (!current()) return null;
          await _load(view, reference);
          return current() ? reference.profileId : null;
        });
      }, waitForRefresh: false);

  Future<void> _change(
      Future<void> Function(LocalAuthorizationView, bool Function()) action,
      {bool waitForRefresh = true}) async {
    if (!_current || _busy || _loading) return;
    final view = _view!;
    final access = _access;
    final operation = ++_operation;
    bool current() =>
        _current &&
        identical(view, _view) &&
        identical(access, _access) &&
        operation == _operation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (waitForRefresh && _refreshing != null) await _refreshing;
      if (!current()) return;
      await action(view, current);
    } on ExternalAuthException catch (e) {
      if (current()) {
        _error = switch (e.failure) {
          ExternalAuthFailure.staleRevision => '设置已变更，请核对后重新操作。',
          ExternalAuthFailure.corruptState => '授权设置损坏，访问已拒绝。',
          _ => '连接未完成，请在连接设置中检查首次配对或连接状态。',
        };
      }
    } catch (_) {
      if (current()) _error = '操作未完成，请检查连接设置。';
    } finally {
      if (current()) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  Future<void> _openConnectionSettings() async {
    final access = _access;
    if (access == null || _busy || !_current) return;
    _settingsOpen = true;
    try {
      if (_selected != null && _status.profileId != _selected!.profileId) {
        await access.select(_selected!.profileId);
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('连接设置')),
                body: ListView(padding: const EdgeInsets.all(16), children: [
                  FirstPartyExternalControl(access: access),
                ]),
              )));
    } finally {
      _settingsOpen = false;
      await _refresh();
    }
  }

  void _openReview() {
    final scope = GeneratedQuestionDependenciesScope.maybeOf(context);
    if (scope == null ||
        !scope.contributions.any((c) =>
            c.slot == ModuleUiSlot.workspaceAction &&
            c.key == 'generated_proposal_review')) {
      return;
    }
    Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => GeneratedProposalInboxScreen(dependencies: scope)));
  }

  @override
  Widget build(BuildContext context) {
    final phase = _busy
        ? ExternalAgentAccessPhase.connecting
        : _enabled
            ? ExternalAgentAccessPhase.enabled
            : !_configured
                ? ExternalAgentAccessPhase.setup
                : _error != null
                    ? ExternalAgentAccessPhase.failed
                    : ExternalAgentAccessPhase.disabled;
    return Scaffold(
      appBar: AppBar(title: const Text('外部 Agent')),
      body: ExternalAgentSettingsBody(
        clientName: _record?.profile.displayName ?? '外部 Agent',
        phase: phase,
        directWriteEnabled: _direct,
        allContentConfigured: _configured,
        error: _error,
        onConnect: !_loading && !_busy && _current && _access != null
            ? () => _setAccess(true)
            : null,
        onAccessChanged:
            !_loading && _current && _access != null ? _setAccess : null,
        onDirectWriteChanged: _busy || !_configured ? null : _setDirectWrite,
        onOpenReview: _openReview,
        connectionSettings: Column(children: [
          if (_profiles.length > 1)
            DropdownButtonFormField<String>(
              initialValue: _selected?.profileId,
              decoration: const InputDecoration(labelText: '连接配置'),
              items: [
                for (final p in _profiles)
                  DropdownMenuItem(
                      value: p.clientProfileId, child: Text(p.displayName)),
              ],
              onChanged: _busy
                  ? null
                  : (id) {
                      if (id == null) return;
                      _change((view, current) async {
                        await _access?.disable();
                        if (!current()) return;
                        await _load(view, await view.select(id));
                      });
                    },
            ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('首次配对与连接诊断'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _openConnectionSettings,
          ),
        ]),
      ),
    );
  }
}
