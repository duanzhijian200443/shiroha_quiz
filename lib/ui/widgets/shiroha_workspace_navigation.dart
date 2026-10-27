import 'package:flutter/material.dart';

import '../../application/u1_workspace/u1_workspace_dtos.dart';
import '../theme/design_tokens.dart';
import 'shiroha_icons.dart';

enum WorkspaceDestination {
  home,
  library,
  spaces,
  training,
  banks,
  assistant,
  settings
}

/// Desktop navigation reuses existing destinations and their lifecycle owners.
class ShirohaWorkspaceNavigation extends StatelessWidget {
  const ShirohaWorkspaceNavigation({
    super.key,
    required this.expanded,
    required this.selectedIndex,
    required this.onSelected,
    this.horizontal = false,
    this.recentFiles,
    this.onOpenFile,
  });

  final bool expanded, horizontal;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<LibraryFileSummary>? recentFiles;
  final ValueChanged<String>? onOpenFile;

  static const labels = ['首页', '资料库', '学习空间', '今日训练', '题库', '助手', '设置'];
  static const icons = [
    Icons.home_rounded,
    Icons.description_outlined,
    Icons.menu_book_outlined,
    Icons.track_changes_outlined,
    Icons.grid_view_outlined,
    Icons.auto_awesome_outlined,
    Icons.settings_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (horizontal) {
      return Material(
          color: colors.surface,
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (var index = 0; index < labels.length; index++)
                  SizedBox(width: 88, child: _destination(context, index)),
              ]),
            ),
          ));
    }
    return SizedBox(
      key: const ValueKey('workspace-navigation'),
      width: expanded
          ? DesignTokens.expandedNavigationWidth
          : DesignTokens.compactNavigationWidth,
      child: Material(
        color: Color.lerp(colors.surface, colors.primaryContainer, .12),
        child: SafeArea(
          child: DecoratedBox(
            decoration: BoxDecoration(
                border: Border(
                    right: BorderSide(
                        color: colors.outlineVariant.withValues(alpha: .65)))),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding:
                        EdgeInsets.fromLTRB(expanded ? 24 : 20, 26, 20, 26),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.auto_stories_outlined,
                              color: colors.primary, size: 26),
                          if (expanded) ...[
                            const SizedBox(width: 14),
                            const Expanded(
                                child: Text('shiroha_quiz',
                                    style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700))),
                          ],
                        ]),
                  ),
                  Expanded(
                      child: SingleChildScrollView(
                    padding:
                        EdgeInsets.symmetric(horizontal: expanded ? 16 : 12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (expanded) ...[
                            Text('工作区',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurfaceVariant)),
                            const SizedBox(height: 8),
                            Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 12),
                                decoration: BoxDecoration(
                                    border: Border.all(
                                        color: colors.outlineVariant),
                                    borderRadius: BorderRadius.circular(9)),
                                child: const Row(children: [
                                  Icon(Icons.folder_open_outlined, size: 18),
                                  SizedBox(width: 10),
                                  Expanded(
                                      child: Text('本地工作区',
                                          style: TextStyle(fontSize: 13)))
                                ])),
                            const SizedBox(height: 22),
                          ],
                          for (var index = 0; index < labels.length; index++)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: _destination(context, index)),
                          if (expanded) ...[
                            const SizedBox(height: 52),
                            Divider(color: colors.outlineVariant),
                            const SizedBox(height: 12),
                            Text('最近资料',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurfaceVariant)),
                            const SizedBox(height: 8),
                            if (recentFiles == null)
                              Text('暂不可用',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: colors.onSurfaceVariant))
                            else if (recentFiles!.isEmpty)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  child: Text('暂无资料',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: colors.onSurfaceVariant)))
                            else
                              for (final file in recentFiles!.take(4))
                                ListTile(
                                    dense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    minLeadingWidth: 16,
                                    leading: const Icon(
                                        Icons.description_outlined,
                                        size: 17),
                                    title: Text(file.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12)),
                                    onTap: onOpenFile == null
                                        ? null
                                        : () => onOpenFile!(file.fileId)),
                            Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                    onPressed: () => onSelected(1),
                                    child: const Text('查看全部  →'))),
                          ],
                        ]),
                  )),
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: InkWell(
                        onTap: () => onSelected(6),
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(children: [
                              CircleAvatar(
                                  radius: 18,
                                  backgroundColor: colors.primaryContainer,
                                  child: Text('S',
                                      style: TextStyle(color: colors.primary))),
                              if (expanded) ...[
                                const SizedBox(width: 14),
                                const Expanded(
                                    child: Text('Shiroha',
                                        style: TextStyle(fontSize: 13))),
                                const Icon(Icons.chevron_right, size: 18)
                              ],
                            ])),
                      )),
                ]),
          ),
        ),
      ),
    );
  }

  Widget _destination(BuildContext context, int index) {
    final colors = Theme.of(context).colorScheme;
    final selected = selectedIndex == index;
    final foreground = selected ? colors.primary : colors.onSurfaceVariant;
    final icon = index == 5
        ? ShirohaIcon(ShirohaGlyph.assistant, color: foreground)
        : Icon(icons[index], color: foreground, size: 22);
    // Keep the tooltip's OverlayPortal anchor outside the excluded descendants.
    // Otherwise its floating semantics node has no reachable traversal parent.
    return Tooltip(
      message: labels[index],
      child: Semantics(
          selected: selected,
          button: true,
          label: labels[index],
          onTap: () => onSelected(index),
          excludeSemantics: true,
          child: Material(
            color: selected ? colors.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              key: ValueKey('workspace-nav-$index'),
              borderRadius: BorderRadius.circular(9),
              onTap: () => onSelected(index),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: horizontal
                      ? Column(mainAxisSize: MainAxisSize.min, children: [
                          icon,
                          const SizedBox(height: 4),
                          Text(labels[index],
                              style: TextStyle(fontSize: 11, color: foreground))
                        ])
                      : Row(
                          mainAxisAlignment: expanded
                              ? MainAxisAlignment.start
                              : MainAxisAlignment.center,
                          children: [
                              icon,
                              if (expanded) ...[
                                const SizedBox(width: 16),
                                Expanded(
                                    child: Text(labels[index],
                                        style: TextStyle(
                                            fontSize: 14,
                                            color: foreground,
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500)))
                              ],
                            ]),
                ),
              ),
            ),
          )),
    );
  }
}
