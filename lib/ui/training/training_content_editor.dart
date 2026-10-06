import 'package:flutter/material.dart';
import '../../application/home_training_result.dart';
import '../../application/training/training_contracts.dart';
import '../../domain/training/training_content_member.dart';
import 'training_bank_selector.dart';
import 'training_configuration_controller.dart';
import 'training_content_draft.dart';
import 'training_visuals.dart';
import 'training_ui_theme.dart';
import 'training_hero.dart';

class TrainingContentEditor extends StatefulWidget {
  const TrainingContentEditor(
      {super.key,
      required this.controller,
      required this.draft,
      required this.catalog,
      this.onOpenBank});
  final TrainingConfigurationController controller;
  final TrainingContentDraft draft;
  final TrainingCatalogSnapshot catalog;
  final TrainingBankNavigation? onOpenBank;
  @override
  State<TrainingContentEditor> createState() => _TrainingContentEditorState();
}

class _TrainingContentEditorState extends State<TrainingContentEditor> {
  TrainingContentDraft get draft => widget.draft;
  TrainingConfigurationController get controller => widget.controller;
  late final TextEditingController _name =
      TextEditingController(text: draft.name);
  String? _message;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final result = await controller.save(draft);
    if (!mounted) return;
    if (result.content != null ||
        result.failure == HomeTrainingFailure.stale ||
        result.failure == HomeTrainingFailure.notFound) {
      Navigator.pop(context);
    } else {
      setState(() => _message = controller.message);
    }
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(title),
                content: Text(text),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(action)),
                ],
              )) ??
      false;

  Future<void> _delete() async {
    if (!await _confirm(
        '删除训练内容？', '仅删除训练配置，不删除题库与学习记录。题目、复习状态、答案记录、复习日志和学习时长均保留。', '确认删除')) {
      return;
    }
    if (!mounted) return;
    final result = await controller.delete(draft.original!);
    if (!mounted) return;
    final shouldClose = switch (result) {
      HomeTrainingSuccess() => true,
      HomeTrainingFailed(:final failure) =>
        failure == HomeTrainingFailure.stale ||
            failure == HomeTrainingFailure.notFound,
    };
    if (shouldClose) {
      Navigator.pop(context);
    } else {
      setState(() => _message = controller.message);
    }
  }

  Future<void> _rebind(TrainingContentMember member) async {
    if (!await _confirm('重新绑定题库？',
        '立即保存“${member.bankName}”的重新绑定。其它编辑仍是草稿；返回或取消不会撤销本次重新绑定。', '确认重新绑定')) {
      return;
    }
    if (!mounted) return;
    final result = await controller.rebind(draft.original!, member.bankName);
    if (!mounted) return;
    switch (result) {
      case HomeTrainingSuccess(:final value):
        setState(() {
          draft.acceptRebind(value, member.bankName);
          _message = controller.message;
        });
      case HomeTrainingFailed(:final failure):
        if (failure == HomeTrainingFailure.stale ||
            failure == HomeTrainingFailure.notFound) {
          Navigator.pop(context);
        } else {
          setState(() => _message = controller.message);
        }
    }
  }

  Future<void> _selectBanks() async {
    final names = await Navigator.push<List<String>>(
        context,
        MaterialPageRoute(
            builder: (_) => TrainingBankSelector(
                onOpenBank: widget.onOpenBank,
                refreshCatalog: () async {
                  await controller.load();
                  return controller.snapshot?.catalog;
                },
                catalog: controller.snapshot?.catalog ?? widget.catalog,
                categoryKey: draft.categoryKey,
                members: draft.members)));
    if (mounted && names != null) setState(() => draft.setBanks(names));
  }

  @override
  Widget build(BuildContext context) => TrainingUiTheme(
        child: Builder(
            builder: (context) => AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) => PopScope(
                    canPop: !controller.busy,
                    child: Scaffold(
                      appBar: AppBar(
                          title: Text(
                              draft.original == null ? '新建训练内容' : '编辑训练内容'),
                          actions: [
                            TextButton(
                                onPressed: controller.busy || !draft.canSave
                                    ? null
                                    : _save,
                                child: const Text('完成'))
                          ]),
                      body: AbsorbPointer(
                          absorbing: controller.busy,
                          child: TrainingPageBody(children: [
                            if (controller.busy)
                              const LinearProgressIndicator(),
                            if (_message != null)
                              Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Semantics(
                                      liveRegion: true,
                                      child: Text(_message!))),
                            TrainingHero(
                                title: draft.name.trim().isEmpty
                                    ? trainingCategoryLabel(draft.categoryKey)
                                    : draft.name,
                                subtitle: '包含 ${draft.members.length} 个题库',
                                categoryLabel:
                                    trainingCategoryLabel(draft.categoryKey),
                                visualKey: draft.visualKey),
                            const TrainingSectionHeading(title: '基本信息'),
                            TrainingCard(
                                child: Row(children: [
                              const Text('名称'),
                              const SizedBox(width: 20),
                              Expanded(
                                  child: TextField(
                                      controller: _name,
                                      decoration: InputDecoration(
                                          hintText: '训练内容名称',
                                          suffixIcon: IconButton(
                                              tooltip: '清空名称',
                                              icon: const Icon(Icons.cancel,
                                                  size: 18),
                                              onPressed: () => setState(() {
                                                    _name.clear();
                                                    draft.name = '';
                                                  }))),
                                      onChanged: (value) =>
                                          setState(() => draft.name = value))),
                            ])),
                            const TrainingSectionHeading(title: '出题设置'),
                            TrainingCard(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text('出题量',
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant)),
                                  Row(children: [
                                    Expanded(
                                        child: Text('${draft.questionLimit} 题',
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineSmall
                                                ?.copyWith(
                                                    fontWeight:
                                                        FontWeight.w700))),
                                    IconButton.filledTonal(
                                        tooltip: '减少题量',
                                        onPressed: draft.questionLimit <= 1
                                            ? null
                                            : () => setState(
                                                () => draft.questionLimit--),
                                        icon: const Icon(Icons.remove)),
                                    const SizedBox(width: 8),
                                    IconButton.filledTonal(
                                        tooltip: '增加题量',
                                        onPressed: draft.questionLimit >= 100
                                            ? null
                                            : () => setState(
                                                () => draft.questionLimit++),
                                        icon: const Icon(Icons.add)),
                                  ]),
                                  Row(children: [
                                    const Text('1'),
                                    Expanded(
                                        child: Slider(
                                            key: const ValueKey(
                                                'question-limit'),
                                            value:
                                                draft.questionLimit.toDouble(),
                                            min: 1,
                                            max: 100,
                                            divisions: 99,
                                            label: '${draft.questionLimit} 题',
                                            semanticFormatterCallback: (v) =>
                                                '${v.round()} 题',
                                            onChanged: (v) => setState(() =>
                                                draft.questionLimit =
                                                    v.round()))),
                                    const Text('100'),
                                  ]),
                                ])),
                            TrainingCard(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  const TrainingSectionHeading(
                                      title: '出题比例',
                                      help:
                                          '调整目标比例，自动归一化为 100%；预计题数由正式配额算法计算。'),
                                  LayoutBuilder(
                                      builder: (context, constraints) {
                                    final chart = TrainingRatioOverview(
                                        members: draft.members,
                                        limit: draft.questionLimit);
                                    final sliders = Column(children: [
                                      for (var i = 0;
                                          i < draft.members.length;
                                          i++)
                                        _weight(context, draft.members[i], i),
                                    ]);
                                    if (constraints.maxWidth < 300 ||
                                        MediaQuery.textScalerOf(context)
                                                .scale(1) >
                                            1.2) {
                                      return Column(children: [
                                        chart,
                                        const SizedBox(height: 12),
                                        sliders
                                      ]);
                                    }
                                    return Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          chart,
                                          const SizedBox(width: 16),
                                          Expanded(child: sliders),
                                        ]);
                                  }),
                                  const SizedBox(height: 8),
                                  Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                          borderRadius:
                                              BorderRadius.circular(14)),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text('预计出题数'),
                                            const SizedBox(height: 8),
                                            Wrap(
                                                spacing: 24,
                                                runSpacing: 12,
                                                children: [
                                                  for (final member
                                                      in draft.members)
                                                    SizedBox(
                                                        width: 136,
                                                        child: Column(
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            children: [
                                                              Text(
                                                                  member
                                                                      .bankName,
                                                                  style: TextStyle(
                                                                      color: Theme.of(
                                                                              context)
                                                                          .colorScheme
                                                                          .onSurfaceVariant)),
                                                              Text(
                                                                  '预计理想题数：${draft.quotas[member.bankName]} 题'),
                                                            ])),
                                                ]),
                                          ])),
                                  const SizedBox(height: 10),
                                  Text(
                                      '0% 不参与新题抽取；分类复习仍保留。\n预计题数为理想配额，实际新题数取决于可用题目。',
                                      style: TextStyle(
                                          fontSize: 12,
                                          height: 1.6,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant)),
                                ])),
                            TrainingSectionHeading(
                                title: '关联题库',
                                help: '仅关联该分类内的真实题库。移除不会删除题库或学习记录。',
                                action: TextButton.icon(
                                    onPressed: _selectBanks,
                                    icon: const Icon(Icons.edit_outlined,
                                        size: 18),
                                    label: const Text('编辑题库'))),
                            for (var i = 0; i < draft.members.length; i++)
                              _member(draft.members[i], i),
                            const TrainingSectionHeading(title: '分类视觉'),
                            TrainingCard(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  const Text('修改分类视觉，将应用于该分类全部训练内容。'),
                                  const SizedBox(height: 12),
                                  Wrap(spacing: 8, runSpacing: 8, children: [
                                    for (final key in CategoryVisualKey.values)
                                      ChoiceChip(
                                          label: Text(trainingVisualLabel(key)),
                                          avatar: Icon(trainingVisualIcon(key),
                                              size: 18),
                                          selected: (draft.visualKey ??
                                                  CategoryVisualKey
                                                      .genericLearning) ==
                                              key,
                                          onSelected: (_) => setState(
                                              () => draft.visualKey = key)),
                                  ]),
                                ])),
                            if (draft.original != null)
                              OutlinedButton.icon(
                                  onPressed: _delete,
                                  style: OutlinedButton.styleFrom(
                                      foregroundColor:
                                          Theme.of(context).colorScheme.error),
                                  icon: const Icon(Icons.delete_outline),
                                  label: const Text('删除训练内容')),
                            TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('取消编辑')),
                          ])),
                    ),
                  ),
                )),
      );

  Widget _weight(
          BuildContext context, TrainingContentMember member, int index) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color.lerp(
                        Theme.of(context).colorScheme.onSurfaceVariant,
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                        (index % 5) * .17))),
            const SizedBox(width: 8),
            Expanded(
                child: Text('${member.bankName} · ${member.weightPercent}%')),
          ]),
          Slider(
              key: ValueKey('weight-${member.bankName}'),
              value: member.weightPercent.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              label: '${member.weightPercent}%',
              semanticFormatterCallback: (v) =>
                  '${member.bankName} ${v.round()}%',
              onChanged: draft.members.length == 1
                  ? null
                  : (v) => setState(
                      () => draft.adjustWeight(member.bankName, v.round()))),
        ]),
      );

  Widget _member(TrainingContentMember member, int index) {
    final catalog = controller.snapshot?.catalog ?? widget.catalog;
    final eligible = catalog.banks.any((b) =>
        b.bankName == member.bankName &&
        b.categoryKey == draft.categoryKey &&
        b.ordinaryTrainingEligible);
    return TrainingCard(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const TrainingBankBadge(),
          const SizedBox(width: 12),
          Expanded(child: Text(member.bankName)),
          IconButton(
            tooltip: '移除题库 ${member.bankName}',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => setState(() => draft.setBanks(draft.members
                .where((m) => m.bankName != member.bankName)
                .map((m) => m.bankName)
                .toList())),
          ),
        ]),
        if (member.bindingStatus == TrainingBindingStatus.invalidated) ...[
          Text('绑定失效 · ${trainingInvalidationLabel(member)}'),
          if (draft.original?.members
                  .any((m) => m.bankName == member.bankName) ==
              true)
            TextButton(
                onPressed: eligible ? () => _rebind(member) : null,
                child: const Text('重新绑定')),
        ],
        Wrap(children: [
          IconButton(
              tooltip: '上移题库 ${member.bankName}',
              icon: const Icon(Icons.arrow_upward),
              onPressed: index == 0
                  ? null
                  : () => setState(() => draft.moveMember(index, -1))),
          IconButton(
              tooltip: '下移题库 ${member.bankName}',
              icon: const Icon(Icons.arrow_downward),
              onPressed: index == draft.members.length - 1
                  ? null
                  : () => setState(() => draft.moveMember(index, 1))),
        ]),
      ],
    ));
  }
}
