import 'package:flutter/material.dart';
import '../../application/training/training_contracts.dart';
import '../../domain/training/category_key.dart';
import '../../domain/training/training_content_member.dart';
import 'training_visuals.dart';

class TrainingBankSelector extends StatefulWidget {
  const TrainingBankSelector(
      {super.key,
      required this.catalog,
      required this.categoryKey,
      required this.members});
  final TrainingCatalogSnapshot catalog;
  final CategoryKey categoryKey;
  final List<TrainingContentMember> members;
  @override
  State<TrainingBankSelector> createState() => _TrainingBankSelectorState();
}

class _TrainingBankSelectorState extends State<TrainingBankSelector> {
  late final List<String> _selected =
      widget.members.map((m) => m.bankName).toList();
  String _search = '';
  @override
  Widget build(BuildContext context) {
    final banks = widget.catalog.banks
        .where((b) =>
            b.categoryKey == widget.categoryKey && b.ordinaryTrainingEligible)
        .toList();
    final eligibleNames = banks.map((b) => b.bankName).toSet();
    final retained =
        widget.members.where((m) => !eligibleNames.contains(m.bankName));
    final original = {for (final m in widget.members) m.bankName: m};
    return Scaffold(
      appBar: AppBar(title: const Text('选择题库')),
      body: TrainingPageBody(children: [
        Text(trainingCategoryLabel(widget.categoryKey),
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search), hintText: '搜索题库'),
            onChanged: (v) => setState(() => _search = v)),
        const SizedBox(height: 16),
        if (banks.isEmpty) const TrainingCard(child: Text('该分类暂无可选题库。')),
        for (final bank in banks.where((b) => b.bankName.contains(_search)))
          TrainingCard(
              child: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(bank.bankName),
            subtitle: original[bank.bankName]?.bindingStatus ==
                    TrainingBindingStatus.invalidated
                ? const Text('原绑定已失效；重新勾选不会恢复绑定')
                : null,
            value: _selected.contains(bank.bankName),
            onChanged: (checked) => setState(() {
              if (checked == true) {
                _selected.add(bank.bankName);
              } else {
                _selected.remove(bank.bankName);
              }
            }),
          )),
        for (final member in retained)
          TrainingCard(
              child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(member.bankName),
            subtitle: Text('原关联题库 · ${trainingInvalidationLabel(member)}'),
            trailing: _selected.contains(member.bankName)
                ? IconButton(
                    tooltip: '移除 ${member.bankName}',
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () =>
                        setState(() => _selected.remove(member.bankName)))
                : const Text('已移除'),
          )),
      ]),
      bottomNavigationBar: SafeArea(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Expanded(child: Text('已选择 ${_selected.length} 个题库')),
          FilledButton(
              onPressed: _selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, List<String>.of(_selected)),
              child: const Text('下一步')),
        ]),
      )),
    );
  }
}
