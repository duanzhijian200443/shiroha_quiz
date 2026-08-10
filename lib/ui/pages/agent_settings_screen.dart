import 'package:flutter/material.dart';

import '../../application/agent/agent_config.dart';
import '../../application/agent/agent_config_service.dart';

class AgentSettingsScreen extends StatefulWidget {
  const AgentSettingsScreen({
    super.key,
    required this.settingsService,
    this.onOpenProfileSettings,
  });

  final AgentSettingsService settingsService;
  final VoidCallback? onOpenProfileSettings;

  @override
  State<AgentSettingsScreen> createState() => _AgentSettingsScreenState();
}

class _AgentSettingsScreenState extends State<AgentSettingsScreen> {
  bool _isLoading = true;
  bool _isSaving = false;
  AgentSettingsSnapshot? _snapshot;
  String? _selectedProfileId;
  bool _webEnabled = false;
  double _temperature = 1.0;
  AgentReasoningEffort _reasoningEffort = AgentReasoningEffort.high;
  String? _loadError;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final snapshot = await widget.settingsService.load();
      if (!mounted) return;
      final config = snapshot.config;
      final selectedId = snapshot.selectedProfile?.profileId;
      setState(() {
        _snapshot = snapshot;
        _selectedProfileId = selectedId;
        _webEnabled = config?.webEnabled ?? false;
        _temperature = config?.temperature ?? 1.0;
        _reasoningEffort = config?.reasoningEffort ?? AgentReasoningEffort.high;
        _isLoading = false;
      });
    } on AgentConfigException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = _settingsError(error.failure);
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = '暂时无法读取 Shiroha Agent 设置';
        _isLoading = false;
      });
    }
  }

  Future<void> _save() async {
    final profileId = _selectedProfileId;
    if (profileId == null) {
      setState(() => _saveError = '请先选择主模型');
      return;
    }
    setState(() {
      _isSaving = true;
      _saveError = null;
    });
    try {
      final config = AgentConfig(
        providerKind: AgentProviderKind.deepSeekResponses,
        mainProfileId: profileId,
        webEnabled: _webEnabled,
        temperature: _temperature,
        reasoningEffort: _reasoningEffort,
      );
      await widget.settingsService.save(config);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Shiroha Agent 设置已保存')),
      );
      await _load();
    } on AgentConfigException catch (error) {
      if (!mounted) return;
      setState(() => _saveError = _settingsError(error.failure));
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveError = '暂时无法保存设置，请稍后重试');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text(
          'Shiroha Agent 设置',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? _SettingsFailure(message: _loadError!, onRetry: _load)
                : _buildContent(context),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final snapshot = _snapshot!;
    final profiles = snapshot.availableProfiles;
    if (profiles.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.smart_toy_outlined, size: 48),
              const SizedBox(height: 16),
              const Text(
                '暂无可用于 Shiroha Agent 的文本模型配置',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '请先在 AI 服务中配置完整的文本模型连接信息。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (widget.onOpenProfileSettings != null) ...[
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  key: const ValueKey<String>('a0-agent-open-ai-profiles'),
                  onPressed: widget.onOpenProfileSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('配置 AI 服务'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        if (snapshot.state == AgentSettingsState.unconfigured)
          const _SettingsNotice(
            key: ValueKey<String>('a0-agent-unconfigured'),
            text: '选择主模型并保存后，Shiroha 才能开始回复。',
          ),
        if (snapshot.state == AgentSettingsState.profileUnavailable)
          const _SettingsNotice(
            key: ValueKey<String>('a0-agent-profile-unavailable'),
            text: '此前选择的主模型已不可用，请重新选择并保存。',
            isError: true,
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  key: const ValueKey<String>('a0-agent-main-profile'),
                  initialValue: _selectedProfileId,
                  decoration: const InputDecoration(
                    labelText: '主模型',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final profile in profiles)
                      DropdownMenuItem<String>(
                        value: profile.profileId,
                        child: Text(
                          '${profile.displayName} · ${profile.modelName}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _isSaving
                      ? null
                      : (value) => setState(() {
                            _selectedProfileId = value;
                            _saveError = null;
                          }),
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  key: const ValueKey<String>('a0-agent-web-toggle'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('联网'),
                  subtitle: const Text('使用主模型原生联网；能力取决于所选主模型'),
                  value: _webEnabled,
                  onChanged: _isSaving
                      ? null
                      : (value) => setState(() => _webEnabled = value),
                ),
                const Divider(),
                Row(
                  children: [
                    const Expanded(child: Text('温度')),
                    Text(
                      _temperature.toStringAsFixed(1),
                      key: const ValueKey<String>('a0-agent-temperature-value'),
                      style: TextStyle(
                        color: colors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Slider(
                  key: const ValueKey<String>('a0-agent-temperature'),
                  min: 0,
                  max: 2,
                  divisions: 20,
                  label: _temperature.toStringAsFixed(1),
                  value: _temperature,
                  onChanged: _isSaving
                      ? null
                      : (value) => setState(() => _temperature = value),
                ),
                const Text('部分模型在启用深度推理时可能忽略温度设置。'),
                const SizedBox(height: 20),
                Text(
                  '推理强度',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                SegmentedButton<AgentReasoningEffort>(
                  key: const ValueKey<String>('a0-agent-reasoning'),
                  segments: const [
                    ButtonSegment(
                      value: AgentReasoningEffort.high,
                      label: Text('较高'),
                    ),
                    ButtonSegment(
                      value: AgentReasoningEffort.max,
                      label: Text('最高'),
                    ),
                  ],
                  selected: <AgentReasoningEffort>{_reasoningEffort},
                  onSelectionChanged: _isSaving
                      ? null
                      : (selection) => setState(
                            () => _reasoningEffort = selection.single,
                          ),
                ),
                const SizedBox(height: 8),
                const Text('更高推理强度可能增加响应时间和 API 消耗。'),
              ],
            ),
          ),
        ),
        if (_saveError case final error?) ...[
          const SizedBox(height: 12),
          _SettingsNotice(text: error, isError: true),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const ValueKey<String>('a0-agent-save'),
          onPressed: _isSaving ? null : _save,
          icon: _isSaving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(_isSaving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}

class _SettingsNotice extends StatelessWidget {
  const _SettingsNotice({
    super.key,
    required this.text,
    this.isError = false,
  });

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isError ? colors.errorContainer : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        style: TextStyle(
          color:
              isError ? colors.onErrorContainer : colors.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _SettingsFailure extends StatelessWidget {
  const _SettingsFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(
              key: const ValueKey<String>('a0-agent-settings-retry'),
              onPressed: onRetry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

String _settingsError(AgentConfigFailure failure) {
  return switch (failure) {
    AgentConfigFailure.invalidInput => '设置无效，请检查后重试',
    AgentConfigFailure.unconfigured => '请先选择主模型',
    AgentConfigFailure.corruptStoredConfig => 'Agent 设置异常，请重新保存',
    AgentConfigFailure.profileNotFound => '所选模型配置已不可用',
    AgentConfigFailure.profileIncomplete => '模型配置不完整，请先修复连接信息',
    AgentConfigFailure.temporarilyUnavailable => '暂时无法保存设置，请稍后重试',
  };
}
