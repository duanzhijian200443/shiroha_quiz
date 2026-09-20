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
                  icon: Icons.rule_folder_outlined,
                  title: '导入后流程',
                  description: '导入任务完成后不会直接入库。',
                  children: [
                    _AdvancedInfoRow(
                      key: ValueKey<String>('import-flow-review-row'),
                      title: '识别完成后进入校对页',
                      subtitle: '确认题目、答案和解析后再收入题库。',
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
                      backgroundColor: theme.colorScheme.primaryContainer,
                      foregroundColor: theme.colorScheme.onPrimaryContainer,
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
      ),
      child: Padding(
        padding: const EdgeInsets.all(DesignTokens.cardInternalPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
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
