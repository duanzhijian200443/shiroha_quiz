import 'package:flutter/material.dart';
import '../../application/generated_question/generated_question_service.dart';
import '../../domain/generated_question/generated_question_contract.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';
import 'generated_proposal_controllers.dart';

/// Each ordered node has its own literal value editor. No text projection or
/// Markdown/math parser participates in this review model.
class GeneratedTypedQuestionEditor extends StatefulWidget {
  const GeneratedTypedQuestionEditor({super.key, required this.item});
  final GeneratedItem item;
  @override
  State<GeneratedTypedQuestionEditor> createState() =>
      _GeneratedTypedQuestionEditorState();
}

class _GeneratedTypedQuestionEditorState
    extends State<GeneratedTypedQuestionEditor> {
  final Map<String, Object?> values = {};
  String? error;
  bool leaving = false;
  List<Map<String, Object?>> get changes {
    final draft = widget.item.working;
    final originals = <String, Object?>{
      'stem': generatedContentJson(draft.stem),
      'explanation': draft.explanation == null
          ? null
          : generatedContentJson(draft.explanation!),
      'answer': switch (draft.answer) {
        ChoiceAnswer(:final optionIds) => {
            'type': 'choice',
            'optionIds': optionIds
          },
        ContentAnswer(:final content) => {
            'type': 'content',
            'content': generatedContentJson(content)
          },
        null => null
      },
      for (final option in draft.options)
        option.optionId: generatedContentJson(option.content)
    };
    return [
      for (final entry in values.entries)
        if (generatedCanonical(entry.value) !=
            generatedCanonical(originals[entry.key]))
          {
            'itemId': widget.item.itemId,
            'field': originals.containsKey(entry.key) &&
                    ['stem', 'answer', 'explanation'].contains(entry.key)
                ? entry.key
                : 'optionContent',
            if (!['stem', 'answer', 'explanation'].contains(entry.key))
              'optionId': entry.key,
            'value': entry.value
          }
    ];
  }

  void update(String field, Object? value) =>
      setState(() => values[field] = value);
  Future<void> cancel() async {
    if (leaving) return;
    final discard = changes.isEmpty ||
        await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                        title: const Text('放弃本次编辑？'),
                        content: const Text('本次编辑尚未应用到审核工作副本。'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('继续编辑')),
                          FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('放弃编辑'))
                        ])) ==
            true;
    if (discard && mounted) {
      setState(() => leaving = true);
      Navigator.pop(context);
    }
  }

  void apply() {
    try {
      var draft = widget.item.working;
      for (final edit in changes) {
        draft = applyGeneratedEdit(draft, edit);
      }
      final result = changes;
      setState(() => leaving = true);
      Navigator.pop(context, result);
    } catch (e) {
      setState(() => error = generatedReviewError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.item.working;
    return PopScope(
        canPop: leaving || changes.isEmpty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) cancel();
        },
        child: Scaffold(
            appBar: AppBar(
                title: const Text('编辑题目'),
                leading: IconButton(
                    onPressed: cancel, icon: const Icon(Icons.close))),
            body: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child:
                        ListView(padding: const EdgeInsets.all(16), children: [
                      const Text('题型和选项身份固定；文本与数学节点按原顺序分别编辑。'),
                      if (error != null)
                        Text(error!,
                            key: const ValueKey('generated-edit-error')),
                      _TypedContentField(
                          label: '题干',
                          fieldKey: 'stem',
                          initial: draft.stem,
                          onChanged: (v) => update('stem',
                              v == null ? null : generatedContentJson(v))),
                      for (final option in draft.options)
                        _TypedContentField(
                            label: '选项 ${option.label}',
                            fieldKey: option.optionId,
                            initial: option.content,
                            onChanged: (v) => update(option.optionId,
                                v == null ? null : generatedContentJson(v))),
                      if (draft.answer case ChoiceAnswer(:final optionIds)) ...[
                        const Text('标准答案'),
                        DropdownButtonFormField<String>(
                            key: const ValueKey('generated-choice-answer'),
                            initialValue: optionIds.single,
                            items: [
                              for (final option in draft.options)
                                DropdownMenuItem(
                                    value: option.optionId,
                                    child: Text(option.label))
                            ],
                            onChanged: (id) {
                              if (id != null) {
                                update('answer', {
                                  'type': 'choice',
                                  'optionIds': [id]
                                });
                              }
                            })
                      ] else if (draft.answer
                          case ContentAnswer(:final content))
                        _TypedContentField(
                            label: '标准答案',
                            fieldKey: 'answer',
                            initial: content,
                            onChanged: (v) => update('answer', {
                                  'type': 'content',
                                  'content': generatedContentJson(v!)
                                })),
                      _TypedContentField(
                          label: '解析',
                          fieldKey: 'explanation',
                          initial: draft.explanation,
                          nullable: true,
                          onChanged: (v) => update('explanation',
                              v == null ? null : generatedContentJson(v))),
                      const SizedBox(height: 16),
                      FilledButton(
                          key: const ValueKey('generated-apply-edit'),
                          onPressed: apply,
                          child: const Text('应用编辑')),
                    ])))));
  }
}

class _NodeValue {
  _NodeValue(ContentNode node)
      : type = switch (node) {
          TextNode() => 0,
          InlineMathNode() => 1,
          BlockMathNode() => 2,
          _ => throw StateError('Unsupported typed node')
        },
        controller = TextEditingController(
            text: switch (node) {
          TextNode(:final text) => text,
          InlineMathNode(:final latex) || BlockMathNode(:final latex) => latex,
          _ => ''
        });
  final int type;
  final TextEditingController controller;
  ContentNode get node => switch (type) {
        0 => TextNode(controller.text),
        1 => InlineMathNode(controller.text),
        _ => BlockMathNode(controller.text)
      };
}

class _TypedContentField extends StatefulWidget {
  const _TypedContentField(
      {required this.label,
      required this.fieldKey,
      required this.initial,
      required this.onChanged,
      this.nullable = false});
  final String label, fieldKey;
  final RichContent? initial;
  final bool nullable;
  final ValueChanged<RichContent?> onChanged;
  @override
  State<_TypedContentField> createState() => _TypedContentFieldState();
}

class _TypedContentFieldState extends State<_TypedContentField> {
  late final nodes = [
    for (final node in widget.initial?.nodes ?? <ContentNode>[])
      _NodeValue(node)
  ];
  late bool present = widget.initial != null;
  void changed() {
    widget.onChanged(present
        ? RichContent(nodes: [for (final node in nodes) node.node])
        : null);
  }

  void clear() {
    for (final node in nodes) {
      node.controller.dispose();
    }
    nodes.clear();
  }

  @override
  void dispose() {
    clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.label, style: Theme.of(context).textTheme.titleMedium),
        if (widget.nullable)
          Wrap(spacing: 8, children: [
            ChoiceChip(
                key: ValueKey('generated-${widget.fieldKey}-null'),
                label: const Text('不提供'),
                selected: !present,
                onSelected: (_) {
                  setState(() => present = false);
                  changed();
                }),
            ChoiceChip(
                key: ValueKey('generated-${widget.fieldKey}-empty'),
                label: const Text('明确为空'),
                selected: present && nodes.isEmpty,
                onSelected: (_) {
                  setState(() {
                    present = true;
                    clear();
                  });
                  changed();
                }),
            ChoiceChip(
                label: const Text('提供解析'),
                selected: present && nodes.isNotEmpty,
                onSelected: (_) {
                  setState(() => present = true);
                  changed();
                })
          ]),
        if (present) ...[
          for (var i = 0; i < nodes.length; i++)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                    key: ValueKey('generated-node-${widget.fieldKey}-$i'),
                    controller: nodes[i].controller,
                    minLines: 1,
                    maxLines: null,
                    decoration: InputDecoration(
                        labelText: '${widget.label} · ${[
                          '文本',
                          '行内公式',
                          '块公式'
                        ][nodes[i].type]} ${i + 1}',
                        border: const OutlineInputBorder()),
                    onChanged: (_) => changed())),
          Wrap(spacing: 8, children: [
            for (var type = 0; type < 3; type++)
              TextButton(
                  key: ValueKey('generated-add-${widget.fieldKey}-$type'),
                  onPressed: () {
                    setState(() => nodes.add(_NodeValue(switch (type) {
                          0 => const TextNode(''),
                          1 => const InlineMathNode(''),
                          _ => const BlockMathNode('')
                        })));
                    changed();
                  },
                  child: Text('添加${['文本', '行内公式', '块公式'][type]}'))
          ]),
        ]
      ]));
}
