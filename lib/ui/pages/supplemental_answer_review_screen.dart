import 'package:flutter/material.dart';

import '../../application/supplemental_answers/supplemental_answer_command.dart';
import '../../application/supplemental_answers/supplemental_answer_failure.dart';
import '../../application/supplemental_answers/supplemental_answer_review_session.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/supplemental_answers/answer_candidate.dart';
import '../../domain/question/question_draft_v2.dart';
import '../widgets/structured_content_renderer.dart';

/// Bounded P6 Preview/Review activation.
///
/// This screen is the only P6 presentation surface in v0: it renders the
/// transient review session, drives explicit per-candidate confirmation
/// through the shared typed-answer command, and never mutates anything
/// itself. It does not add navigation/IA, file picking, OCR, or candidate
/// editing.
class SupplementalAnswerReviewScreen extends StatefulWidget {
  const SupplementalAnswerReviewScreen({
    super.key,
    required this.session,
    required this.confirmCommand,
  });

  final SupplementalAnswerReviewSession session;
  final SupplementalAnswerConfirmCommand confirmCommand;

  @override
  State<SupplementalAnswerReviewScreen> createState() =>
      _SupplementalAnswerReviewScreenState();
}

class _SupplementalAnswerReviewScreenState
    extends State<SupplementalAnswerReviewScreen> {
  late SupplementalAnswerReviewSession _session;
  final Set<String> _selectedFillIds = <String>{};
  final Set<String> _replaceArmedIds = <String>{};
  bool _confirming = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
  }

  Future<void> _confirmFill(AnswerCandidate candidate) async {
    setState(() {
      _confirming = true;
      _errorMessage = null;
    });
    try {
      final decided = _session.confirmFill(candidate.candidateId);
      await widget.confirmCommand.confirm(decided.confirmation);
      if (!mounted) return;
      setState(() {
        _session = decided.session.markCommitted(candidate.candidateId);
        _selectedFillIds.remove(candidate.candidateId);
        _confirming = false;
      });
    } on SupplementalAnswerException catch (error) {
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _errorMessage = _messageFor(error.failure);
      });
    } on SupplementalAnswerReviewException catch (error) {
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _confirmReplace(AnswerCandidate candidate) async {
    setState(() {
      _confirming = true;
      _errorMessage = null;
    });
    try {
      final decided = _session.confirmReplace(candidate.candidateId);
      await widget.confirmCommand.confirm(decided.confirmation);
      if (!mounted) return;
      setState(() {
        _session = decided.session.markCommitted(candidate.candidateId);
        _replaceArmedIds.remove(candidate.candidateId);
        _confirming = false;
      });
    } on SupplementalAnswerException catch (error) {
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _errorMessage = _messageFor(error.failure);
      });
    } on SupplementalAnswerReviewException catch (error) {
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _errorMessage = error.toString();
      });
    }
  }

  void _armReplace(AnswerCandidate candidate) {
    setState(() {
      _session = _session.selectForReplace(candidate.candidateId);
      _replaceArmedIds.add(candidate.candidateId);
      _errorMessage = null;
    });
  }

  void _reject(AnswerCandidate candidate) {
    setState(() {
      _session = _session.reject(candidate.candidateId);
      _selectedFillIds.remove(candidate.candidateId);
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final fillCandidates = <AnswerCandidate>[];
    final conflictCandidates = <AnswerCandidate>[];
    final terminal = <String>[];
    for (final record in _session.records) {
      final candidate = record.candidate;
      if (candidate == null) {
        terminal.add(
          '${record.fragmentId}: ${record.disposition.name}',
        );
        continue;
      }
      switch (candidate.writeIntent) {
        case CandidateWriteIntent.fill:
          fillCandidates.add(candidate);
        case CandidateWriteIntent.replace:
          conflictCandidates.add(candidate);
        case CandidateWriteIntent.noOp:
          terminal.add('${candidate.candidateId}: noOp');
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('补充答案确认')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_errorMessage != null) ...[
            _ErrorBanner(message: _errorMessage!),
            const SizedBox(height: 12),
          ],
          const _SectionLabel('可填写答案'),
          if (fillCandidates.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('无', style: TextStyle(color: Colors.grey)),
            )
          else
            for (final candidate in fillCandidates)
              _FillCandidateCard(
                candidate: candidate,
                selected: _selectedFillIds.contains(candidate.candidateId),
                outcome: _session.outcomeOf(candidate.candidateId),
                confirming: _confirming,
                onToggle: (selected) {
                  setState(() {
                    if (selected) {
                      _selectedFillIds.add(candidate.candidateId);
                    } else {
                      _selectedFillIds.remove(candidate.candidateId);
                    }
                  });
                },
                onConfirm: () => _confirmFill(candidate),
                onReject: () => _reject(candidate),
              ),
          const Divider(height: 32),
          const _SectionLabel('答案冲突（需逐题二次确认）'),
          if (conflictCandidates.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('无', style: TextStyle(color: Colors.grey)),
            )
          else
            for (final candidate in conflictCandidates)
              _ConflictCandidateCard(
                candidate: candidate,
                outcome: _session.outcomeOf(candidate.candidateId),
                confirming: _confirming,
                replaceArmed: _replaceArmedIds.contains(candidate.candidateId),
                onArmReplace: () => _armReplace(candidate),
                onConfirmReplace: () => _confirmReplace(candidate),
                onReject: () => _reject(candidate),
              ),
          const Divider(height: 32),
          const _SectionLabel('不可写入项'),
          if (terminal.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('无', style: TextStyle(color: Colors.grey)),
            )
          else
            for (final label in terminal)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
        ],
      ),
    );
  }
}

String _messageFor(SupplementalAnswerFailure failure) {
  return switch (failure) {
    SupplementalAnswerFailure.staleTarget =>
      '题目或补充文档已变化，未写入任何内容，请重新匹配。',
    SupplementalAnswerFailure.temporarilyUnavailable =>
      '保存暂时不可用，请稍后重试。',
    SupplementalAnswerFailure.artifactCorrupt ||
    SupplementalAnswerFailure.unsupportedArtifact ||
    SupplementalAnswerFailure.sourceUnavailable =>
      '补充文档不可用，未写入任何内容。',
    SupplementalAnswerFailure.targetUnavailable =>
      '目标题目不可用，未写入任何内容。',
    SupplementalAnswerFailure.invalidCandidate =>
      '候选答案无效，未写入任何内容。',
    SupplementalAnswerFailure.internalError =>
      '发生内部错误，未写入任何内容。',
    SupplementalAnswerFailure.noUsableAnswers ||
    SupplementalAnswerFailure.ambiguousMatch ||
    SupplementalAnswerFailure.unmatched ||
    SupplementalAnswerFailure.conflict =>
      '当前匹配状态不可写入。',
  };
}

RichContent _answerContent(QuestionAnswer answer) {
  return switch (answer) {
    ContentAnswer(:final content) => content,
    ChoiceAnswer(:final optionIds) =>
      RichContent(nodes: [TextNode(optionIds.join(', '))]),
  };
}

class _FillCandidateCard extends StatelessWidget {
  const _FillCandidateCard({
    required this.candidate,
    required this.selected,
    required this.outcome,
    required this.confirming,
    required this.onToggle,
    required this.onConfirm,
    required this.onReject,
  });

  final AnswerCandidate candidate;
  final bool selected;
  final CandidateReviewOutcome outcome;
  final bool confirming;
  final ValueChanged<bool> onToggle;
  final VoidCallback onConfirm;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final committed = outcome == CandidateReviewOutcome.committed;
    final rejected = outcome == CandidateReviewOutcome.rejected;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichContentRenderer(content: candidate.expectedDraft.stem),
            const SizedBox(height: 8),
            const _SectionLabel('候选答案'),
            const SizedBox(height: 4),
            RichContentRenderer(
              content: _answerContent(candidate.answer),
            ),
            const SizedBox(height: 8),
            if (committed)
              const Text(
                '已写入',
                style: TextStyle(color: Colors.green, fontSize: 13),
              )
            else if (rejected)
              const Text(
                '已拒绝',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              )
            else
              Row(
                children: [
                  Checkbox(
                    value: selected,
                    onChanged: confirming ? null : (value) => onToggle(value ?? false),
                  ),
                  const Text('选择'),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: confirming ? null : onReject,
                    child: const Text('拒绝'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed:
                        (confirming || !selected) ? null : onConfirm,
                    child: const Text('确认填写'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ConflictCandidateCard extends StatelessWidget {
  const _ConflictCandidateCard({
    required this.candidate,
    required this.outcome,
    required this.confirming,
    required this.replaceArmed,
    required this.onArmReplace,
    required this.onConfirmReplace,
    required this.onReject,
  });

  final AnswerCandidate candidate;
  final CandidateReviewOutcome outcome;
  final bool confirming;
  final bool replaceArmed;
  final VoidCallback onArmReplace;
  final VoidCallback onConfirmReplace;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final committed = outcome == CandidateReviewOutcome.committed;
    final rejected = outcome == CandidateReviewOutcome.rejected;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichContentRenderer(content: candidate.expectedDraft.stem),
            const SizedBox(height: 8),
            const _SectionLabel('现有答案'),
            const SizedBox(height: 4),
            if (candidate.expectedDraft.answer case final existing?)
              RichContentRenderer(content: _answerContent(existing)),
            const SizedBox(height: 8),
            const _SectionLabel('补充候选答案'),
            const SizedBox(height: 4),
            RichContentRenderer(
              content: _answerContent(candidate.answer),
            ),
            const SizedBox(height: 8),
            if (committed)
              const Text(
                '已替换',
                style: TextStyle(color: Colors.green, fontSize: 13),
              )
            else if (rejected)
              const Text(
                '已拒绝',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              )
            else
              Row(
                children: [
                  OutlinedButton(
                    onPressed: confirming ? null : onReject,
                    child: const Text('拒绝'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: confirming
                        ? null
                        : (replaceArmed ? onConfirmReplace : onArmReplace),
                    child: Text(replaceArmed ? '二次确认替换' : '确认替换'),
                  ),
                ],
              ),
          ],
        ),
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

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
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
