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
  bool _showUnusable = false;
  List<AiModelCompatibility> _models = const <AiModelCompatibility>[];
  AiCapabilityBindingSummary? _current;
  String? _selectedModelRef;
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
    final selectable = _models
        .where(
          (model) => model.compatible,
        )
        .toList();
    final unusable = _models
        .where(
          (model) => model.selectionState == AiModelSelectionState.unsupported,
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text('选择模型 · ${_slotName(widget.slot)}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RadioGroup<String>(
              groupValue: _selectedModelRef,
              onChanged: _saving
                  ? (_) {}
                  : (value) => setState(() {
                        _selectedModelRef = value;
                        final item = _models
                            .where((item) => item.model.modelRef == value)
                            .firstOrNull;
                        _message = item?.selectionState ==
                                AiModelSelectionState.unannotated
                            ? 'Shiroha 尚未标注该模型的当前能力，请确认该模型支持此用途。'
                            : null;
                      }),
              child: ShirohaPageBody(
                children: <Widget>[
                  if (_message != null) ...<Widget>[
                    _Notice(message: _message!),
                    const SizedBox(height: 16),
                  ],
                  OutlinedButton.icon(
                    key: const ValueKey<String>('add-custom-model'),
                    onPressed: _saving ? null : _addCustomModel,
                    icon: const Icon(Icons.add),
                    label: const Text('添加自定义模型'),
                  ),
                  if (_current?.model.availability ==
                      AiModelAvailability.unavailable)
                    Text('${_current!.model.displayName}：当前模型目录未返回此模型'),
                  const ShirohaSectionLabel('可使用'),
                  const SizedBox(height: 8),
                  if (selectable.isEmpty)
                    ShirohaSurfaceCard(
                      child: Padding(
                        padding: const EdgeInsets.all(
                          DesignTokens.cardInternalPadding,
                        ),
                        child: Text(_emptyStateMessage),
                      ),
                    )
                  else
                    for (final entry
                        in _groupByProvider(selectable).entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                        child: Text(
                          entry.value.first.provider.displayName,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      ShirohaSettingsCard(
                        children: entry.value
                            .map((model) => _modelTile(model, enabled: true))
                            .toList(growable: false),
                      ),
                    ],
                  if (unusable.isNotEmpty) ...<Widget>[
                    const SizedBox(height: DesignTokens.sectionGap),
                    ShirohaSurfaceCard(
                      child: ExpansionTile(
                        key: const ValueKey<String>(
                          'model-unavailable-toggle',
                        ),
                        title: Text('当前不可使用（${unusable.length}）'),
                        subtitle: const Text('展开查看具体原因'),
                        initiallyExpanded: _showUnusable,
                        onExpansionChanged: (value) =>
                            setState(() => _showUnusable = value),
                        children: unusable
                            .map((model) => _modelTile(model, enabled: false))
                            .toList(growable: false),
                      ),
                    ),
                  ],
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

  Widget _modelTile(AiModelCompatibility item, {required bool enabled}) {
    final colors = Theme.of(context).colorScheme;
    final selected = item.model.modelRef == _selectedModelRef;
    final tags = item.capabilities.entries
        .where((entry) => entry.value == AiCapabilitySupport.supported)
        .map((entry) => _capabilityName(entry.key))
        .toList(growable: false);
    return RadioListTile<String>(
      key: ValueKey<String>('model-${item.model.modelRef}'),
      value: item.model.modelRef,
      enabled: enabled && !_saving,
      selected: selected,
      title: Text(item.model.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(item.model.canonicalModelId),
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
          if (!enabled ||
              item.selectionState == AiModelSelectionState.unannotated)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _stateLabel(item.selectionState),
                style: TextStyle(
                  color:
                      item.selectionState == AiModelSelectionState.unannotated
                          ? colors.onSurfaceVariant
                          : colors.error,
                ),
              ),
            ),
        ],
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

String _stateLabel(AiModelSelectionState state) => switch (state) {
      AiModelSelectionState.selectable => '可使用',
      AiModelSelectionState.unannotated => '能力未标注',
      AiModelSelectionState.unsupported => '不支持当前功能',
      AiModelSelectionState.unavailable => '当前模型目录未返回',
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
  const _CustomModelDialog({required this.service, required this.providers});
  final AiConfigPresentationService service;
  final List<AiProviderOverview> providers;
  @override
  State<_CustomModelDialog> createState() => _CustomModelDialogState();
}

class _CustomModelDialogState extends State<_CustomModelDialog> {
  final _id = TextEditingController();
  final _name = TextEditingController();
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
          displayName: _name.text);
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
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('添加自定义模型'),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            initialValue: _providerId,
            decoration: const InputDecoration(labelText: 'Provider'),
            items: widget.providers
                .map((item) => DropdownMenuItem(
                    value: item.provider.providerId,
                    child: Text(item.provider.displayName)))
                .toList(),
            onChanged: _saving
                ? null
                : (value) => setState(() => _providerId = value!),
          ),
          TextField(
              key: const ValueKey<String>('custom-model-id'),
              controller: _id,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: 'Model ID *')),
          TextField(
              key: const ValueKey<String>('custom-model-name'),
              controller: _name,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: 'Display Name（可选）')),
          if (_error != null) Text(_error!),
        ])),
        actions: [
          TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
              key: const ValueKey<String>('save-custom-model'),
              onPressed: _saving ? null : _save,
              child: const Text('添加')),
        ],
      );
}
