import 'package:flutter/material.dart';

import '../../application/ai_config/ai_config_service.dart';
import '../../domain/ai_config/ai_config_contracts.dart';
import '../theme/design_tokens.dart';
import '../widgets/shiroha_settings_components.dart';

class AiProviderSettingsScreen extends StatefulWidget {
  const AiProviderSettingsScreen({super.key, required this.service});

  final AiConfigPresentationService service;

  @override
  State<AiProviderSettingsScreen> createState() =>
      _AiProviderSettingsScreenState();
}

class _AiProviderSettingsScreenState extends State<AiProviderSettingsScreen> {
  bool _loading = true;
  List<AiProviderOverview> _providers = const <AiProviderOverview>[];
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final providers = await widget.service.listProviders();
      if (!mounted) return;
      setState(() {
        _providers = providers;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = '暂时无法读取 API 提供商';
      });
    }
  }

  Future<void> _openEditor([AiProviderOverview? provider]) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AiProviderEditorScreen(
          service: widget.service,
          existing: provider,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _delete(AiProviderOverview provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 API 提供商？'),
        content: Text(
          '将删除“${provider.provider.displayName}”及其模型记录。'
          '正在被能力或 Agent 使用时，系统会拒绝删除。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.service.deleteProvider(provider.provider.providerId);
      await _load();
    } on AiConfigException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error.failure == AiConfigFailure.providerInUse
            ? '该提供商正在被模型能力或 Agent 使用，无法删除'
            : '删除失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('API 提供商与密钥')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ShirohaPageBody(
              children: <Widget>[
                if (_message != null) ...<Widget>[
                  _ProviderNotice(message: _message!),
                  const SizedBox(height: 16),
                ],
                if (_providers.isEmpty)
                  const ShirohaSurfaceCard(
                    child: Padding(
                      padding: EdgeInsets.all(
                        DesignTokens.cardInternalPadding,
                      ),
                      child: Text('尚未添加 API 提供商。密钥只会保存在安全凭据存储中。'),
                    ),
                  )
                else
                  for (final provider in _providers) ...<Widget>[
                    _ProviderCard(
                      overview: provider,
                      onEdit: () => _openEditor(provider),
                      onDelete: () => _delete(provider),
                    ),
                    const SizedBox(height: 12),
                  ],
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey<String>('provider-add-button'),
                  onPressed: _openEditor,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('添加提供商'),
                ),
              ],
            ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.overview,
    required this.onEdit,
    required this.onDelete,
  });

  final AiProviderOverview overview;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final provider = overview.provider;
    final status = switch ((
      overview.credentialState,
      provider.lastConnectionStatus,
      provider.lastSyncStatus,
    )) {
      (AiCredentialState.missing, _, _) => '缺少 API Key',
      (AiCredentialState.unavailable, _, _) => '凭据暂不可用',
      (_, AiOperationStatus.failed, _) => '连接测试失败',
      (_, _, AiOperationStatus.failed) => '模型列表刷新失败',
      _ when provider.state == AiProviderState.legacyIncomplete => '需要完善配置',
      _ => '已就绪',
    };
    final ready = status == '已就绪';
    return ShirohaSurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(DesignTokens.cardInternalPadding),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.cloud_done_outlined,
              color: ready
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.tertiary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    provider.displayName,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(status),
                  Text('当前模型 ${overview.modelCount} 个'),
                ],
              ),
            ),
            TextButton(onPressed: onEdit, child: const Text('编辑')),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'delete') onDelete();
              },
              itemBuilder: (_) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class AiProviderEditorScreen extends StatefulWidget {
  const AiProviderEditorScreen({
    super.key,
    required this.service,
    this.existing,
  });

  final AiConfigPresentationService service;
  final AiProviderOverview? existing;

  @override
  State<AiProviderEditorScreen> createState() => _AiProviderEditorScreenState();
}

class _AiProviderEditorScreenState extends State<AiProviderEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _credentialController;
  late AiProviderOverview? _existing;
  late AiProviderKind _kind;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _existing = widget.existing;
    final provider = _existing?.provider;
    _kind = provider?.kind ?? AiProviderKind.deepseek;
    _nameController = TextEditingController(text: provider?.displayName ?? '');
    _baseUrlController = TextEditingController(text: provider?.baseUrl ?? '');
    _credentialController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _credentialController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final existing = _existing;
      if (existing == null) {
        await widget.service.createProvider(
          kind: _kind,
          displayName: _nameController.text,
          baseUrl: _baseUrlController.text,
          credential: _credentialController.text,
        );
      } else {
        await widget.service.updateProvider(
          providerId: existing.provider.providerId,
          expectedRevision: existing.provider.revision,
          kind: _kind,
          displayName: _nameController.text,
          baseUrl: _baseUrlController.text,
          replacementCredential: _credentialController.text.isEmpty
              ? null
              : _credentialController.text,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } on AiConfigException catch (error) {
      if (!mounted) return;
      setState(() => _message = _providerError(error.failure));
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = '保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runExisting(Future<void> Function(String) action) async {
    final id = _existing?.provider.providerId;
    if (id == null || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action(id);
      if (!mounted) return;
      final refreshed = (await widget.service.listProviders())
          .where((item) => item.provider.providerId == id)
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        _existing = refreshed ?? _existing;
        _message = '操作成功';
      });
    } on AiConfigException catch (error) {
      if (!mounted) return;
      setState(() => _message = _providerError(error.failure));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testDraft() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.service.testConnectionDraft(
        providerId: _existing?.provider.providerId,
        kind: _kind,
        baseUrl: _baseUrlController.text,
        credential: _credentialController.text,
      );
      if (!mounted) return;
      setState(() => _message = '连接测试成功');
    } on AiConfigException catch (error) {
      if (!mounted) return;
      setState(() => _message = _providerError(error.failure));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = _existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(existing ? '编辑 API 提供商' : '添加 API 提供商')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: DesignTokens.contentMaxWidth,
            ),
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(
                  DesignTokens.pageHorizontalPadding,
                ),
                children: <Widget>[
                  DropdownButtonFormField<AiProviderKind>(
                    key: const ValueKey<String>('provider-kind-field'),
                    initialValue: _kind,
                    decoration: const InputDecoration(
                      labelText: 'Provider',
                      border: OutlineInputBorder(),
                    ),
                    items: AiProviderKind.values
                        .map(
                          (kind) => DropdownMenuItem<AiProviderKind>(
                            value: kind,
                            child: Text(_providerKindName(kind)),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _busy || existing
                        ? null
                        : (value) => setState(() => _kind = value!),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey<String>('provider-name-field'),
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: '显示名称',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '请输入显示名称'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey<String>('provider-key-field'),
                    controller: _credentialController,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      hintText: existing ? '留空以保留现有密钥' : null,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        !existing && (value == null || value.trim().isEmpty)
                            ? '新 Provider 必须填写 API Key'
                            : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey<String>('provider-base-url-field'),
                    controller: _baseUrlController,
                    readOnly: existing && _existing!.hasModelAuthority,
                    decoration: InputDecoration(
                      labelText: 'Base URL',
                      helperText: existing && _existing!.hasModelAuthority
                          ? '已有模型时不可修改，请新建 Provider 实例'
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '请输入 Base URL'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: <Widget>[
                      OutlinedButton.icon(
                        key: const ValueKey<String>(
                          'provider-test-connection',
                        ),
                        onPressed: _busy ? null : _testDraft,
                        icon: const Icon(Icons.network_check),
                        label: const Text('测试连接'),
                      ),
                      if (existing)
                        OutlinedButton.icon(
                          key: const ValueKey<String>('provider-sync-models'),
                          onPressed: _busy
                              ? null
                              : () => _runExisting(widget.service.syncModels),
                          icon: const Icon(Icons.sync_rounded),
                          label: const Text('刷新模型列表'),
                        ),
                    ],
                  ),
                  if (_message != null) ...<Widget>[
                    const SizedBox(height: 16),
                    _ProviderNotice(message: _message!),
                  ],
                  const SizedBox(height: DesignTokens.sectionGap),
                  FilledButton.icon(
                    key: const ValueKey<String>('provider-save-button'),
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_busy ? '处理中…' : '保存配置'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _providerKindName(AiProviderKind kind) => switch (kind) {
      AiProviderKind.deepseek => 'DeepSeek',
      AiProviderKind.zhipu => '智谱 AI',
      AiProviderKind.gemini => 'Gemini',
      AiProviderKind.openAiCompatible => 'OpenAI Compatible',
    };

String _providerError(AiConfigFailure failure) => switch (failure) {
      AiConfigFailure.credentialMissing => '缺少 API Key',
      AiConfigFailure.connectionRejected => '连接被拒绝，请检查密钥',
      AiConfigFailure.syncFailed => '模型列表刷新失败，原有模型列表未改变',
      AiConfigFailure.staleRevision => '配置已被更新，请返回后重试',
      AiConfigFailure.providerInUse => 'Provider 正在使用中，无法删除',
      AiConfigFailure.invalidInput => '配置内容无效，请检查后重试',
      _ => '操作失败，请稍后重试',
    };

class _ProviderNotice extends StatelessWidget {
  const _ProviderNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
      ),
      child: Text(message),
    );
  }
}
