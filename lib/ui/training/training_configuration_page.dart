import 'package:flutter/material.dart';
import '../../application/training/training_configuration_contracts.dart';
import '../../application/training/training_contracts.dart';
import '../../domain/training/training_content.dart';
import '../../domain/training/category_key.dart';
import 'training_bank_selector.dart';
import 'training_configuration_controller.dart';
import 'training_content_draft.dart';
import 'training_content_editor.dart';
import 'training_visuals.dart';
import 'training_ui_theme.dart';
import 'training_hero.dart';

/// Injectable production-quality page; Home composition is intentionally owned
/// by I2. The caller owns and disposes the controller.
class TrainingConfigurationPage extends StatefulWidget {
  const TrainingConfigurationPage(
      {super.key, required this.controller, this.onOpenBank});
  final TrainingConfigurationController controller;
  final TrainingBankNavigation? onOpenBank;
  @override
  State<TrainingConfigurationPage> createState() =>
      _TrainingConfigurationPageState();
}

class _TrainingConfigurationPageState extends State<TrainingConfigurationPage> {
  TrainingConfigurationController get controller => widget.controller;
  CategoryKey? _viewedCategory;
  @override
  void initState() {
    super.initState();
    controller.load();
  }

  Future<void> _open(TrainingCategorySnapshot category,
      [TrainingContent? content]) async {
    final snapshot = controller.snapshot;
    if (snapshot == null || controller.busy) return;
    final draft = TrainingContentDraft(
        categoryKey: category.categoryKey,
        preference: category.preference,
        content: content,
        initialSortOrder: category.contents.isEmpty
            ? 0
            : category.contents.last.content.sortOrder + 1);
    if (content == null) {
      final names = await Navigator.push<List<String>>(
          context,
          MaterialPageRoute(
              builder: (_) => TrainingBankSelector(
                  catalog: snapshot.catalog,
                  onOpenBank: widget.onOpenBank,
                  refreshCatalog: _refreshCatalog,
                  categoryKey: category.categoryKey,
                  members: const [])));
      if (!mounted || names == null) return;
      draft.setBanks(names);
    }
    if (!mounted) return;
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => TrainingContentEditor(
                controller: controller,
                onOpenBank: widget.onOpenBank,
                draft: draft,
                catalog: snapshot.catalog)));
  }

  Future<TrainingCatalogSnapshot?> _refreshCatalog() async {
    await controller.load();
    return controller.snapshot?.catalog;
  }

  @override
  Widget build(BuildContext context) => TrainingUiTheme(
      child: Builder(
          builder: (context) => AnimatedBuilder(
                animation: controller,
                builder: (context, _) => Scaffold(
                  appBar: AppBar(title: const Text('训练内容配置'), actions: [
                    IconButton(
                        tooltip: '刷新配置',
                        onPressed: controller.busy ? null : controller.load,
                        icon: const Icon(Icons.refresh)),
                  ]),
                  body: Column(children: [
                    if (controller.message != null)
                      Padding(
                          padding: const EdgeInsets.all(16),
                          child: Semantics(
                              liveRegion: true,
                              child: Text(controller.message!))),
                    Expanded(
                        child: switch (controller.state) {
                      TrainingConfigurationLoad.loading =>
                        const Center(child: CircularProgressIndicator()),
                      TrainingConfigurationLoad.unavailable => Center(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              const Text('暂时无法读取训练配置'),
                              TextButton(
                                  onPressed:
                                      controller.busy ? null : controller.load,
                                  child: const Text('重试读取')),
                            ])),
                      TrainingConfigurationLoad.loaded => controller
                              .snapshot!.categories.isEmpty
                          ? const TrainingPageBody(children: [
                              TrainingCard(
                                  child: Text('暂无分类。导入题库或创建题库分类后，可在这里配置训练内容。'))
                            ])
                          : _TrainingCategoryPager(
                              key: ObjectKey(controller.snapshot),
                              categories: controller.snapshot!.categories,
                              initialCategory: _viewedCategory,
                              busy: controller.busy,
                              onChanged: (category) =>
                                  _viewedCategory = category,
                              pageBuilder: (category, previous, next,
                                      pagination) =>
                                  _categoryPage(context, category, previous,
                                      next, pagination)),
                    }),
                  ]),
                ),
              )));

  Widget _categoryPage(BuildContext context, TrainingCategorySnapshot category,
          Widget previous, Widget next, Widget pagination) =>
      TrainingPageBody(key: PageStorageKey(category.categoryKey), children: [
        TrainingHero(
            visualKey: category.preference.visualKey,
            categoryLabel: trainingCategoryLabel(category.categoryKey),
            title: trainingCategoryLabel(category.categoryKey),
            subtitle: '已配置 ${category.contents.length} 个训练内容',
            expanded: true,
            previous: previous,
            next: next),
        Padding(padding: const EdgeInsets.only(bottom: 12), child: pagination),
        TrainingSectionHeading(
            title: '当前训练内容',
            help: '选择训练内容进行编辑；更多操作可设为当前或调整显示顺序。',
            action: FilledButton.tonalIcon(
                onPressed: controller.busy ? null : () => _open(category),
                icon: const Icon(Icons.add),
                label: const Text('新建训练内容'))),
        if (category.contents.isEmpty)
          const TrainingCard(child: Text('暂无训练内容，选择题库新建一组训练。')),
        for (var i = 0; i < category.contents.length; i++)
          _contentCard(context, category, i),
        const TrainingSectionHeading(
            title: '显示顺序', help: '通过每项左侧的排序按钮，或更多菜单中的上移/下移调整顺序。'),
        const TrainingCard(
            child: Wrap(spacing: 16, runSpacing: 8, children: [
          Text('排序方式'),
          Text('按自定义顺序'),
        ])),
        const SizedBox(height: 24),
      ]);

  Widget _contentCard(
      BuildContext context, TrainingCategorySnapshot category, int index) {
    final view = category.contents[index];
    final content = view.content;
    final current = category.preference.currentContentId == content.contentId;
    final colors = Theme.of(context).colorScheme;
    Widget menu({required bool sorting}) => PopupMenuButton<String>(
          tooltip: sorting ? '调整顺序 ${content.name}' : '更多操作 ${content.name}',
          enabled: !controller.busy,
          icon: Icon(sorting ? Icons.menu : Icons.more_horiz,
              color: colors.onSurfaceVariant),
          onSelected: (value) {
            if (value == 'current') {
              controller.select(category, content.contentId);
            }
            if (value == 'edit') _open(category, content);
            if (value == 'up' || value == 'down') {
              controller.move(
                  category,
                  content.contentId,
                  value == 'up'
                      ? TrainingContentMove.up
                      : TrainingContentMove.down);
            }
          },
          itemBuilder: (_) => [
            if (!sorting) ...[
              const PopupMenuItem(value: 'edit', child: Text('编辑训练内容')),
              PopupMenuItem(
                  value: 'current',
                  enabled: !current,
                  child: Text(current ? '已是当前配置' : '设为当前')),
            ],
            PopupMenuItem(
                value: 'up', enabled: index > 0, child: const Text('上移')),
            PopupMenuItem(
                value: 'down',
                enabled: index < category.contents.length - 1,
                child: const Text('下移')),
          ],
        );
    return TrainingCard(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
        child: Row(children: [
          menu(sorting: true),
          Expanded(
              child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap:
                      controller.busy ? null : () => _open(category, content),
                  child: Row(children: [
                    CategoryVisualBadge(
                        visualKey: category.preference.visualKey,
                        label: trainingCategoryLabel(category.categoryKey)),
                    const SizedBox(width: 14),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(content.name,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 5),
                          Text('${content.members.length} 个题库',
                              style: TextStyle(color: colors.onSurfaceVariant)),
                          if (current || !view.usable)
                            Text(
                                '${current ? '当前配置 · ' : ''}${view.usable ? '可用' : '配置需修复'}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: view.usable
                                        ? colors.onSurfaceVariant
                                        : colors.error)),
                        ])),
                  ]))),
          menu(sorting: false),
        ]));
  }
}

/// Browsing configuration categories is local UI state, never current selection.
class _TrainingCategoryPager extends StatefulWidget {
  const _TrainingCategoryPager(
      {super.key,
      required this.categories,
      required this.initialCategory,
      required this.busy,
      required this.onChanged,
      required this.pageBuilder});
  final List<TrainingCategorySnapshot> categories;
  final CategoryKey? initialCategory;
  final bool busy;
  final ValueChanged<CategoryKey> onChanged;
  final Widget Function(TrainingCategorySnapshot, Widget, Widget, Widget)
      pageBuilder;

  @override
  State<_TrainingCategoryPager> createState() => _TrainingCategoryPagerState();
}

class _TrainingCategoryPagerState extends State<_TrainingCategoryPager> {
  late int _index;
  late final PageController _pages;

  @override
  void initState() {
    super.initState();
    final retained = widget.categories.indexWhere(
        (category) => category.categoryKey == widget.initialCategory);
    _index = retained < 0 ? 0 : retained;
    _pages = PageController(initialPage: _index, keepPage: false);
    widget.onChanged(widget.categories[_index].categoryKey);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final target = _index + delta;
    if (widget.busy || target < 0 || target >= widget.categories.length) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(target);
    } else {
      _pages.animateToPage(target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic);
    }
  }

  Widget _arrow({required bool previous}) {
    final disabled = widget.busy ||
        (previous ? _index == 0 : _index == widget.categories.length - 1);
    final colors = Theme.of(context).colorScheme;
    return IconButton(
        key: ValueKey(
            previous ? 'previous-training-category' : 'next-training-category'),
        tooltip: previous ? '上一页' : '下一页',
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: EdgeInsets.zero,
        onPressed: disabled ? null : () => _move(previous ? -1 : 1),
        icon: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surface.withValues(alpha: .85)),
            child: Icon(previous ? Icons.chevron_left : Icons.chevron_right,
                size: 18,
                color: disabled
                    ? colors.onSurface.withValues(alpha: .3)
                    : colors.onSurface)));
  }

  Widget _pagination() => Row(
          key: const ValueKey('training-category-pagination'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < widget.categories.length; i++)
              Semantics(
                  label: '第${i + 1}页，共${widget.categories.length}页',
                  selected: i == _index,
                  child: Container(
                      key: ValueKey('training-category-dot-$i'),
                      width: i == _index ? 9 : 7,
                      height: i == _index ? 9 : 7,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == _index
                              ? Theme.of(context).colorScheme.onSurface
                              : Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: .2))))
          ]);

  @override
  Widget build(BuildContext context) => Column(children: [
        Expanded(
            child: PageView.builder(
                key: const ValueKey('training-category-pages'),
                controller: _pages,
                physics: widget.busy
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: widget.categories.length,
                onPageChanged: (index) {
                  setState(() => _index = index);
                  widget.onChanged(widget.categories[index].categoryKey);
                },
                itemBuilder: (_, index) => widget.pageBuilder(
                    widget.categories[index],
                    _arrow(previous: true),
                    _arrow(previous: false),
                    _pagination()))),
      ]);
}
