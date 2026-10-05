import 'package:flutter/material.dart';
import '../../application/home_training_result.dart';
import '../../application/training/training_contracts.dart';
import '../../domain/training/training_content_member.dart';
import 'training_bank_selector.dart';
import 'training_configuration_controller.dart';
import 'training_content_draft.dart';
import 'training_visuals.dart';

class TrainingContentEditor extends StatefulWidget {
  const TrainingContentEditor(
      {super.key,
      required this.controller,
      required this.draft,
      required this.catalog});
  final TrainingConfigurationController controller;
  final TrainingContentDraft draft;
  final TrainingCatalogSnapshot catalog;
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
                catalog: controller.snapshot?.catalog ?? widget.catalog,
                categoryKey: draft.categoryKey,
                members: draft.members)));
    if (mounted && names != null) setState(() => draft.setBanks(names));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => PopScope(
          canPop: !controller.busy,
          child: Scaffold(
            appBar: AppBar(
                title: Text(draft.original == null ? '新建训练内容' : '编辑训练内容'),
                actions: [
                  TextButton(
                      onPressed:
                          controller.busy || !draft.canSave ? null : _save,
                      child: const Text('完成')),
                ]),
            body: AbsorbPointer(
                absorbing: controller.busy,
                child: TrainingPageBody(children: [
                  if (controller.busy) const LinearProgressIndicator(),
                  if (_message != null)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Semantics(
                            liveRegion: true, child: Text(_message!))),
                  TrainingCard(
                      child: Row(children: [
                    CategoryVisualBadge(
                        visualKey: draft.visualKey,
                        label: trainingCategoryLabel(draft.categoryKey)),
                    const SizedBox(width: 16),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(trainingCategoryLabel(draft.categoryKey),
                              style: Theme.of(context).textTheme.headlineSmall),
                          Text('包含 ${draft.members.length} 个题库'),
                        ])),
                  ])),
                  TrainingCard(
                      child: TextField(
                          controller: _name,
                          decoration: const InputDecoration(labelText: '名称'),
                          onChanged: (value) =>
                              setState(() => draft.name = value))),
                  TrainingCard(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text('分类视觉',
                            style: Theme.of(context).textTheme.titleMedium),
                        const Text('修改分类视觉，将应用于该分类全部训练内容。'),
                        const SizedBox(height: 12),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final key in CategoryVisualKey.values)
                            ChoiceChip(
                                label: Text(trainingVisualLabel(key)),
                                avatar: Icon(trainingVisualIcon(key), size: 18),
                                selected: (draft.visualKey ??
                                        CategoryVisualKey.genericLearning) ==
                                    key,
                                onSelected: (_) =>
                                    setState(() => draft.visualKey = key)),
                        ]),
                      ])),
                  TrainingCard(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        const Text('每次出题量'),
                        Row(children: [
                          Expanded(
                              child: Text('${draft.questionLimit} 题',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium)),
                          IconButton(
                              tooltip: '减少题量',
                              onPressed: draft.questionLimit <= 1
                                  ? null
                                  : () => setState(() => draft.questionLimit--),
                              icon: const Icon(Icons.remove)),
                          IconButton(
                              tooltip: '增加题量',
                              onPressed: draft.questionLimit >= 100
                                  ? null
                                  : () => setState(() => draft.questionLimit++),
                              icon: const Icon(Icons.add)),
                        ]),
                        Slider(
                            key: const ValueKey('question-limit'),
                            value: draft.questionLimit.toDouble(),
                            min: 1,
                            max: 100,
                            divisions: 99,
                            label: '${draft.questionLimit} 题',
                            semanticFormatterCallback: (v) => '${v.round()} 题',
                            onChanged: (v) => setState(
                                () => draft.questionLimit = v.round())),
                        const Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [Text('1'), Text('100')]),
                      ])),
                  TrainingCard(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text('出题比例',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 16),
                        Center(
                            child: TrainingRatioOverview(
                                members: draft.members,
                                limit: draft.questionLimit)),
                        const SizedBox(height: 16),
                        for (final member in draft.members) ...[
                          Text('${member.bankName} · ${member.weightPercent}%'),
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
                                  : (v) => setState(() => draft.adjustWeight(
                                      member.bankName, v.round()))),
                          Text('预计理想题数：${draft.quotas[member.bankName]} 题'),
                          const SizedBox(height: 12),
                        ],
                        const Text('0% 不参与新题抽取；分类复习仍保留。'),
                        const Text('预计题数为理想配额，实际新题数取决于可用题目。'),
                      ])),
                  TrainingCard(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Wrap(
                            spacing: 16,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text('关联题库',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              TextButton.icon(
                                  onPressed: _selectBanks,
                                  icon: const Icon(Icons.edit_outlined),
                                  label: const Text('编辑题库')),
                            ]),
                        for (var i = 0; i < draft.members.length; i++)
                          _member(draft.members[i], i),
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
      );

  Widget _member(TrainingContentMember member, int index) {
    final catalog = controller.snapshot?.catalog ?? widget.catalog;
    final eligible = catalog.banks.any((b) =>
        b.bankName == member.bankName &&
        b.categoryKey == draft.categoryKey &&
        b.ordinaryTrainingEligible);
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(member.bankName),
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
              IconButton(
                  tooltip: '移除题库 ${member.bankName}',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() => draft.setBanks(draft.members
                      .where((m) => m.bankName != member.bankName)
                      .map((m) => m.bankName)
                      .toList()))),
            ]),
            const Divider(),
          ],
        ));
  }
}
