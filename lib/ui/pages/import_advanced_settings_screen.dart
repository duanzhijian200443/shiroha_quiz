import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';

/// Advanced import settings.
///
/// This page is deliberately secondary to the import entry and contains only
/// settings that are real. A row is interactive only when a backend consumer
/// actually reads the value; everything else is presented as a read-only
/// explanation, never as a control that does nothing.
class ImportAdvancedSettingsScreen extends StatelessWidget {
  const ImportAdvancedSettingsScreen({super.key});

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
                const _AdvancedSection(
                  icon: Icons.speed_outlined,
                  title: 'OCR 并行度',
                  description: '当前版本的 OCR 解析由系统自动管理并发。',
                  children: [
                    _AdvancedInfoRow(
                      key: ValueKey<String>('advanced-ocr-concurrency-row'),
                      title: 'OCR 并发：当前由系统自动管理',
                      subtitle: '暂不提供手动并发设置；可调并行度需要先完成 OCR 后端的并发消费。',
                    ),
                  ],
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
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
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      '完成',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
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
