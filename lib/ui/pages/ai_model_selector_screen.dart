import 'package:flutter/material.dart';

import '../../application/ai_config/ai_config_service.dart';
import '../../domain/ai_config/ai_config_contracts.dart';
import '../theme/design_tokens.dart';
import '../widgets/shiroha_settings_components.dart';

class AiModelSelectorScreen extends StatefulWidget {
  const AiModelSelectorScreen({
    super.key,
    required this.service,
    required this.slot,
  });

  final AiConfigPresentationService service;
  final AiCapabilitySlot slot;

  @override
  State<AiModelSelectorScreen> createState() => _AiModelSelectorScreenState();
}

class _AiModelSelectorScreenState extends State<AiModelSelectorScreen> {
  bool _loading = true;
  bool _saving = false;
  List<AiModelCompatibility> _models = const <AiModelCompatibility>[];
  AiCapabilityBindingSummary? _current;
  String? _selectedModelRef;
  String? _message;
  String _searchQuery = '';
  String? _expandedProviderId;
  String? _preSearchExpandedProviderId;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final current = await widget.service.bindingSummary(widget.slot);
      final models = await widget.service.listModelsForSlot(widget.slot);
      if (!mounted) return;
      setState(() {
        _current = current;
        _models = models;
        final currentRef = current?.model.modelRef;
        _selectedModelRef = models.any(
          (model) => model.compatible && model.model.modelRef == currentRef,
        )
            ? currentRef
            : null;
        _expandedProviderId = current?.model.providerId;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = '暂时无法读取模型列表';
      });
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      if (_searchQuery.isEmpty && value.isNotEmpty) {
        _preSearchExpandedProviderId = _expandedProviderId;
      }
      _searchQuery = value;
      if (value.isEmpty) {
        _expandedProviderId = _preSearchExpandedProviderId;
      }
    });
  }

  void _toggleProvider(String providerId) {
    setState(() {
      _expandedProviderId =
          _expandedProviderId == providerId ? null : providerId;
    });
  }

  Future<void> _addCustomModel() async {
    try {
      final providers = await widget.service.listProviders();
      if (!mounted) return;
      if (providers.isEmpty) {
        setState(() => _message = '请先添加 Provider');
        return;
      }
      final result = await showDialog<String>(
        context: context,
        builder: (_) =>
            _CustomModelDialog(service: widget.service, providers: providers),
      );
      if (result == null || !mounted) return;
      await _load();
      if (!mounted) return;
      setState(() {
        if (_models
            .any((item) => item.model.modelRef == result && item.compatible)) {
          _selectedModelRef = result;
          _expandedProviderId = _models
              .singleWhere((item) => item.model.modelRef == result)
              .model
              .providerId;
          _message = '模型已添加，请确认并应用模型。能力未标注时，请确认该模型支持此用途。';
        }
      });
    } catch (_) {
      if (mounted) setState(() => _message = '暂时无法添加自定义模型');
    }
  }

  Future<void> _confirm() async {
    final selected = _selectedModelRef;
    if (selected == null) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await widget.service.applyBinding(
        slot: widget.slot,
        modelRef: selected,
        expectedRevision: _current?.binding.revision,
        temperature: _current?.binding.temperature ??
            (widget.slot == AiCapabilitySlot.documentRecognition ? 0.0 : 0.7),
        reasoningEffort: _current?.binding.reasoningEffort ?? '',
      );
      if (mounted) Navigator.of(context).pop(true);
    } on AiConfigException catch (error) {
      if (!mounted) return;
      setState(() => _message = _bindingError(error.failure));
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = '应用失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final searching = _searchQuery.trim().isNotEmpty;
    final visibleModels = searching ? _searchMatches() : _models;
    final providerGroups = _groupByProvider(visibleModels);
    return Scaffold(
      appBar: AppBar(title: Text('选择模型 · ${_slotName(widget.slot)}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RadioGroup<String>(
              groupValue: _selectedModelRef,
              onChanged: _saving
                  ? (_) {}
                  : (value) => setState(() => _selectedModelRef = value),
              child: ShirohaPageBody(
                children: <Widget>[
                  if (_message != null) ...<Widget>[
                    _Notice(message: _message!),
                    const SizedBox(height: 16),
                  ],
                  OutlinedButton.icon(
                    key: const ValueKey<String>('add-custom-model'),
                    onPressed: _saving ? null : _addCustomModel,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('添加自定义模型'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey<String>('model-search-field'),
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    decoration: const InputDecoration(
                      hintText: '搜索模型',
                      prefixIcon: Icon(Icons.search_rounded),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  if (_current != null) ...<Widget>[
                    const SizedBox(height: DesignTokens.sectionGap),
                    _CurrentSelection(
                      summary: _current!,
                      slotName: _slotName(widget.slot),
                    ),
                  ],
                  const SizedBox(height: DesignTokens.sectionGap),
                  if (_models.isEmpty)
                    ShirohaSurfaceCard(
                      child: Padding(
                        padding: const EdgeInsets.all(
                          DesignTokens.cardInternalPadding,
                        ),
                        child: Text(_emptyStateMessage),
                      ),
                    )
                  else if (searching && providerGroups.isEmpty)
                    const ShirohaSurfaceCard(
                      child: Padding(
                        padding: EdgeInsets.all(
                          DesignTokens.cardInternalPadding,
                        ),
                        child: Text('没有匹配的模型'),
                      ),
                    )
                  else
                    for (final entry in providerGroups.entries)
                      _providerAccordion(
                        entry.value,
                        expanded: searching || _expandedProviderId == entry.key,
                        onToggle: () => _toggleProvider(entry.key),
                      ),
                  if (!searching &&
                      _models.isNotEmpty &&
                      _models.every((model) => !model.compatible))
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '当前没有可用于此功能的模型。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: DesignTokens.sectionGap),
                  FilledButton.icon(
                    key: const ValueKey<String>('model-confirm-button'),
                    onPressed:
                        _saving || _selectedModelRef == null ? null : _confirm,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(_saving ? '应用中…' : '确认并应用模型'),
                  ),
                ],
              ),
            ),
    );
  }

  String get _emptyStateMessage {
    if (_models.isEmpty) {
      return '尚未发现任何模型，请前往 Provider 页面刷新模型列表。';
    }
    return '当前没有可用于此功能的模型。';
  }

  List<AiModelCompatibility> _searchMatches() {
    final query = _searchQuery.trim().toLowerCase();
    return _models
        .where(
          (item) =>
              item.model.displayName.toLowerCase().contains(query) ||
              item.model.canonicalModelId.toLowerCase().contains(query) ||
              item.provider.displayName.toLowerCase().contains(query),
        )
        .toList();
  }

  Widget _providerAccordion(
    List<AiModelCompatibility> models, {
    required bool expanded,
    required VoidCallback onToggle,
  }) {
    final provider = models.first.provider;
    final boundHere =
        _current != null && _current!.model.providerId == provider.providerId;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ShirohaSurfaceCard(
        child: Column(
          children: <Widget>[
            InkWell(
              key: ValueKey<String>('provider-header-${provider.providerId}'),
              onTap: onToggle,
              borderRadius:
                  BorderRadius.circular(DesignTokens.cardInternalPadding),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: DesignTokens.cardInternalPadding,
                  vertical: 12,
                ),
                child: Row(
                  children: <Widget>[
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: const Icon(Icons.expand_more_rounded),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  provider.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                              ),
                              if (provider.kind ==
                                  AiProviderKind.openAiCompatible) ...<Widget>[
                                const SizedBox(width: 6),
                                Text(
                                  '自定义/OpenAI兼容',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ],
                          ),
                          if (boundHere)
                            Text(
                              '当前：${_current!.model.displayName}',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${models.length} 个',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: expanded
                  ? Column(
                      children: models
                          .map((model) => _modelTile(model))
                          .toList(growable: false),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelTile(AiModelCompatibility item) {
    final colors = Theme.of(context).colorScheme;
    final selected = item.model.modelRef == _selectedModelRef;
    final enabled = item.compatible && !_saving;
    final sameId = item.model.displayName == item.model.canonicalModelId;
    final tags = item.capabilities.entries
        .where((entry) => entry.value == AiCapabilitySupport.supported)
        .map((entry) => _capabilityName(entry.key))
        .toList(growable: false);
    final unsupported =
        item.selectionState == AiModelSelectionState.unsupported;
    final unannotated =
        item.selectionState == AiModelSelectionState.unannotated;
    return RadioListTile<String>(
      key: ValueKey<String>('model-${item.model.modelRef}'),
      value: item.model.modelRef,
      enabled: enabled,
      selected: selected,
      title: Text(item.model.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!sameId) Text(item.model.canonicalModelId),
          if (tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: tags
                    .map(
                      (tag) => Chip(
                        label: Text(tag),
                        visualDensity: VisualDensity.compact,
                        side: BorderSide(color: colors.outlineVariant),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          if (unannotated)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '能力未标注',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
          if (unsupported)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '不支持当前功能',
                style: TextStyle(color: colors.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _CurrentSelection extends StatelessWidget {
  const _CurrentSelection({required this.summary, required this.slotName});

  final AiCapabilityBindingSummary summary;
  final String slotName;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ShirohaSurfaceCard(
      key: const ValueKey<String>('current-selection'),
      child: Padding(
        padding: const EdgeInsets.all(DesignTokens.cardInternalPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '当前选择 · $slotName',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              summary.model.displayName,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              summary.provider.displayName,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (summary.model.availability == AiModelAvailability.unavailable)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '当前模型目录未返回此模型',
                  style: TextStyle(color: colors.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Map<String, List<AiModelCompatibility>> _groupByProvider(
  List<AiModelCompatibility> models,
) {
  final result = <String, List<AiModelCompatibility>>{};
  for (final model in models) {
    result.putIfAbsent(model.provider.providerId, () => []).add(model);
  }
  return result;
}

String _slotName(AiCapabilitySlot slot) => switch (slot) {
      AiCapabilitySlot.textModel => '文本模型',
      AiCapabilitySlot.imageUnderstanding => '图片理解',
      AiCapabilitySlot.documentRecognition => '文档识别',
    };

String _capabilityName(AiModelCapability capability) => switch (capability) {
      AiModelCapability.textInput => '文本输入',
      AiModelCapability.imageInput => '图片输入',
      AiModelCapability.textOutput => '文本输出',
      AiModelCapability.reasoning => '推理',
      AiModelCapability.toolCalling => '工具调用',
      AiModelCapability.ocr => 'OCR',
      AiModelCapability.embedding => '向量',
    };

String _bindingError(AiConfigFailure failure) => switch (failure) {
      AiConfigFailure.staleRevision => '配置已在其他位置更新，请重新选择',
      AiConfigFailure.modelUnavailable => '该模型已不可用',
      AiConfigFailure.capabilityUnknown => '能力未标注',
      AiConfigFailure.capabilityUnsupported => '模型不支持当前能力',
      _ => '应用失败，请刷新后重试',
    };

class _Notice extends StatelessWidget {
  const _Notice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
      ),
      child: Text(message, style: TextStyle(color: colors.onErrorContainer)),
    );
  }
}

class _CustomModelDialog extends StatefulWidget {
  const _CustomModelDialog({
    required this.service,
    required this.providers,
  });

  final AiConfigPresentationService service;
  final List<AiProviderOverview> providers;

  @override
  State<_CustomModelDialog> createState() => _CustomModelDialogState();
}

class _CustomModelDialogState extends State<_CustomModelDialog> {
  final TextEditingController _id = TextEditingController();
  final TextEditingController _name = TextEditingController();
  late String _providerId = widget.providers.first.provider.providerId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final ref = await widget.service.addCustomModel(
        providerId: _providerId,
        canonicalModelId: _id.text,
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
      title: const Text('添加自定义模型'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            DropdownButtonFormField<String>(
              key: const ValueKey<String>('custom-model-provider'),
              initialValue: _providerId,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: widget.providers
                  .map(
                    (item) => DropdownMenuItem<String>(
                      value: item.provider.providerId,
                      child: Text(item.provider.displayName),
                    ),
                  )
                  .toList(growable: false),
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _providerId = value!),
            ),
            TextField(
              key: const ValueKey<String>('custom-model-id'),
              controller: _id,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: 'Model ID *'),
            ),
            TextField(
              key: const ValueKey<String>('custom-model-name'),
              controller: _name,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: 'Display Name（可选）'),
            ),
            if (_error != null) Text(_error!),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('save-custom-model'),
          onPressed: _saving ? null : _save,
          child: const Text('添加'),
        ),
      ],
    );
  }
}
