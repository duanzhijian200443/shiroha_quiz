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
  bool _showIncompatible = false;
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
    final compatible = _models.where((model) => model.compatible).toList();
    final incompatible = _models.where((model) => !model.compatible).toList();
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
                  const ShirohaSectionLabel('兼容模型'),
                  const SizedBox(height: 8),
                  if (compatible.isEmpty)
                    const ShirohaSurfaceCard(
                      child: Padding(
                        padding: EdgeInsets.all(
                          DesignTokens.cardInternalPadding,
                        ),
                        child: Text('暂无已验证兼容的模型，请先同步 Provider 模型。'),
                      ),
                    )
                  else
                    for (final entry
                        in _groupByProvider(compatible).entries) ...[
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
                  if (incompatible.isNotEmpty) ...<Widget>[
                    const SizedBox(height: DesignTokens.sectionGap),
                    ShirohaSurfaceCard(
                      child: ExpansionTile(
                        key:
                            const ValueKey<String>('model-incompatible-toggle'),
                        title: Text('不兼容模型（${incompatible.length}）'),
                        subtitle: const Text('展开查看具体原因'),
                        initiallyExpanded: _showIncompatible,
                        onExpansionChanged: (value) =>
                            setState(() => _showIncompatible = value),
                        children: incompatible
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
          if (!enabled)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                item.reasonCodes.map(_reasonName).join('；'),
                style: TextStyle(color: colors.error),
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

String _reasonName(String reason) {
  if (reason == 'modelUnavailable') return 'Provider 已不再提供该模型';
  if (reason.startsWith('unknown:')) return '能力尚未验证：${reason.substring(8)}';
  if (reason.startsWith('unsupported:')) {
    return '不支持所需能力：${reason.substring(12)}';
  }
  return '当前能力不兼容';
}

String _bindingError(AiConfigFailure failure) => switch (failure) {
      AiConfigFailure.staleRevision => '配置已在其他位置更新，请重新选择',
      AiConfigFailure.modelUnavailable => '该模型已不可用',
      AiConfigFailure.capabilityUnknown => '模型能力尚未验证',
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
