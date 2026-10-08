import 'package:flutter/material.dart';
import '../../domain/generated_question/generated_question_contract.dart';
import '../../domain/question/question_draft_v2.dart';
import '../theme/shiroha_theme_tokens.dart';
import '../widgets/structured_content_renderer.dart';
import 'generated_proposal_controllers.dart';

class GeneratedProposalQuestionCard extends StatelessWidget {
  const GeneratedProposalQuestionCard(
      {super.key,
      required this.item,
      required this.evidenceState,
      this.actions});
  final GeneratedItem item;
  final List<Object?> evidenceState;
  final Widget? actions;
  @override
  Widget build(BuildContext context) {
    final draft = item.working;
    final tokens = Theme.of(context).extension<ShirohaThemeTokens>();
    return Card(
        key: ValueKey('generated-item-${item.itemId}'),
        color: tokens?.surface,
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('第 ${item.position + 1} 题 · ${switch (draft.kind) {
                QuestionKind.singleChoice => '单选题',
                QuestionKind.fillBlank => '填空题',
                QuestionKind.shortAnswer => '简答题'
              }} · ${generatedDecisionLabel(item.decision)}'),
              const SizedBox(height: 12),
              RichContentRenderer(content: draft.stem),
              for (final option in draft.options)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${option.label}. '),
                          Expanded(
                              child:
                                  RichContentRenderer(content: option.content))
                        ])),
              const Divider(height: 24),
              const Text('标准答案'),
              switch (draft.answer) {
                ContentAnswer(:final content) =>
                  RichContentRenderer(content: content),
                ChoiceAnswer(:final optionIds) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final option in draft.options
                            .where((o) => optionIds.contains(o.optionId)))
                          Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${option.label}. '),
                                Expanded(
                                    child: RichContentRenderer(
                                        content: option.content))
                              ])
                      ]),
                null => const Text('未提供答案'),
              },
              const SizedBox(height: 12),
              const Text('解析'),
              if (draft.explanation == null)
                const Text('未提供解析')
              else if (draft.explanation!.nodes.isEmpty)
                const Text('解析为空（已明确保留空内容）')
              else
                RichContentRenderer(content: draft.explanation!),
              const SizedBox(height: 12),
              if (item.evidence.isEmpty)
                const Text('来源：uncited（未引用来源）')
              else ...[
                for (var i = 0; i < item.evidence.length; i++)
                  Text(
                      '来源 ${item.evidence[i].evidenceKey} · ${i < evidenceState.length ? (evidenceState[i] as Map)['status'] : 'unavailable'}\n文件 ${item.evidence[i].fileId} · 原始版本 ${item.evidence[i].artifactRevision}')
              ],
              if (actions != null) ...[const SizedBox(height: 12), actions!],
            ])));
  }
}
