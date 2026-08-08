import 'package:flutter/material.dart';

import '../../data/repositories/question_repository.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/content/typed_answer_editor_codec.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../utils/typed_answer_input_parser.dart';
import '../models/persisted_question_view.dart';
import '../widgets/structured_content_renderer.dart';

/// Typed answer-only repair screen (P5.2).
///
/// The screen edits exactly one field of the typed draft: the answer. The
/// stem and choice options render read-only through the RichContent
/// renderer, and every other draft field (kind, questionNumber, options,
/// explanation, sourceRefs, assetRefs, issues) plus the review state is
/// preserved by the frozen repository mutation. Input is typed view/domain
/// data only; legacy rows and raw `Map<String, dynamic>` payloads are never
/// accepted here.
class TypedAnswerRepairScreen extends StatefulWidget {
  const TypedAnswerRepairScreen({
    super.key,
    required this.question,
    required this.draft,
    this.repository,
  });

  final PersistedQuestionView question;

  /// `question.typedDraft`; the caller guarantees a non-null typed draft.
  final QuestionDraftV2 draft;

  /// Injectable for widget tests; defaults to the shared repository.
  final QuestionRepository? repository;

  @override
  State<TypedAnswerRepairScreen> createState() =>
      _TypedAnswerRepairScreenState();
}

class _TypedAnswerRepairScreenState extends State<TypedAnswerRepairScreen> {
  // Fixed redacted user-facing messages: no internal data, SQL, payload,
  // storage id, or content ever enters these strings.
  static const String _unsupportedMessage = '答案包含不支持的内容，请修改后重试';
  static const String _readOnlyUnsupportedMessage = '当前答案包含暂不支持编辑的内容，已保留原答案';
  static const String _staleMessage = '题目已在编辑期间被修改，请返回列表刷新后重试';
  static const String _saveFailedMessage = '保存失败，请稍后重试';
  static const String _clearChoiceHint = '不选择任何选项并保存将清空答案';

  final TextEditingController _answerController = TextEditingController();
  late final Set<String> _selectedOptionIds = <String>{
    if (widget.draft.answer case ChoiceAnswer(:final optionIds)) ...optionIds,
  };

  /// Editable text the editor opened with. Saving identical text preserves
  /// the original answer exactly (lossless no-op round-trip).
  late final String _initialText;

  /// True when the current answer contains nodes that cannot enter the text
  /// editor without loss (raw fallback). The original answer is preserved
  /// and saving is blocked.
  late final bool _readOnlyUnsupported;

  RichContent? _previewContent;
  String? _errorMessage;
  bool _isSaving = false;

  /// Checkbox editing is used only for reachable choice states with enough
  /// options and a choice-shaped answer. A `ContentAnswer` on a choice kind
  /// (legal fallback) and insufficient-option drafts (0/1) always use the
  /// text editor so manual repair is never blocked.
  bool get _useCheckboxEditor =>
      widget.draft.kind == QuestionKind.singleChoice &&
      widget.draft.options.length >= 2 &&
      widget.draft.answer is! ContentAnswer;

  @override
  void initState() {
    super.initState();
    final answer = widget.draft.answer;
    var initialText = '';
    var unsupported = false;
    if (answer case ContentAnswer(:final content)) {
      switch (TypedAnswerEditorCodec.encode(content)) {
        case TypedAnswerEditorText(:final text):
          initialText = text;
        case TypedAnswerEditorUnsupported():
          unsupported = true;
        case TypedAnswerEditorContent():
          break;
      }
    } else if (answer case ChoiceAnswer(:final optionIds)) {
      // Text fallback for insufficient-option drafts: display-only label
      // projection. A no-op save keeps the original ChoiceAnswer; edits
      // produce a typed ContentAnswer.
      initialText =
          optionIds.map((optionId) => _optionLabel(optionId)).join(', ');
    }
    _initialText = initialText;
    _readOnlyUnsupported = unsupported;
    if (!_useCheckboxEditor && !unsupported) {
      _answerController.text = initialText;
      _updatePreview(initialText);
    }
  }

  String _optionLabel(String optionId) {
    for (final option in widget.draft.options) {
      if (option.optionId == optionId) return option.label;
    }
    return optionId;
  }

  @override
  void dispose() {
    _answerController.dispose();
    super.dispose();
  }

  void _updatePreview(String text) {
    switch (TypedAnswerInputParser.parse(text)) {
      case TypedAnswerInputParsed(:final content):
        setState(() {
          _previewContent = content;
          _errorMessage = null;
        });
      case TypedAnswerInputEmpty():
        setState(() {
          _previewContent = null;
          _errorMessage = null;
        });
      case TypedAnswerInputUnsupported():
        setState(() {
          _previewContent = null;
          _errorMessage = _unsupportedMessage;
        });
    }
  }

  Future<void> _save() async {
    if (_isSaving || _readOnlyUnsupported) return;

    final QuestionAnswer? newAnswer;
    if (_useCheckboxEditor) {
      if (_selectedOptionIds.isEmpty) {
        // Explicit clear / 暂不确定: a choice answer may be emptied to null.
        newAnswer = null;
      } else {
        // Persistence stores option identities only; the saved order follows
        // the current draft option order, never the click order.
        newAnswer = ChoiceAnswer(
          optionIds: <String>[
            for (final option in widget.draft.options)
              if (_selectedOptionIds.contains(option.optionId)) option.optionId,
          ],
        );
      }
    } else if (_answerController.text == _initialText) {
      // No semantic edit: preserve the original answer exactly (lossless
      // no-op round-trip, including explicit typed empty content).
      newAnswer = widget.draft.answer;
    } else {
      switch (TypedAnswerInputParser.parse(_answerController.text)) {
        case TypedAnswerInputParsed(:final content):
          newAnswer = ContentAnswer(content: content);
        case TypedAnswerInputEmpty():
          // Empty/whitespace input clears the answer; never a placeholder.
          newAnswer = null;
        case TypedAnswerInputUnsupported():
          setState(() => _errorMessage = _unsupportedMessage);
          return;
      }
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    final repository = widget.repository ?? QuestionRepository.instance;
    try {
      await repository.updateTypedAnswer(
        storageId: widget.question.storageId,
        expectedDraft: widget.draft,
        newAnswer: newAnswer,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on TypedAnswerMutationException catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = error.failure == TypedAnswerMutationFailure.stale
            ? _staleMessage
            : _saveFailedMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('修正答案')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionLabel('题干'),
            const SizedBox(height: 8),
            RichContentRenderer(content: widget.draft.stem),
            // Options render read-only whenever the checkbox editor is not
            // used, so a content fallback or insufficient-option draft still
            // shows the full question context.
            if (!_useCheckboxEditor && widget.draft.options.isNotEmpty) ...[
              const SizedBox(height: 16),
              const _SectionLabel('选项'),
              const SizedBox(height: 8),
              for (final option in widget.draft.options)
                _buildOption(context, option),
            ],
            const Divider(height: 32),
            const _SectionLabel('答案'),
            const SizedBox(height: 8),
            if (_readOnlyUnsupported)
              _buildReadOnlyAnswer()
            else if (_useCheckboxEditor)
              _buildChoiceEditor()
            else
              _buildContentEditor(),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              _buildError(_errorMessage!),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (_isSaving || _readOnlyUnsupported) ? null : _save,
                child: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOption(
    BuildContext context,
    QuestionOption option,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${option.label}.',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: RichContentRenderer(content: option.content, fontSize: 15),
          ),
        ],
      ),
    );
  }

  /// Multi-select semantics: the typed answer is a multi-option
  /// [ChoiceAnswer], so the editor never narrows choice questions to a
  /// single selection. Deselecting every option and saving clears the answer
  /// to null.
  Widget _buildChoiceEditor() {
    return Column(
      children: [
        for (final option in widget.draft.options)
          CheckboxListTile(
            value: _selectedOptionIds.contains(option.optionId),
            onChanged: _isSaving
                ? null
                : (checked) {
                    setState(() {
                      if (checked ?? false) {
                        _selectedOptionIds.add(option.optionId);
                      } else {
                        _selectedOptionIds.remove(option.optionId);
                      }
                      _errorMessage = null;
                    });
                  },
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Row(
              children: [
                Text(
                  '${option.label}.',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: RichContentRenderer(
                    content: option.content,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(
          _clearChoiceHint,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  /// Read-only mode for answers containing nodes the current text editor
  /// cannot represent losslessly. The original answer stays untouched and
  /// saving is blocked.
  Widget _buildReadOnlyAnswer() {
    final answer = widget.draft.answer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (answer case ContentAnswer(:final content)) ...[
          RichContentRenderer(content: content),
          const SizedBox(height: 12),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.orangeAccent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.orangeAccent.withValues(alpha: 0.4),
            ),
          ),
          child: const Text(
            _readOnlyUnsupportedMessage,
            style: TextStyle(fontSize: 13, color: Colors.orangeAccent),
          ),
        ),
      ],
    );
  }

  Widget _buildContentEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _answerController,
          onChanged: _updatePreview,
          minLines: 3,
          maxLines: null,
          decoration: const InputDecoration(
            hintText: '输入答案内容；留空可清空答案',
            border: OutlineInputBorder(),
          ),
        ),
        if (_previewContent != null) ...[
          const SizedBox(height: 12),
          const _SectionLabel('预览'),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: RichContentRenderer(content: _previewContent!),
          ),
        ],
      ],
    );
  }

  Widget _buildError(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        color: Colors.grey,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}
