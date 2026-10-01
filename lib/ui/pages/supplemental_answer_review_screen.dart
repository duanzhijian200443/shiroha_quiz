import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/supplemental_answers/supplemental_answer_command.dart';
import '../../application/supplemental_answers/supplemental_answer_failure.dart';
import '../../application/supplemental_answers/supplemental_answer_review_session.dart';
import '../../application/supplemental_answers/supplemental_source_inspection.dart';
import '../../core/observability/diagnostic_summary.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../domain/supplemental_answers/answer_candidate.dart';
import '../../domain/supplemental_answers/answer_match_record.dart';
import '../pages/supplemental_source_viewer.dart';
import '../widgets/structured_content_renderer.dart';

/// Presentation-only seam for opening the original source viewer.
///
/// Launching the viewer is never a verification: implementations must not
/// return any verified/trusted state and must not call `verifySource`.
typedef SupplementalOriginalSourceLauncher = Future<void> Function(
  BuildContext context,
  SupplementalSourceInspection inspection,
  int? pageHint,
);

/// Default launcher: pushes the read-only SV-C2 original source viewer.
Future<void> launchSupplementalOriginalSourceViewer(
  BuildContext context,
  SupplementalSourceInspection inspection,
  int? pageHint,
) {
  return Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => SupplementalSourceViewerScreen(
        inspection: inspection,
        pageHint: pageHint,
      ),
    ),
  );
}

/// Bounded P6 Preview/Review activation.
///
/// This screen is the only P6 presentation surface in v0: it renders the
/// transient review session, drives explicit per-candidate source
/// verification and confirmation through the shared typed-answer command,
/// and never mutates anything itself. Opening the original file never marks
/// a candidate verified; only the explicit per-candidate confirmation does.
class SupplementalAnswerReviewScreen extends StatefulWidget {
  const SupplementalAnswerReviewScreen({
    super.key,
    required this.session,
    required this.confirmCommand,
    this.sourceInspectionService,
    this.originalSourceLauncher = launchSupplementalOriginalSourceViewer,
  });

  final SupplementalAnswerReviewSession session;
  final SupplementalAnswerConfirmCommand confirmCommand;

  /// SV-C1 inspection capability. Null keeps the review readable but makes
  /// source verification unavailable and keeps every write action closed;
  /// nothing is ever auto-trusted.
  final SupplementalSourceInspectionService? sourceInspectionService;

  /// Presentation test seam; owns no verification authority.
  final SupplementalOriginalSourceLauncher originalSourceLauncher;

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

  Future<void> _copyTraceInfo() async {
    final lines = _traceLines(_session.correlationId, _session.traceId);
    if (lines.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: lines.join('\n')));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('诊断信息已复制')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('诊断信息复制失败')),
      );
    }
  }

  /// One inspected original per candidate. Obtaining an inspection only
  /// enables the explicit verify action; it never verifies by itself.
  final Map<String, SupplementalSourceInspection> _inspections =
      <String, SupplementalSourceInspection>{};
  final Set<String> _inspectingIds = <String>{};
  final Set<String> _unsupportedSourceIds = <String>{};

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
        _errorMessage = _reviewFailureMessage(error.failure);
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
        _errorMessage = _reviewFailureMessage(error.failure);
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

  /// Inspects the exact candidate origin through the SV-C1 service and opens
  /// the read-only viewer. Inspection failure never opens the viewer and
  /// never verifies anything; the same candidate never runs two inspections
  /// at once.
  Future<void> _viewOriginalSource(AnswerCandidate candidate) async {
    final service = widget.sourceInspectionService;
    final candidateId = candidate.candidateId;
    final origin = candidate.origin;
    if (service == null ||
        _confirming ||
        _inspectingIds.contains(candidateId) ||
        origin is! SupplementalAnswerOrigin) {
      return;
    }
    setState(() {
      _errorMessage = null;
      _inspectingIds.add(candidateId);
    });
    try {
      final inspection = await service.inspect(origin.supplementalFileId);
      if (!mounted) return;
      if (!_isViewerSupportedMimeType(inspection.mimeType)) {
        setState(() {
          _inspectingIds.remove(candidateId);
          _inspections.remove(candidateId);
          _unsupportedSourceIds.add(candidateId);
        });
        return;
      }
      final pageHint = _pageHintOf(origin);
      setState(() {
        _inspectingIds.remove(candidateId);
        _unsupportedSourceIds.remove(candidateId);
        _inspections[candidateId] = inspection;
      });
      await widget.originalSourceLauncher(context, inspection, pageHint);
    } on SupplementalSourceInspectionException catch (error) {
      if (!mounted) return;
      setState(() {
        _inspectingIds.remove(candidateId);
        _inspections.remove(candidateId);
        _errorMessage = _inspectionFailureMessage(error.failure);
      });
    }
  }

  /// The one explicit per-candidate verification action. Opening or viewing
  /// the original file never reaches this transition by itself.
  void _confirmVerifiedSource(String candidateId) {
    final inspection = _inspections[candidateId];
    if (inspection == null) {
      return;
    }
    setState(() {
      _errorMessage = null;
      try {
        _session = _session.verifySource(candidateId, inspection);
      } on SupplementalAnswerReviewException catch (error) {
        switch (error.failure) {
          case SupplementalAnswerReviewFailure.sourceInspectionRequired:
          case SupplementalAnswerReviewFailure.staleSessionRevision:
            // The cached inspection no longer proves the candidate origin;
            // require a fresh look before anything can be verified again.
            _inspections.remove(candidateId);
            _errorMessage = '原文状态已变化，请重新查看原文件后再确认。';
          default:
            _errorMessage = '当前状态无法记录原文核验。';
        }
      }
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
        terminal.add(_formatTerminalRecord(record));
        continue;
      }
      switch (candidate.writeIntent) {
        case CandidateWriteIntent.fill:
          fillCandidates.add(candidate);
        case CandidateWriteIntent.replace:
          conflictCandidates.add(candidate);
        case CandidateWriteIntent.noOp:
          terminal.add(
            '${candidate.candidateId}: noOp — 内容与现有答案完全一致，无需更新',
          );
      }
    }

    final verificationAvailable = widget.sourceInspectionService != null;

    return Scaffold(
      appBar: AppBar(title: const Text('补充答案确认')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_traceLines(_session.correlationId, _session.traceId)
              .isNotEmpty) ...[
            _SupplementalTraceBanner(
              correlationId: _session.correlationId,
              traceId: _session.traceId,
              onCopy: _copyTraceInfo,
            ),
            const SizedBox(height: 12),
          ],
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
                verificationState:
                    _session.verificationStateOf(candidate.candidateId),
                verificationAvailable: verificationAvailable,
                inspectionReady:
                    _inspections.containsKey(candidate.candidateId),
                inspecting: _inspectingIds.contains(candidate.candidateId),
                sourceUnsupported:
                    _unsupportedSourceIds.contains(candidate.candidateId),
                onToggle: (selected) {
                  setState(() {
                    if (selected) {
                      _selectedFillIds.add(candidate.candidateId);
                    } else {
                      _selectedFillIds.remove(candidate.candidateId);
                    }
                  });
                },
                onViewSource: () => _viewOriginalSource(candidate),
                onConfirmVerifiedSource: () =>
                    _confirmVerifiedSource(candidate.candidateId),
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
                verificationState:
                    _session.verificationStateOf(candidate.candidateId),
                verificationAvailable: verificationAvailable,
                inspectionReady:
                    _inspections.containsKey(candidate.candidateId),
                inspecting: _inspectingIds.contains(candidate.candidateId),
                sourceUnsupported:
                    _unsupportedSourceIds.contains(candidate.candidateId),
                replaceArmed: _replaceArmedIds.contains(candidate.candidateId),
                onViewSource: () => _viewOriginalSource(candidate),
                onConfirmVerifiedSource: () =>
                    _confirmVerifiedSource(candidate.candidateId),
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
    SupplementalAnswerFailure.staleTarget => '题目或补充文档已变化，未写入任何内容，请重新匹配。',
    SupplementalAnswerFailure.temporarilyUnavailable => '保存暂时不可用，请稍后重试。',
    SupplementalAnswerFailure.artifactCorrupt ||
    SupplementalAnswerFailure.unsupportedArtifact ||
    SupplementalAnswerFailure.sourceUnavailable =>
      '补充文档不可用，未写入任何内容。',
    SupplementalAnswerFailure.targetUnavailable => '目标题目不可用，未写入任何内容。',
    SupplementalAnswerFailure.invalidCandidate => '候选答案无效，未写入任何内容。',
    SupplementalAnswerFailure.internalError => '发生内部错误，未写入任何内容。',
    SupplementalAnswerFailure.noUsableAnswers ||
    SupplementalAnswerFailure.ambiguousMatch ||
    SupplementalAnswerFailure.unmatched ||
    SupplementalAnswerFailure.conflict =>
      '当前匹配状态不可写入。',
  };
}

/// Fixed safe messages for review-lifecycle failures; no raw exception text
/// ever reaches the UI.
String _reviewFailureMessage(SupplementalAnswerReviewFailure failure) {
  return switch (failure) {
    SupplementalAnswerReviewFailure.sourceVerificationRequired =>
      '请先对照原文件完成原文核验，再进行确认。',
    SupplementalAnswerReviewFailure.sourceInspectionRequired =>
      '原文状态已变化，请重新查看原文件后再确认。',
    SupplementalAnswerReviewFailure.staleSessionRevision => '评审状态已更新，请重试。',
    SupplementalAnswerReviewFailure.unknownCandidate ||
    SupplementalAnswerReviewFailure.alreadyDecided =>
      '该候选答案已处理或不在当前评审中。',
    SupplementalAnswerReviewFailure.ambiguousNotCommittable ||
    SupplementalAnswerReviewFailure.unmatchedNotCommittable ||
    SupplementalAnswerReviewFailure.invalidNotCommittable =>
      '当前匹配状态不可写入。',
    SupplementalAnswerReviewFailure.conflictRequiresReplaceReconfirmation =>
      '答案冲突需逐题二次确认替换。',
    SupplementalAnswerReviewFailure.fillOnlyForMissingAnswers ||
    SupplementalAnswerReviewFailure.noOpTerminal =>
      '当前候选状态不可写入。',
  };
}

String _formatTerminalRecord(AnswerMatchRecord record) {
  final negativeCodes = record.evidence.where((code) => switch (code) {
        MatchEvidenceCode.ambiguousChoiceLabel ||
        MatchEvidenceCode.noLocator ||
        MatchEvidenceCode.missingPrimaryProof ||
        MatchEvidenceCode.duplicateLocator ||
        MatchEvidenceCode.multipleTargets ||
        MatchEvidenceCode.subquestionSetMismatch ||
        MatchEvidenceCode.typeIncompatible ||
        MatchEvidenceCode.unsupportedContent ||
        MatchEvidenceCode.sourceConflict ||
        MatchEvidenceCode.legacyIneligible ||
        MatchEvidenceCode.sequenceOnly =>
          true,
        _ => false,
      });

  final dispName = record.disposition.name;
  final dispLabel = _dispositionLabel(record.disposition);
  if (negativeCodes.isNotEmpty) {
    final reasons = negativeCodes.map(_evidenceDescription).join('，');
    return '${record.fragmentId}: $dispName — $dispLabel: $reasons';
  }
  return '${record.fragmentId}: $dispName — $dispLabel';
}

String _dispositionLabel(AnswerMatchDisposition disposition) {
  return switch (disposition) {
    AnswerMatchDisposition.unmatched => '未匹配',
    AnswerMatchDisposition.invalid => '无效答案',
    AnswerMatchDisposition.ambiguous => '歧义项',
    AnswerMatchDisposition.conflict => '存在冲突',
    AnswerMatchDisposition.matched => '已匹配',
  };
}

String _evidenceDescription(MatchEvidenceCode code) {
  return switch (code) {
    MatchEvidenceCode.ambiguousChoiceLabel => '选项标签不明确（未能识别出唯一选项）',
    MatchEvidenceCode.noLocator => '未能识别出有效题号定位',
    MatchEvidenceCode.missingPrimaryProof => '未在目标题库中找到对应题号',
    MatchEvidenceCode.duplicateLocator => '文档中存在重复题号',
    MatchEvidenceCode.multipleTargets => '匹配到多个目标题目，存在歧义',
    MatchEvidenceCode.subquestionSetMismatch => '子题目编号范围与题库不一致',
    MatchEvidenceCode.typeIncompatible => '题目类型不兼容（与题库题型不匹配）',
    MatchEvidenceCode.unsupportedContent => '答案包含暂不支持写入的内容格式',
    MatchEvidenceCode.sourceConflict => '文档中存在相互冲突的答案',
    MatchEvidenceCode.legacyIneligible => '旧版本非结构化题目，不支持写入',
    MatchEvidenceCode.sequenceOnly => '仅有上下文顺序，缺乏明确题号证据',
    MatchEvidenceCode.uniqueMainNumber => '题号唯一',
    MatchEvidenceCode.mainNumberAndSubquestion => '题号与子题号明确',
    MatchEvidenceCode.uniqueStemFingerprint => '题干特征唯一',
    MatchEvidenceCode.continuationGroup => '连续题组',
    MatchEvidenceCode.typeCompatible => '题型兼容',
    MatchEvidenceCode.headingCorroboration => '章节标题吻合',
    MatchEvidenceCode.sourceCorroboration => '来源关系吻合',
    MatchEvidenceCode.neighborhoodConsistency => '相邻题号连续',
  };
}

/// Fixed safe messages for SV-C1 inspection failures; never a path, key, or
/// raw exception.
String _inspectionFailureMessage(SupplementalSourceInspectionFailure failure) {
  return switch (failure) {
    SupplementalSourceInspectionFailure.artifactUnavailable ||
    SupplementalSourceInspectionFailure.artifactChanged =>
      '补充文档解析状态已变化，请重新匹配。',
    SupplementalSourceInspectionFailure.fileUnavailable ||
    SupplementalSourceInspectionFailure.sourceReadFailed ||
    SupplementalSourceInspectionFailure.sourceIntegrityMismatch =>
      '原文件不可用或已变化，请重新选择或重新匹配。',
    SupplementalSourceInspectionFailure.resourceLimitExceeded =>
      '文件较大，当前无法在应用内完成原文核验。',
  };
}

bool _isViewerSupportedMimeType(String mimeType) {
  return mimeType == 'application/pdf' ||
      mimeType == 'text/plain' ||
      mimeType == 'text/markdown' ||
      mimeType.startsWith('image/');
}

/// First real page provenance in the candidate's own ordered source refs.
/// Without one, the viewer opens the whole document; page numbers are never
/// guessed from question numbers or positions.
int? _pageHintOf(SupplementalAnswerOrigin origin) {
  for (final ref in origin.supplementalSourceRefs) {
    final start = ref.start;
    if (start != null) {
      return start.pageNumber;
    }
  }
  return null;
}

/// Human-readable option labels for a ChoiceAnswer. Display only: the
/// original typed answer is still what gets written.
String _choiceAnswerLabels(List<String> optionIds, QuestionDraftV2 draft) {
  final labels = <String>[];
  for (final optionId in optionIds) {
    String? label;
    for (final option in draft.options) {
      if (option.optionId == optionId) {
        label = option.label;
        break;
      }
    }
    labels.add(label ?? optionId);
  }
  return labels.join('、');
}

Widget _answerView(QuestionAnswer answer, QuestionDraftV2 draft) {
  return switch (answer) {
    ContentAnswer(:final content) => RichContentRenderer(content: content),
    ChoiceAnswer(:final optionIds) =>
      Text(_choiceAnswerLabels(optionIds, draft)),
  };
}

/// Bounded, locally scrollable content host so large stems, options, images,
/// or answers cannot stretch a review card without limit. This never changes
/// the shared renderer.
Widget _boundedReviewContent({
  required String keyName,
  required double maxHeight,
  required Widget child,
}) {
  return ConstrainedBox(
    key: ValueKey<String>(keyName),
    constraints: BoxConstraints(maxHeight: maxHeight),
    child: SingleChildScrollView(child: child),
  );
}

class _QuestionContextView extends StatelessWidget {
  const _QuestionContextView({required this.draft});

  final QuestionDraftV2 draft;

  @override
  Widget build(BuildContext context) {
    return _boundedReviewContent(
      keyName: 'supplemental-review-bounded-context',
      maxHeight: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichContentRenderer(content: draft.stem),
          for (final option in draft.options)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${option.label}. '),
                  Expanded(child: RichContentRenderer(content: option.content)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SourceVerificationSection extends StatelessWidget {
  const _SourceVerificationSection({
    required this.state,
    required this.verificationAvailable,
    required this.inspectionReady,
    required this.inspecting,
    required this.sourceUnsupported,
    required this.terminal,
    required this.onViewSource,
    required this.onConfirmVerified,
  });

  final SupplementalSourceVerificationState state;
  final bool verificationAvailable;
  final bool inspectionReady;
  final bool inspecting;
  final bool sourceUnsupported;
  final bool terminal;
  final VoidCallback onViewSource;
  final VoidCallback onConfirmVerified;

  @override
  Widget build(BuildContext context) {
    if (state == SupplementalSourceVerificationState.notRequired) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('原文核验'),
        const SizedBox(height: 4),
        const Text(
          '请对照原文件确认候选答案。文件解析结果可能存在字符识别或排版差异。'
          '打开原文件不会自动标记为已核对。',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Text(
          state == SupplementalSourceVerificationState.verified
              ? '已核对原文'
              : '待核对原文',
          style: TextStyle(
            color: state == SupplementalSourceVerificationState.verified
                ? Colors.green
                : Colors.orange,
            fontSize: 13,
          ),
        ),
        if (sourceUnsupported)
          const Text(
            '当前格式暂不支持应用内原文核验。',
            style: TextStyle(color: Colors.orange, fontSize: 13),
          )
        else if (!verificationAvailable)
          const Text(
            '原文核验不可用，无法完成原文核验确认。',
            style: TextStyle(color: Colors.orange, fontSize: 13),
          ),
        if (!terminal && verificationAvailable && !sourceUnsupported) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              OutlinedButton(
                onPressed: inspecting ? null : onViewSource,
                child: const Text('查看原文件'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed:
                    inspectionReady && !inspecting ? onConfirmVerified : null,
                child: const Text('我已对照原文件确认此候选答案'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _FillCandidateCard extends StatelessWidget {
  const _FillCandidateCard({
    required this.candidate,
    required this.selected,
    required this.outcome,
    required this.confirming,
    required this.verificationState,
    required this.verificationAvailable,
    required this.inspectionReady,
    required this.inspecting,
    required this.sourceUnsupported,
    required this.onToggle,
    required this.onViewSource,
    required this.onConfirmVerifiedSource,
    required this.onConfirm,
    required this.onReject,
  });

  final AnswerCandidate candidate;
  final bool selected;
  final CandidateReviewOutcome outcome;
  final bool confirming;
  final SupplementalSourceVerificationState verificationState;
  final bool verificationAvailable;
  final bool inspectionReady;
  final bool inspecting;
  final bool sourceUnsupported;
  final ValueChanged<bool> onToggle;
  final VoidCallback onViewSource;
  final VoidCallback onConfirmVerifiedSource;
  final VoidCallback onConfirm;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final committed = outcome == CandidateReviewOutcome.committed;
    final rejected = outcome == CandidateReviewOutcome.rejected;
    final draft = candidate.expectedDraft;
    final verified =
        verificationState == SupplementalSourceVerificationState.verified;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  draft.questionNumber != null
                      ? '第 ${draft.questionNumber} 题'
                      : '题目',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 4),
            _QuestionContextView(draft: draft),
            const SizedBox(height: 8),
            const _SectionLabel('候选答案'),
            const SizedBox(height: 4),
            _boundedReviewContent(
              keyName: 'supplemental-review-bounded-answer',
              maxHeight: 280,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _answerView(candidate.answer, draft),
              ),
            ),
            if (candidate.reviewOnlyExplanation case final explanation?) ...[
              const SizedBox(height: 8),
              const _SectionLabel('解析（仅预览，不会写入题目答案）'),
              const SizedBox(height: 4),
              _boundedReviewContent(
                keyName: 'supplemental-review-bounded-explanation',
                maxHeight: 240,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: RichContentRenderer(content: explanation),
                ),
              ),
            ],
            const SizedBox(height: 8),
            _SourceVerificationSection(
              state: verificationState,
              verificationAvailable: verificationAvailable,
              inspectionReady: inspectionReady,
              inspecting: inspecting,
              sourceUnsupported: sourceUnsupported,
              terminal: committed || rejected,
              onViewSource: onViewSource,
              onConfirmVerified: onConfirmVerifiedSource,
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
                    onChanged:
                        confirming ? null : (value) => onToggle(value ?? false),
                  ),
                  const Text('选择'),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: confirming ? null : onReject,
                    child: const Text('拒绝'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    // Disabled until the explicit source verification exists;
                    // the Application authority remains the real gate.
                    onPressed:
                        confirming || !selected || !verified ? null : onConfirm,
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
    required this.verificationState,
    required this.verificationAvailable,
    required this.inspectionReady,
    required this.inspecting,
    required this.sourceUnsupported,
    required this.replaceArmed,
    required this.onViewSource,
    required this.onConfirmVerifiedSource,
    required this.onArmReplace,
    required this.onConfirmReplace,
    required this.onReject,
  });

  final AnswerCandidate candidate;
  final CandidateReviewOutcome outcome;
  final bool confirming;
  final SupplementalSourceVerificationState verificationState;
  final bool verificationAvailable;
  final bool inspectionReady;
  final bool inspecting;
  final bool sourceUnsupported;
  final bool replaceArmed;
  final VoidCallback onViewSource;
  final VoidCallback onConfirmVerifiedSource;
  final VoidCallback onArmReplace;
  final VoidCallback onConfirmReplace;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final committed = outcome == CandidateReviewOutcome.committed;
    final rejected = outcome == CandidateReviewOutcome.rejected;
    final draft = candidate.expectedDraft;
    final verified =
        verificationState == SupplementalSourceVerificationState.verified;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  draft.questionNumber != null
                      ? '第 ${draft.questionNumber} 题'
                      : '题目',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 4),
            _QuestionContextView(draft: draft),
            const SizedBox(height: 8),
            const _SectionLabel('现有答案'),
            const SizedBox(height: 4),
            if (candidate.expectedDraft.answer case final existing?)
              _boundedReviewContent(
                keyName: 'supplemental-review-bounded-existing-answer',
                maxHeight: 280,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _answerView(existing, draft),
                ),
              ),
            const SizedBox(height: 8),
            const _SectionLabel('补充候选答案'),
            const SizedBox(height: 4),
            _boundedReviewContent(
              keyName: 'supplemental-review-bounded-answer',
              maxHeight: 280,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _answerView(candidate.answer, draft),
              ),
            ),
            if (candidate.reviewOnlyExplanation case final explanation?) ...[
              const SizedBox(height: 8),
              const _SectionLabel('解析（仅预览，不会写入题目答案）'),
              const SizedBox(height: 4),
              _boundedReviewContent(
                keyName: 'supplemental-review-bounded-explanation',
                maxHeight: 240,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: RichContentRenderer(content: explanation),
                ),
              ),
            ],
            const SizedBox(height: 8),
            _SourceVerificationSection(
              state: verificationState,
              verificationAvailable: verificationAvailable,
              inspectionReady: inspectionReady,
              inspecting: inspecting,
              sourceUnsupported: sourceUnsupported,
              terminal: committed || rejected,
              onViewSource: onViewSource,
              onConfirmVerified: onConfirmVerifiedSource,
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
                    // Verify first, then arm, then the explicit second
                    // confirmation; the Application replace authority still
                    // enforces the same order as a backstop.
                    onPressed: confirming || !verified
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

/// The user-facing trace lines, gated by the frozen OBS-1 §21 validation:
/// only a strictly valid diagnostic id and a safe trace token are rendered
/// or copied; anything else is omitted.
List<String> _traceLines(String? correlationId, String? traceId) {
  return <String>[
    if (correlationId != null &&
        DiagnosticSummaryFormatter.isValidDiagnosticId(correlationId))
      '诊断编号：$correlationId',
    if (traceId != null && DiagnosticSummaryFormatter.isSafeToken(traceId))
      'Trace ID：$traceId',
  ];
}

class _SupplementalTraceBanner extends StatelessWidget {
  const _SupplementalTraceBanner({
    required this.correlationId,
    required this.traceId,
    required this.onCopy,
  });

  final String? correlationId;
  final String? traceId;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final lines = _traceLines(correlationId, traceId);
    if (lines.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey<String>('supplemental-answer-trace-info'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.tag, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              lines.join('\n'),
              key: const ValueKey<String>('supplemental-answer-trace-ids'),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          IconButton(
            key: const ValueKey<String>('supplemental-answer-copy-trace'),
            tooltip: '复制诊断信息',
            onPressed: onCopy,
            icon: const Icon(Icons.copy, size: 18),
          ),
        ],
      ),
    );
  }
}
