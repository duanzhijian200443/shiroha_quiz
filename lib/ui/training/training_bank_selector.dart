import 'package:flutter/material.dart';
import '../../application/training/training_contracts.dart';
import '../../domain/training/category_key.dart';
import '../../domain/training/training_content_member.dart';
import 'training_ui_theme.dart';
import 'training_visuals.dart';

typedef TrainingBankNavigation = Future<void> Function(String bankName);
typedef TrainingCatalogRefresh = Future<TrainingCatalogSnapshot?> Function();

class TrainingBankSelector extends StatefulWidget {
  const TrainingBankSelector(
      {super.key,
      required this.catalog,
      required this.categoryKey,
      required this.members,
      this.onOpenBank,
      this.refreshCatalog});
  final TrainingCatalogSnapshot catalog;
  final CategoryKey categoryKey;
  final List<TrainingContentMember> members;
  final TrainingBankNavigation? onOpenBank;
  final TrainingCatalogRefresh? refreshCatalog;
  @override
  State<TrainingBankSelector> createState() => _TrainingBankSelectorState();
}

class _TrainingBankSelectorState extends State<TrainingBankSelector> {
  late final List<String> _selected =
      widget.members.map((m) => m.bankName).toList();
  late TrainingCatalogSnapshot? _catalog = widget.catalog;
  final _scroll = ScrollController();
  final _searchController = TextEditingController();
  String _search = '';
  String? _message;
  bool _opening = false;

  @override
  void dispose() {
    _scroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool _eligible(String name) =>
      _catalog?.banks.any((b) =>
          b.bankName == name &&
          b.categoryKey == widget.categoryKey &&
          b.ordinaryTrainingEligible) ??
      false;

  Future<void> _openBank(String name) async {
    if (_opening || widget.onOpenBank == null) return;
    setState(() => _opening = true);
    try {
      if (widget.refreshCatalog != null) {
        final fresh = await widget.refreshCatalog!();
        if (!mounted) return;
        setState(() => _catalog = fresh);
      }
      if (!_eligible(name)) {
        setState(() => _message = '题库已变化或暂不可用，请检查后再选择。');
        return;
      }
      await widget.onOpenBank!(name);
      if (!mounted) return;
      if (widget.refreshCatalog != null) {
        final fresh = await widget.refreshCatalog!();
        if (!mounted) return;
        setState(() => _catalog = fresh);
      }
    } catch (_) {
      if (mounted) setState(() => _message = '暂时无法查看题库，请重试。');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _toggle(String name) => setState(() {
        if (_selected.contains(name)) {
          _selected.remove(name);
        } else {
          _selected.add(name);
        }
      });

  @override
  Widget build(BuildContext context) =>
      TrainingUiTheme(child: Builder(builder: _build));

  Widget _build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final banks = _catalog?.banks
            .where((b) =>
                b.categoryKey == widget.categoryKey &&
                b.ordinaryTrainingEligible)
            .toList() ??
        <TrainingCatalogBank>[];
    final eligibleNames = banks.map((b) => b.bankName).toSet();
    final retainedNames = {
      ..._selected,
      ...widget.members.map((m) => m.bankName)
    }.where((name) => !eligibleNames.contains(name));
    final original = {for (final m in widget.members) m.bankName: m};
    final filtered = banks.where((b) => b.bankName.contains(_search)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('选择题库')),
      body: TrainingPageBody(controller: _scroll, children: [
        TextField(
            controller: _searchController,
            decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: '搜索题库',
                helperText: trainingCategoryLabel(widget.categoryKey)),
            onChanged: (v) => setState(() => _search = v)),
        const SizedBox(height: 16),
        if (_opening) const LinearProgressIndicator(),
        if (_message != null)
          Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Semantics(liveRegion: true, child: Text(_message!))),
        if (_catalog == null)
          const TrainingCard(child: Text('暂时无法读取题库，请返回后重试。')),
        if (_catalog != null && banks.isEmpty)
          const TrainingCard(child: Text('该分类暂无可选题库。')),
        if (banks.isNotEmpty && filtered.isEmpty)
          const TrainingCard(child: Text('没有匹配的题库。')),
        for (final bank in filtered)
          TrainingCard(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(children: [
                Expanded(
                    child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _opening ? null : () => _toggle(bank.bankName),
                        child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 8),
                            child: Row(children: [
                              const TrainingBankBadge(),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(bank.bankName,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.w600)),
                                    if (original[bank.bankName]
                                            ?.bindingStatus ==
                                        TrainingBindingStatus.invalidated)
                                      Text('原绑定已失效；重新勾选不会恢复绑定',
                                          style: TextStyle(
                                              color: colors.onSurfaceVariant)),
                                  ])),
                            ])))),
                if (widget.onOpenBank != null &&
                    original[bank.bankName]?.bindingStatus !=
                        TrainingBindingStatus.invalidated)
                  IconButton(
                      key: ValueKey('bank-detail-${bank.bankName}'),
                      tooltip: '查看题库详情：${bank.bankName}',
                      style:
                          IconButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed:
                          _opening ? null : () => _openBank(bank.bankName),
                      icon: Icon(Icons.open_in_new,
                          size: 21, semanticLabel: '查看题库详情：${bank.bankName}')),
                SizedBox(
                    width: 48,
                    height: 48,
                    child: Checkbox(
                        key: ValueKey('bank-select-${bank.bankName}'),
                        semanticLabel: '选择题库：${bank.bankName}',
                        value: _selected.contains(bank.bankName),
                        onChanged:
                            _opening ? null : (_) => _toggle(bank.bankName))),
              ])),
        for (final name in retainedNames)
          TrainingCard(
              child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(name),
                  subtitle: Text(
                      '原关联题库 · ${original[name] == null ? '题库已变化或暂不可用' : trainingInvalidationLabel(original[name]!)}'),
                  trailing: _selected.contains(name)
                      ? IconButton(
                          tooltip: '移除 $name',
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: _opening
                              ? null
                              : () => setState(() => _selected.remove(name)))
                      : const Text('已移除'))),
      ]),
      bottomNavigationBar: SafeArea(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Expanded(child: Text('已选择 ${_selected.length} 个题库')),
                FilledButton(
                    onPressed: _selected.isEmpty || _opening || _catalog == null
                        ? null
                        : () =>
                            Navigator.pop(context, List<String>.of(_selected)),
                    child: const Text('下一步')),
              ]))),
    );
  }
}
