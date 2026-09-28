import 'package:flutter/material.dart';
import '../../application/answer_completion/answer_completion_query.dart';
import '../../application/answers/ai_answer_generation.dart';
import '../dependencies/answer_completion_dependencies_scope.dart';
import '../widgets/structured_content_renderer.dart';
import 'answer_completion_ai_review.dart';
import 'supplemental_answer_review_screen.dart';
import 'supplemental_answer_source_picker_sheet.dart';

/// Secondary work queue and imported-set detail. Counts and eligibility come
/// only from the Application snapshot; presentation never reads repositories.
class AnswerCompletionScreen extends StatefulWidget {
  const AnswerCompletionScreen({super.key, required this.bankName, this.setId});
  final String bankName;
  final String? setId;

  @override
  State<AnswerCompletionScreen> createState() => _AnswerCompletionScreenState();
}

class _AnswerCompletionScreenState extends State<AnswerCompletionScreen> {
  Future<AnswerCompletionRead>? _read;
  AnswerCompletionDependenciesScope? _dependencies;
  bool _showAll = false;
  bool _opening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dependencies = AnswerCompletionDependenciesScope.maybeOf(context);
    if (_dependencies != dependencies || _read == null) {
      _dependencies = dependencies;
      _read = _load();
    }
  }

  Future<AnswerCompletionRead> _load() async {
    try {
      return await _dependencies?.query.readBank(widget.bankName) ??
          const AnswerCompletionQueryUnavailable();
    } catch (_) {
      return const AnswerCompletionQueryUnavailable();
    }
  }

  void _reload() => setState(() {
        _read = _load();
      });

  Future<void> _openSet(AnswerCompletionSet set) async {
    await Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) => AnswerCompletionScreen(
                bankName: widget.bankName, setId: set.set.setId)));
    if (mounted) _reload();
  }

  Future<void> _supplement(AnswerCompletionSet selected) async {
    final dependencies = _dependencies!;
    if (_opening ||
        !selected.canSupplement ||
        dependencies.supplemental == null ||
        dependencies.confirmCommand == null) {
      return;
    }
    setState(() => _opening = true);
    try {
      final binding = dependencies.supplemental!.bind(selected);
      final session = await showSupplementalAnswerSourcePicker(
          context: context,
          service: binding.activation,
          sourceAcquisition: binding.acquisition,
          targetScope: binding.scope,
          pickFile: dependencies.pickFile);
      if (!mounted || session == null) return;
      await Navigator.push(
          context,
          MaterialPageRoute<void>(
              builder: (_) => SupplementalAnswerReviewScreen(
                  session: session,
                  confirmCommand: dependencies.confirmCommand!)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('题组暂时不可用，请刷新后重试。')));
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
        _reload();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(widget.setId == null ? '待补答案' : '导入题组详情'),
            actions: [
              IconButton(
                  onPressed: _reload,
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh))
            ]),
        body: FutureBuilder<AnswerCompletionRead>(
            future: _read,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = snapshot.data;
              if (data is! AnswerCompletionSnapshot) {
                return _notice('暂时无法读取待补答案，请重试。');
              }
              final setId = widget.setId;
              if (setId == null) return _queue(data);
              final set = data.findSet(setId);
              if (set == null) return _notice('题组已不可用，请返回刷新。');
              return _detail(set);
            }),
      );

  Widget _notice(String message) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message),
        TextButton(onPressed: _reload, child: const Text('重试'))
      ]));

  Widget _heading(String title) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium));

  Widget _queue(AnswerCompletionSnapshot data) =>
      ListView(padding: const EdgeInsets.all(16), children: [
        _heading('待处理'),
        ..._sets(data, AnswerCompletionCategory.pending),
        _heading('未分组题目'),
        if (data.ungrouped.isEmpty) const Text('暂无题目'),
        for (final member in data.ungrouped) _member(member),
        _heading('暂不支持 / 数据异常'),
        ..._sets(data, AnswerCompletionCategory.unsupported),
        _heading('已完成'),
        ..._sets(data, AnswerCompletionCategory.completed),
      ]);

  List<Widget> _sets(
      AnswerCompletionSnapshot data, AnswerCompletionCategory category) {
    final sets = data.sets.where((s) => s.category == category).toList();
    return [
      if (sets.isEmpty) const Text('暂无题组'),
      for (final set in sets)
        ListTile(
            title: Text(set.set.displayName),
            subtitle: Text(_counts(set)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openSet(set))
    ];
  }

  String _counts(AnswerCompletionSet set) =>
      '共 ${set.total} · 待补 ${set.missing} · 已答 ${set.answered} · 暂不支持/异常 ${set.ineligible}';

  Widget _detail(AnswerCompletionSet set) =>
      ListView(padding: const EdgeInsets.all(16), children: [
        _heading(set.set.displayName),
        Text(_counts(set)),
        Text(switch (set.provenance) {
          AnswerCompletionProvenance.none => '未关联源文件',
          AnswerCompletionProvenance.available => '源文件在文件库中',
          AnswerCompletionProvenance.unavailable => '源文件不可用或已删除，题组仍保留',
        }),
        if (!set.canSupplement) const Text('题组包含暂不支持或异常成员，无法进行文件匹配。'),
        if (set.completed) const Text('已完成补充（不代表答案已经验证正确）'),
        FilledButton.tonal(
            onPressed: set.canSupplement &&
                    !_opening &&
                    _dependencies?.supplemental != null &&
                    _dependencies?.confirmCommand != null
                ? () => _supplement(set)
                : null,
            child: const Text('从答案文件补充')),
        SwitchListTile(
            title: const Text('显示全部题目'),
            value: _showAll,
            onChanged: (value) => setState(() => _showAll = value)),
        if (!_showAll && set.missing == 0) const Text('没有待补答案的题目'),
        for (final member in set.members)
          if (_showAll ||
              member.eligibility == AnswerCompletionEligibility.missing)
            _member(member),
      ]);

  Widget _member(AnswerCompletionMember member) => _MemberCard(
      key: ValueKey(member.storageId),
      member: member,
      dependencies: _dependencies!,
      onCommitted: _reload);
}

class _MemberCard extends StatefulWidget {
  const _MemberCard(
      {super.key,
      required this.member,
      required this.dependencies,
      required this.onCommitted});
  final AnswerCompletionMember member;
  final AnswerCompletionDependenciesScope dependencies;
  final VoidCallback onCommitted;
  @override
  State<_MemberCard> createState() => _MemberCardState();
}

class _MemberCardState extends State<_MemberCard> {
  bool _busy = false;
  AiAnswerGenerationService? _generation;
  @override
  void dispose() {
    if (_busy) _generation?.cancel(widget.member.storageId);
    super.dispose();
  }

  Future<void> _generate() async {
    if (_busy || !widget.member.isTyped) return;
    final generation = widget.dependencies.generationService;
    final commit = widget.dependencies.aiCommitCommand;
    if (generation == null || commit == null) return;
    _generation = generation;
    setState(() => _busy = true);
    try {
      final result = await generation.generateForQuestion(
          storageId: widget.member.storageId);
      if (!mounted) return;
      if (result is AiAnswerGenerationGenerated) {
        final committed = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => AiAnswerReviewDialog(
                candidate: result.candidate,
                session: result.reviewSession,
                commitCommand: commit));
        if (mounted && committed == true) widget.onCommitted();
      }
    } on AiAnswerGenerationException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(aiAnswerGenerationFailureMessage(error.failure))));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('生成失败，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final member = widget.member;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(switch (member.eligibility) {
                AnswerCompletionEligibility.missing => '待补答案',
                AnswerCompletionEligibility.answered => '已有答案',
                AnswerCompletionEligibility.legacy => '暂不支持：旧版题目',
                AnswerCompletionEligibility.corrupt => '数据异常：无法安全读取题目',
              }),
              if (member.draft case final draft?) ...[
                RichContentRenderer(content: draft.stem),
                for (final option in draft.options)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${option.label}. '),
                    Expanded(
                        child: RichContentRenderer(content: option.content))
                  ]),
                TextButton.icon(
                    onPressed: !_busy &&
                            widget.dependencies.generationService != null &&
                            widget.dependencies.aiCommitCommand != null
                        ? _generate
                        : null,
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(_busy ? '正在生成…' : 'AI补答案')),
              ],
            ])));
  }
}
