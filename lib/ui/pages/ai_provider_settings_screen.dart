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
      appBar: AppBar(title: const Text('API 提供商与模型')),
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
  late final TextEditingController _firstModelIdController;
  late final TextEditingController _firstModelNameController;
  late AiProviderOverview? _existing;
  late AiProviderKind _kind;

  /// Set once createProvider succeeded and cleared when the editor adopted
  /// the created provider. While set, saving is disabled so a failed
  /// adoption can never produce a duplicate provider.
  String? _createdProviderId;
  bool _busy = false;
  bool _modelsLoading = false;
  List<AiModelRecord> _models = const <AiModelRecord>[];
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
    _firstModelIdController = TextEditingController();
    _firstModelNameController = TextEditingController();
    if (_existing != null) _loadModels();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _credentialController.dispose();
    _firstModelIdController.dispose();
    _firstModelNameController.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    final id = _existing?.provider.providerId;
    if (id == null) return;
    setState(() => _modelsLoading = true);
    try {
      final models = await widget.service.listModelsForProvider(id);
      if (!mounted) return;
      setState(() => _models = models);
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = '暂时无法读取模型列表');
    } finally {
      if (mounted) setState(() => _modelsLoading = false);
    }
  }

  Future<void> _addModel() async {
    final id = _existing?.provider.providerId;
    if (id == null || _busy) return;
    final added = await showDialog<String>(
      context: context,
      builder: (_) => _AddModelDialog(service: widget.service, providerId: id),
    );
    if (added == null || !mounted) return;
    await _loadModels();
    if (!mounted) return;
    setState(() => _message = '模型已添加');
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
        final createdId = await widget.service.createProvider(
          kind: _kind,
          displayName: _nameController.text,
          baseUrl: _baseUrlController.text,
          credential: _credentialController.text,
        );
        setState(() => _createdProviderId = createdId);
        final firstModelId = _firstModelIdController.text.trim();
        if (firstModelId.isEmpty) {
          if (mounted) Navigator.of(context).pop();
          return;
        }
        try {
          await widget.service.addCustomModel(
            providerId: createdId,
            canonicalModelId: firstModelId,
            displayName: _firstModelNameController.text,
          );
        } catch (_) {
          // Partial success across two authorities: the Provider and its
          // credential stay, no destructive rollback; the user retries the
          // first model from this provider's own editor.
          await _adoptCreatedProvider(createdId);
          return;
        }
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

  Future<void> _adoptCreatedProvider(String createdId) async {
    AiProviderOverview? created;
    try {
      created = (await widget.service.listProviders())
          .where((item) => item.provider.providerId == createdId)
          .firstOrNull;
    } catch (_) {
      created = null;
    }
    if (!mounted) return;
    setState(() {
      if (created != null) {
        _existing = created;
        _createdProviderId = null;
      }
      _message = 'API 提供商已保存，但首个模型添加失败，请进入该提供商后重试。';
    });
    await _loadModels();
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
      await _loadModels();
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
                    decoration: InputDecoration(
                      labelText: 'Provider',
                      helperText: _kind == AiProviderKind.openAiCompatible
                          ? '使用 OpenAI Compatible 协议接入未预置的模型提供商。'
                          : null,
                      border: const OutlineInputBorder(),
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
                  if (!existing) ...<Widget>[
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const ValueKey<String>(
                        'provider-first-model-id-field',
                      ),
                      controller: _firstModelIdController,
                      decoration: const InputDecoration(
                        labelText: '首个 Model ID',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          _kind == AiProviderKind.openAiCompatible &&
                                  (value == null || value.trim().isEmpty)
                              ? '自定义模型提供商必须填写首个 Model ID'
                              : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const ValueKey<String>(
                        'provider-first-model-name-field',
                      ),
                      controller: _firstModelNameController,
                      decoration: const InputDecoration(
                        labelText: 'Model Display Name（可选）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
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
                  if (existing) ...<Widget>[
                    const SizedBox(height: DesignTokens.sectionGap),
                    _ProviderModelSection(
                      key: const ValueKey<String>('provider-model-section'),
                      models: _models,
                      loading: _modelsLoading,
                      busy: _busy,
                      onAdd: _addModel,
                    ),
                  ],
                  if (_message != null) ...<Widget>[
                    const SizedBox(height: 16),
                    _ProviderNotice(message: _message!),
                  ],
                  const SizedBox(height: DesignTokens.sectionGap),
                  FilledButton.icon(
                    key: const ValueKey<String>('provider-save-button'),
                    onPressed:
                        _busy || _createdProviderId != null ? null : _save,
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
      // Product label only: the storage kind stays AiProviderKind.openAiCompatible.
      AiProviderKind.deepseek => 'DeepSeek',
      AiProviderKind.zhipu => '智谱 AI',
      AiProviderKind.gemini => 'Gemini',
      AiProviderKind.openAiCompatible => '自定义模型提供商',
    };

String? _modelOriginLabel(AiModelOrigin origin) => switch (origin) {
      AiModelOrigin.providerCatalog => '官方目录',
      AiModelOrigin.curated => '内置',
      AiModelOrigin.userDefined => '手动添加',
      // Migration-only origin; never exposed as a user-facing product label.
      AiModelOrigin.legacyImported => null,
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

class _ProviderModelSection extends StatelessWidget {
  const _ProviderModelSection({
    super.key,
    required this.models,
    required this.loading,
    required this.busy,
    required this.onAdd,
  });

  final List<AiModelRecord> models;
  final bool loading;
  final bool busy;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '模型',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (models.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '暂无模型。可刷新模型列表或手动添加。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          )
        else
          for (final model in models)
            ListTile(
              key: ValueKey<String>('provider-model-${model.modelRef}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              minVerticalPadding: 4,
              title: Text(
                model.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: model.displayName == model.canonicalModelId
                  ? null
                  : Text(
                      model.canonicalModelId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: switch (_modelOriginLabel(model.origin)) {
                final String? label when label != null => Text(
                    label,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                _ => null,
              },
            ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey<String>('provider-add-model-button'),
          onPressed: busy ? null : onAdd,
          icon: const Icon(Icons.add_rounded),
          label: const Text('添加模型'),
        ),
      ],
    );
  }
}

class _AddModelDialog extends StatefulWidget {
  const _AddModelDialog({required this.service, required this.providerId});

  final AiConfigPresentationService service;
  final String providerId;

  @override
  State<_AddModelDialog> createState() => _AddModelDialogState();
}

class _AddModelDialogState extends State<_AddModelDialog> {
  final _formKey = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _name = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final ref = await widget.service.addCustomModel(
        providerId: widget.providerId,
        canonicalModelId: _id.text.trim(),
        displayName: _name.text,
      );
      if (mounted) Navigator.of(context).pop(ref);
    } on AiConfigException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.failure == AiConfigFailure.invalidInput
              ? '请输入有效的 Model ID，不要包含首尾空格'
              : '保存失败，请重试',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加模型'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextFormField(
                key: const ValueKey<String>('provider-model-id-field'),
                controller: _id,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'Model ID *'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? '请输入 Model ID'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey<String>('provider-model-name-field'),
                controller: _name,
                enabled: !_saving,
                decoration:
                    const InputDecoration(labelText: 'Display Name（可选）'),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('provider-save-model'),
          onPressed: _saving ? null : _save,
          child: const Text('添加'),
        ),
      ],
    );
  }
}
