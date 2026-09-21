import 'package:flutter/material.dart';

import '../../application/import/import_advanced_preferences.dart';
import '../../data/repositories/settings_repository.dart';
import '../theme/design_tokens.dart';

/// Advanced import settings.
///
/// This page is deliberately secondary to the import entry and contains only
/// settings that are real. The processing strategy is consumed by the OCR
/// pipeline through `ImportParseRequest.maxConcurrency`; the exception
/// handling toggles persist durable preferences consumed by the import
/// pipeline's failure handling. Read-only blocks explain behavior and never
/// present a control that does nothing.
class ImportAdvancedSettingsScreen extends StatefulWidget {
  const ImportAdvancedSettingsScreen({
    super.key,
    this.preferencesLoader,
    this.preferencesSaver,
  });

  final ImportAdvancedPreferencesLoader? preferencesLoader;
  final ImportAdvancedPreferencesSaver? preferencesSaver;

  @override
  State<ImportAdvancedSettingsScreen> createState() =>
      _ImportAdvancedSettingsScreenState();
}

class _ImportAdvancedSettingsScreenState
    extends State<ImportAdvancedSettingsScreen> {
  /// Local working copy: edits apply here first and are persisted only when
  /// the user confirms with 完成, so 恢复默认 and accidental taps never write
  /// a preference by themselves.
  ImportAdvancedPreferences _preferences = ImportAdvancedPreferences.defaults;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final loader = widget.preferencesLoader;
    final loaded = loader != null
        ? await loader()
        : await SettingsRepository.instance.getImportAdvancedPreferences();
    if (!mounted) return;
    setState(() => _preferences = loaded);
  }

  void _selectStrategy(ImportProcessingStrategy strategy) {
    setState(() {
      _preferences = _preferences.copyWith(processingStrategy: strategy);
    });
  }

  void _resetDefaults() {
    setState(() => _preferences = ImportAdvancedPreferences.defaults);
  }

  Future<void> _done() async {
    final saver = widget.preferencesSaver;
    if (saver != null) {
      await saver(_preferences);
    } else {
      await SettingsRepository.instance
          .setImportAdvancedPreferences(_preferences);
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          '高级设置',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(DesignTokens.pageHorizontalPadding),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: DesignTokens.contentMaxWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AdvancedSection(
                  icon: Icons.speed_outlined,
                  title: '处理策略',
                  description: '选择适合的处理策略，系统将按照此策略进行内容解析。',
                  children: [
                    _StrategyCard(
                      key: const ValueKey<String>(
                        'advanced-strategy-automatic',
                      ),
                      title: '自动（推荐）',
                      description: '根据任务规模自动平衡速度与稳定性',
                      icon: Icons.auto_awesome_outlined,
                      selected: _preferences.processingStrategy ==
                          ImportProcessingStrategy.automatic,
                      onTap: () =>
                          _selectStrategy(ImportProcessingStrategy.automatic),
                    ),
                    const SizedBox(height: 10),
                    _StrategyCard(
                      key: const ValueKey<String>(
                        'advanced-strategy-stability',
                      ),
                      title: '稳定优先',
                      description: '降低 OCR 并发，减少限流与失败',
                      icon: Icons.shield_outlined,
                      selected: _preferences.processingStrategy ==
                          ImportProcessingStrategy.stability,
                      onTap: () =>
                          _selectStrategy(ImportProcessingStrategy.stability),
                    ),
                    const SizedBox(height: 10),
                    _StrategyCard(
                      key: const ValueKey<String>('advanced-strategy-speed'),
                      title: '速度优先',
                      description: '提高安全范围内的 OCR 并发',
                      icon: Icons.rocket_launch_outlined,
                      selected: _preferences.processingStrategy ==
                          ImportProcessingStrategy.speed,
                      onTap: () =>
                          _selectStrategy(ImportProcessingStrategy.speed),
                    ),
                  ],
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                _AdvancedSection(
                  icon: Icons.tune_outlined,
                  title: '异常处理',
                  description: '设置解析过程中的异常处理方式，提升任务成功率。',
                  children: [
                    _AdvancedSwitchRow(
                      key: const ValueKey<String>('advanced-auto-retry-row'),
                      switchKey: const ValueKey<String>(
                        'advanced-auto-retry-switch',
                      ),
                      title: '自动重试',
                      subtitle: '遇到网络、限流或临时服务错误时自动重试',
                      value: _preferences.autoRetryEnabled,
                      onChanged: (value) {
                        setState(() {
                          _preferences =
                              _preferences.copyWith(autoRetryEnabled: value);
                        });
                      },
                    ),
                    _AdvancedSwitchRow(
                      key: const ValueKey<String>(
                        'advanced-retain-unresolved-row',
                      ),
                      switchKey: const ValueKey<String>(
                        'advanced-retain-unresolved-switch',
                      ),
                      title: '保留未识别内容',
                      subtitle: '部分页面或片段识别失败时，仍在校对页显示，便于重试或手动补录',
                      value: _preferences.retainUnresolvedFragments,
                      onChanged: (value) {
                        setState(() {
                          _preferences = _preferences.copyWith(
                            retainUnresolvedFragments: value,
                          );
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                const _AdvancedSection(
                  icon: Icons.route_outlined,
                  title: '流程说明',
                  description: '导入将按照以下流程进行，确保内容准确可靠。',
                  children: [
                    _ImportFlowStrip(
                      key: ValueKey<String>('import-flow-strip'),
                      steps: [
                        '选择文件',
                        '解析内容',
                        '生成候选题目',
                        '待校对',
                        '确认入库',
                      ],
                    ),
                    _AdvancedFootnote(
                      key: ValueKey<String>('import-flow-review-note'),
                      text: '正式入库前需经过人工校对。',
                    ),
                  ],
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                const _AdvancedSection(
                  icon: Icons.article_outlined,
                  title: '文档处理说明',
                  description: '两种解析方式各自适用的文档类型由你在导入页选择。',
                  children: [
                    _AdvancedInfoRow(
                      key: ValueKey<String>('advanced-text-direct-read-row'),
                      title: '文本直读',
                      subtitle: '可直接提取文字的 PDF 或文本类文档，不经过 OCR，直接读取文字并解析。',
                    ),
                    _AdvancedInfoRow(
                      key: ValueKey<String>('advanced-ocr-scan-row'),
                      title: 'OCR 扫描',
                      subtitle: '扫描版 PDF 或图片内容使用 OCR 识别。',
                    ),
                  ],
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                Row(
                  children: [
                    TextButton.icon(
                      key: const ValueKey<String>(
                        'advanced-settings-reset-defaults',
                      ),
                      onPressed: _resetDefaults,
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text('恢复默认'),
                    ),
                    const Spacer(),
                    FilledButton(
                      key: const ValueKey<String>('advanced-settings-done'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 14,
                        ),
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(DesignTokens.cardRadius),
                        ),
                      ),
                      onPressed: _done,
                      child: const Text(
                        '完成',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
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

/// A selectable processing-strategy card.
///
/// Mirrors the parse-mode card on the import entry page: the selected card
/// carries the primary border and a check icon, and the whole card is one
/// tap target.
class _StrategyCard extends StatelessWidget {
  const _StrategyCard({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      label: '$title，$description',
      child: Material(
        color: selected ? colorScheme.primaryContainer : colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? colorScheme.primary : colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: selected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: selected
                                  ? colorScheme.onPrimaryContainer
                                  : colorScheme.onSurface,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: selected
                                  ? colorScheme.onPrimaryContainer
                                  : colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An interactive preference row backed by a persisted setting.
class _AdvancedSwitchRow extends StatelessWidget {
  const _AdvancedSwitchRow({
    super.key,
    required this.switchKey,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final Key switchKey;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Switch(
                  key: switchKey,
                  value: value,
                  onChanged: onChanged,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({
    required this.icon,
    required this.title,
    required this.description,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String description;
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(
                      DesignTokens.compactIconContainerRadius,
                    ),
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A read-only state row.
///
/// It carries no tap handler and no disabled-looking affordance, so it can
/// never be mistaken for a setting the user is able to change.
class _AdvancedInfoRow extends StatelessWidget {
  const _AdvancedInfoRow({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The fixed import pipeline, rendered as a read-only numbered sequence.
///
/// [Wrap] is used instead of a row so the strip reflows on narrow windows and
/// under large text rather than overflowing.
class _ImportFlowStrip extends StatelessWidget {
  const _ImportFlowStrip({super.key, required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (index, step) in steps.indexed)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FlowStep(index: index + 1, label: step),
              if (index < steps.length - 1)
                Icon(
                  Icons.arrow_forward,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
      ],
    );
  }
}

class _FlowStep extends StatelessWidget {
  const _FlowStep({required this.index, required this.label});

  final int index;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: theme.colorScheme.primary),
              ),
              child: Text(
                '$index',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A read-only note under a section's rows.
class _AdvancedFootnote extends StatelessWidget {
  const _AdvancedFootnote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
