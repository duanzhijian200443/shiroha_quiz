import 'package:flutter/material.dart';

import '../../application/import/import_advanced_preferences.dart';
import '../theme/design_tokens.dart';

/// Local edits are persisted only after 完成. Loading and saving lock every
/// control so a delayed read cannot overwrite an edit or persist defaults.
class ImportAdvancedSettingsScreen extends StatefulWidget {
  const ImportAdvancedSettingsScreen({
    super.key,
    required this.preferencesLoader,
    required this.preferencesSaver,
  });

  final ImportAdvancedPreferencesLoader preferencesLoader;
  final ImportAdvancedPreferencesSaver preferencesSaver;

  @override
  State<ImportAdvancedSettingsScreen> createState() =>
      _ImportAdvancedSettingsScreenState();
}

class _ImportAdvancedSettingsScreenState
    extends State<ImportAdvancedSettingsScreen> {
  ImportAdvancedPreferences _preferences = ImportAdvancedPreferences.defaults;
  bool _loaded = false;
  bool _loadFailed = false;
  bool _saving = false;

  bool get _editable => _loaded && !_saving;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      final loaded = await widget.preferencesLoader();
      if (!mounted) return;
      setState(() {
        _preferences = loaded;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  void _edit(ImportAdvancedPreferences next) {
    if (!_editable) return;
    setState(() => _preferences = next);
  }

  Future<void> _done() async {
    if (!_editable) return;
    setState(() => _saving = true);
    try {
      await widget.preferencesSaver(_preferences);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设置保存失败，请重试。')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('高级设置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(DesignTokens.pageHorizontalPadding),
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: DesignTokens.contentMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Section(
                  icon: Icons.settings_outlined,
                  title: 'OCR 并行任务数',
                  children: [
                    const Text('设置 App 全局的 OCR 请求并行数。'),
                    const SizedBox(height: 14),
                    _ConcurrencySelector(
                      value: _preferences.effectiveOcrTaskConcurrency,
                      onChanged: _editable
                          ? (value) => _edit(_preferences.copyWith(
                                ocrTaskConcurrency: value,
                              ))
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                _Section(
                  icon: Icons.tune_outlined,
                  title: '异常处理',
                  children: [
                    _SettingRow(
                      title: '自动重试',
                      subtitle: '网络超时或限流等临时失败时自动重试。',
                      control: Switch(
                        key: const ValueKey('advanced-auto-retry-switch'),
                        value: _preferences.autoRetryEnabled,
                        onChanged: _editable
                            ? (value) => _edit(_preferences.copyWith(
                                  autoRetryEnabled: value,
                                ))
                            : null,
                      ),
                    ),
                    const Divider(),
                    _SettingRow(
                      title: 'OCR 请求超时',
                      subtitle: '设置单次 OCR 请求的最长等待时间。',
                      control: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SegmentedButton<int>(
                          key: const ValueKey('advanced-ocr-timeout-selector'),
                          showSelectedIcon: false,
                          segments: [
                            for (final seconds in ImportAdvancedPreferences
                                .allowedOcrRequestTimeoutSeconds)
                              ButtonSegment<int>(
                                value: seconds,
                                label: Text('$seconds秒'),
                              ),
                          ],
                          selected: {
                            _preferences.effectiveOcrRequestTimeoutSeconds,
                          },
                          onSelectionChanged: _editable
                              ? (selected) => _edit(_preferences.copyWith(
                                    ocrRequestTimeoutSeconds: selected.single,
                                  ))
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                _Section(
                  icon: Icons.build_outlined,
                  title: '校对与修复',
                  children: [
                    _SettingRow(
                      title: 'LaTeX 异常自动尝试修补',
                      subtitle: '发现 LaTeX 问题后自动生成修补建议。',
                      control: Switch(
                        key: const ValueKey('advanced-latex-repair-switch'),
                        value: _preferences.autoRepairLatexEnabled,
                        onChanged: _editable
                            ? (value) => _edit(_preferences.copyWith(
                                  autoRepairLatexEnabled: value,
                                ))
                            : null,
                      ),
                    ),
                    const Divider(),
                    _SettingRow(
                      title: '满分结果自动入库',
                      subtitle: '最终质量评分为 100 分且通过全部安全检查时，跳过人工校对并直接加入目标题库。',
                      control: Switch(
                        key: const ValueKey(
                            'advanced-perfect-auto-commit-switch'),
                        value: _preferences.autoCommitPerfectImports,
                        onChanged: _editable
                            ? (value) => _edit(_preferences.copyWith(
                                  autoCommitPerfectImports: value,
                                ))
                            : null,
                      ),
                    ),
                    const Divider(),
                    _SettingRow(
                      title: '导入完成后',
                      subtitle: '设置解析完成后的默认操作。',
                      control: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SegmentedButton<ImportCompletionBehavior>(
                          key: const ValueKey('advanced-completion-selector'),
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: ImportCompletionBehavior.openReview,
                              label: Text('自动进入校对'),
                            ),
                            ButtonSegment(
                              value: ImportCompletionBehavior.notifyOnly,
                              label: Text('仅通知'),
                            ),
                          ],
                          selected: {_preferences.completionBehavior},
                          onSelectionChanged: _editable
                              ? (selected) => _edit(_preferences.copyWith(
                                    completionBehavior: selected.single,
                                  ))
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
                if (!_loaded) ...[
                  const SizedBox(height: 12),
                  Text(_loadFailed ? '设置加载失败，请返回后重试。' : '正在加载设置…'),
                ],
                const SizedBox(height: DesignTokens.sectionGap),
                Row(
                  children: [
                    TextButton.icon(
                      key: const ValueKey('advanced-settings-reset-defaults'),
                      onPressed: _editable
                          ? () => _edit(ImportAdvancedPreferences.defaults
                              .copyWith(
                                  retainUnresolvedFragments:
                                      _preferences.retainUnresolvedFragments))
                          : null,
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text('恢复默认'),
                    ),
                    const Spacer(),
                    FilledButton(
                      key: const ValueKey('advanced-settings-done'),
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.primary,
                        foregroundColor: colors.onPrimary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 14,
                        ),
                      ),
                      onPressed: _editable ? _done : null,
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(DesignTokens.cardInternalPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Text(title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  )),
            ]),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.subtitle,
    required this.control,
  });

  final String title;
  final String subtitle;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(height: 3),
          Text(subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              )),
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerRight, child: control),
        ],
      ),
    );
  }
}

class _ConcurrencySelector extends StatelessWidget {
  const _ConcurrencySelector({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const min = ImportAdvancedPreferences.minOcrTaskConcurrency;
    const max = ImportAdvancedPreferences.maxOcrTaskConcurrency;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Chip(
            key: const ValueKey('advanced-ocr-concurrency-value'),
            label: Text('$value'),
          ),
        ),
        Row(children: [
          const Text('$min'),
          Expanded(
            child: Slider(
              key: const ValueKey('advanced-ocr-concurrency-slider'),
              value: value.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: max - min,
              onChanged:
                  onChanged == null ? null : (raw) => onChanged!(raw.round()),
            ),
          ),
          const Text('$max'),
        ]),
        Text('当前并行任务数：$value', style: theme.textTheme.bodyMedium),
      ],
    );
  }
}
