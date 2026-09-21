import 'package:flutter/material.dart';

import '../../application/import/import_advanced_preferences.dart';
import '../../data/repositories/settings_repository.dart';
import '../theme/design_tokens.dart';

/// Advanced import settings.
///
/// This page is deliberately secondary to the import entry and contains only
/// settings that are real. The OCR task concurrency slider is consumed by the
/// import pipeline's OCR tasks through `ImportAdvancedPreferences`; the
/// exception handling rows are not implemented yet, so they are presented as
/// planned instead of as working switches. Read-only blocks explain behavior
/// and never present a control that does nothing.
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

  void _setOcrTaskConcurrency(int value) {
    setState(() {
      _preferences = _preferences.copyWith(
        ocrTaskConcurrency:
            ImportAdvancedPreferences.clampOcrTaskConcurrency(value),
      );
    });
  }

  void _resetDefaults() {
    setState(() {
      // Only the editable preference is reset. The reserved exception-handling
      // toggles are not user-editable yet, so their stored value is kept.
      _preferences = _preferences.copyWith(
        ocrTaskConcurrency: ImportAdvancedPreferences.defaultOcrTaskConcurrency,
      );
    });
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
                  icon: Icons.settings_outlined,
                  title: 'OCR 并行任务数',
                  description: '同时处理的 OCR 任务越多，批量导入可能越快，但更容易触发服务限流或增加资源占用。'
                      '单个 PDF 内仍按串行方式处理。',
                  children: [
                    _ConcurrencySelector(
                      key: const ValueKey<String>(
                        'advanced-ocr-concurrency-card',
                      ),
                      value: _preferences.effectiveOcrTaskConcurrency,
                      onChanged: _setOcrTaskConcurrency,
                    ),
                  ],
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                _AdvancedSection(
                  icon: Icons.tune_outlined,
                  title: '异常处理',
                  description: '设置解析过程中的异常处理方式，提升任务成功率。',
                  children: [
                    const _PlannedSwitchRow(
                      key: ValueKey<String>('advanced-auto-retry-row'),
                      switchKey: ValueKey<String>('advanced-auto-retry-switch'),
                      title: '自动重试',
                      subtitle: '遇到网络、限流或临时失败时自动重试',
                    ),
                    const _PlannedSwitchRow(
                      key: ValueKey<String>(
                        'advanced-retain-unresolved-row',
                      ),
                      switchKey: ValueKey<String>(
                        'advanced-retain-unresolved-switch',
                      ),
                      title: '保留未识别内容',
                      subtitle: '部分内容识别失败时仍带入校对页，便于后续检查与补录',
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

/// The OCR task concurrency budget control.
///
/// The slider spans the supported 1..12 range in single steps, so every value
/// it can produce is already a valid runtime budget. The badge above the thumb
/// shows the same number as the value line below the track.
class _ConcurrencySelector extends StatelessWidget {
  const _ConcurrencySelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// Horizontal inset applied to the slider so the thumb, the badge and the
  /// range labels never clip at the card edge.
  static const double _inset = 12;

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const min = ImportAdvancedPreferences.minOcrTaskConcurrency;
    const max = ImportAdvancedPreferences.maxOcrTaskConcurrency;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const _RangeLabel('$min', height: _sliderHeight),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // The slider is inset horizontally, so its thumb travels
                      // the full inner width: the badge can be placed from the
                      // same fraction without guessing framework padding.
                      final fraction = (value - min) / (max - min);
                      final badgeLeft = _inset +
                          (constraints.maxWidth - _inset * 2) * fraction -
                          _badgeWidth / 2;
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Padding(
                            padding:
                                const EdgeInsets.only(top: _badgeAreaHeight),
                            child: SizedBox(
                              height: _sliderHeight,
                              child: Slider(
                                key: const ValueKey<String>(
                                  'advanced-ocr-concurrency-slider',
                                ),
                                value: value.toDouble(),
                                min: min.toDouble(),
                                max: max.toDouble(),
                                divisions: max - min,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: _inset,
                                ),
                                semanticFormatterCallback: (raw) =>
                                    'OCR 并行任务数 ${raw.round()}',
                                onChanged: (raw) => onChanged(raw.round()),
                              ),
                            ),
                          ),
                          Positioned(
                            left: badgeLeft,
                            top: 0,
                            child: _ConcurrencyBadge(value: value),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const _RangeLabel('$max', height: _sliderHeight),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Text(
                  '当前并行任务数：',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  '$value',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const double _badgeWidth = 40;
  static const double _badgeAreaHeight = 26;
  static const double _sliderHeight = 32;
}

class _ConcurrencyBadge extends StatelessWidget {
  const _ConcurrencyBadge({required this.value});

  final int value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('advanced-ocr-concurrency-value'),
      width: _ConcurrencySelector._badgeWidth,
      padding: const EdgeInsets.symmetric(vertical: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: colorScheme.primary, width: 1.5),
      ),
      child: Text(
        '$value',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}

class _RangeLabel extends StatelessWidget {
  const _RangeLabel(this.label, {required this.height});

  final String label;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 26,
      height: height,
      child: Center(
        child: Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// An exception-handling row for a capability that does not exist yet.
///
/// It carries the 规划中 marker and renders inert: it explains what the setting
/// will do without pretending the capability is already available.
class _PlannedSwitchRow extends StatelessWidget {
  const _PlannedSwitchRow({
    super.key,
    required this.switchKey,
    required this.title,
    required this.subtitle,
  });

  final Key switchKey;
  final String title;
  final String subtitle;

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
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const _PlannedChip(),
                      ],
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
              Text(
                '即将推出',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: '该能力尚未开放，当前不会影响解析过程。',
                child: Icon(
                  Icons.info_outline,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                key: switchKey,
                value: false,
                onChanged: null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlannedChip extends StatelessWidget {
  const _PlannedChip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '规划中',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
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
