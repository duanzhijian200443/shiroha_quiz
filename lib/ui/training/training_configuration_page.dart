import 'package:flutter/material.dart';
import '../../application/training/training_configuration_contracts.dart';
import '../../application/training/training_contracts.dart';
import '../../domain/training/training_content.dart';
import 'training_bank_selector.dart';
import 'training_configuration_controller.dart';
import 'training_content_draft.dart';
import 'training_content_editor.dart';
import 'training_visuals.dart';

/// Injectable production-quality page; Home composition is intentionally owned
/// by I2. The caller owns and disposes the controller.
class TrainingConfigurationPage extends StatefulWidget {
  const TrainingConfigurationPage({super.key, required this.controller});
  final TrainingConfigurationController controller;
  @override
  State<TrainingConfigurationPage> createState() =>
      _TrainingConfigurationPageState();
}

class _TrainingConfigurationPageState extends State<TrainingConfigurationPage> {
  TrainingConfigurationController get controller => widget.controller;
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
                draft: draft,
                catalog: snapshot.catalog)));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
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
                      liveRegion: true, child: Text(controller.message!))),
            Expanded(
                child: switch (controller.state) {
              TrainingConfigurationLoad.loading =>
                const Center(child: CircularProgressIndicator()),
              TrainingConfigurationLoad.unavailable => Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('暂时无法读取训练配置'),
                  TextButton(
                      onPressed: controller.busy ? null : controller.load,
                      child: const Text('重试读取')),
                ])),
              TrainingConfigurationLoad.loaded => TrainingPageBody(children: [
                  if (controller.snapshot!.categories.isEmpty)
                    const TrainingCard(
                        child: Text('暂无分类。导入题库或创建题库分类后，可在这里配置训练内容。')),
                  for (final category in controller.snapshot!.categories) ...[
                    TrainingCard(
                        child: Row(children: [
                      CategoryVisualBadge(
                          visualKey: category.preference.visualKey,
                          label: trainingCategoryLabel(category.categoryKey)),
                      const SizedBox(width: 16),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(trainingCategoryLabel(category.categoryKey),
                                style:
                                    Theme.of(context).textTheme.headlineSmall),
                            Text('已配置 ${category.contents.length} 个训练内容'),
                          ])),
                    ])),
                    for (var i = 0; i < category.contents.length; i++)
                      _contentCard(category, i),
                    Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                            onPressed:
                                controller.busy ? null : () => _open(category),
                            icon: const Icon(Icons.add),
                            label: const Text('添加训练内容'))),
                    const SizedBox(height: 24),
                  ],
                ]),
            }),
          ]),
        ),
      );

  Widget _contentCard(TrainingCategorySnapshot category, int index) {
    final view = category.contents[index];
    final content = view.content;
    final current = category.preference.currentContentId == content.contentId;
    return TrainingCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CategoryVisualBadge(
              visualKey: category.preference.visualKey,
              label: trainingCategoryLabel(category.categoryKey)),
          title: Text(content.name),
          subtitle: Text(
              '${content.questionLimit} 题 · ${content.members.length} 个题库\n${current ? '当前配置 · ' : ''}${view.usable ? '可用' : '配置需修复'}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: controller.busy ? null : () => _open(category, content)),
      Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
                onPressed: controller.busy || current
                    ? null
                    : () => controller.select(category, content.contentId),
                child: const Text('设为当前')),
            IconButton(
                tooltip: '上移 ${content.name}',
                icon: const Icon(Icons.arrow_upward),
                onPressed: controller.busy || index == 0
                    ? null
                    : () => controller.move(
                        category, content.contentId, TrainingContentMove.up)),
            IconButton(
                tooltip: '下移 ${content.name}',
                icon: const Icon(Icons.arrow_downward),
                onPressed: controller.busy ||
                        index == category.contents.length - 1
                    ? null
                    : () => controller.move(
                        category, content.contentId, TrainingContentMove.down)),
          ]),
    ]));
  }
}
