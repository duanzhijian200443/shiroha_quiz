import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../application/import/import_advanced_preferences.dart';
import '../../application/questions/folder_query_port.dart';
import '../../services/bank_update_notifier.dart';
import '../../services/import_pipeline/import_question_field_policy.dart';
import '../../services/import_pipeline/subjective_answer_distillation_service.dart';
import '../../services/import_review/import_commit_service.dart';
import '../../services/import_review/import_review_item.dart';
import '../../services/import_review/import_review_report_formatter.dart';
import '../../services/import_review/review_repair_service.dart';
import '../../services/task_manager.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../import_review/dialogs/import_review_change_type_dialog.dart';
import '../import_review/dialogs/import_review_explanation_edit_dialog.dart';
import '../import_review/dialogs/import_review_quality_dialog.dart';
import '../import_review/dialogs/import_review_save_dialog.dart';
import '../import_review/dialogs/import_review_success_report_dialog.dart';
import '../import_review/import_review_controller.dart';
import '../import_review/import_review_view_state.dart';
import '../import_review/widgets/import_review_commit_bar.dart';
import '../import_review/widgets/import_review_diagnostics.dart';
import '../import_review/widgets/import_review_distillation_bar.dart';
import '../import_review/widgets/import_review_question_list.dart';
import '../import_review/widgets/import_review_selection_bar.dart';
import '../import_review/widgets/import_review_summary_bar.dart';
import '../import_review/widgets/import_review_toolbar.dart';
import '../widgets/review_repair_proposal_dialog.dart';

class ImportStagingScreen extends StatefulWidget {
  final List<Map<String, dynamic>> parsedQuestions;
  final String? taskId;
  final List<String>? warnings;
  final Map<String, dynamic>? diagnostics;
  final FolderQueryPort? folderQuery;
  final ImportCommitService? commitService;
  final SubjectiveAnswerDistiller? answerDistiller;
  final ReviewRepairGenerator? reviewRepairGenerator;
  final ImportAdvancedPreferencesLoader? importPreferencesLoader;
  final TaskManager? taskManager;
  final ExplanationRetentionMode initialExplanationRetentionMode;

  const ImportStagingScreen({
    super.key,
    required this.parsedQuestions,
    this.taskId,
    this.warnings,
    this.diagnostics,
    this.folderQuery,
    this.commitService,
    this.answerDistiller,
    this.reviewRepairGenerator,
    this.importPreferencesLoader,
    this.taskManager,
    this.initialExplanationRetentionMode =
        ExplanationRetentionMode.subjectiveOnly,
  });

  @override
  State<ImportStagingScreen> createState() => _ImportStagingScreenState();
}

class _ImportStagingScreenState extends State<ImportStagingScreen> {
  late final ImportReviewController _controller;

  final TextEditingController _bankNameController = TextEditingController();
  final TextEditingController _folderController = TextEditingController();
  bool _autoRepairInitialized = false;

  /// The page renders from this immutable presentation state and forwards
  /// every user event to [_controller]; it owns no business state itself.
  ImportReviewViewState get _state => _controller.state;

  @override
  void initState() {
    super.initState();
    _controller = ImportReviewController(
      parsedQuestions: widget.parsedQuestions,
      taskId: widget.taskId,
      warnings: widget.warnings,
      diagnostics: widget.diagnostics,
      folderQuery: widget.folderQuery,
      commitService: widget.commitService,
      answerDistiller: widget.answerDistiller,
      reviewRepairGenerator: widget.reviewRepairGenerator,
      taskManager: widget.taskManager,
      initialExplanationRetentionMode: widget.initialExplanationRetentionMode,
      answerDistillerFactory: () => SubjectiveAnswerDistillationService(
        engineRepository: AiDependenciesScope.of(context).engineRepository,
      ),
      repairGeneratorFactory: () => ReviewRepairService(
        engineRepository: AiDependenciesScope.of(context).engineRepository,
      ),
      effects: _buildEffects(),
    );
    final needsFollowUpPersist = _controller.initialize();
    _controller.addListener(_handleControllerChanged);
    if (needsFollowUpPersist) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_controller.persistReviewDraft());
      });
    }
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  /// Binds the controller's outcomes to this page's presentation primitives.
  ///
  /// The controller decides what happened; the page decides how it is shown.
  /// Every handler re-checks [mounted] before touching build-context UI.
  ImportReviewEffects _buildEffects() {
    return ImportReviewEffects(
      showMessage: (message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      },
      showError: (message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(message),
          backgroundColor: Colors.redAccent,
        ));
      },
      confirmRepairProposal: (proposal) async {
        if (!mounted) return false;
        return showDialog<bool>(
          context: context,
          builder: (context) => ReviewRepairProposalDialog(proposal: proposal),
        );
      },
      showCommitSuccess: (report, bankName, folderName) {
        // 触发全局题库刷新事件
        globalBankUpdateNotifier.value++;

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('🎉 导入成功！'), backgroundColor: Colors.green));

        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => ImportReviewSuccessReportDialog(
            report: report,
            bankName: bankName,
            folderName: folderName,
            onDone: () => Navigator.pop(context),
          ),
        );
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_autoRepairInitialized) return;
    _autoRepairInitialized = true;
    final loader = widget.importPreferencesLoader ??
        context
            .dependOnInheritedWidgetOfExactType<AiDependenciesScope>()
            ?.importPreferencesLoader;
    if (loader == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_controller.initializeAutoLatexRepair(loader));
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _copyTraceId() async {
    final traceId = _controller.traceId;
    if (traceId == null) return;
    await Clipboard.setData(ClipboardData(text: traceId));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Trace ID 已复制')),
    );
  }

  void _validateBeforeSave() {
    if (_controller.isBlockedByQualityGate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('解析不完整，禁止入库'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    if (_state.allItems.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title:
              const Text('提示', style: TextStyle(fontWeight: FontWeight.bold)),
          content: const Text('当前没有可入库题目'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }

    final report = _controller.buildCommitReport();

    if (report.qualityScore < 60) {
      showDialog(
        context: context,
        builder: (_) => ImportReviewQualityDialog(
          title: '提取质量不佳',
          message: ImportReviewReportFormatter.formatDialogSummary(report),
          cancelLabel: '返回检查',
          confirmLabel: '仍然继续',
          confirmIsDanger: true,
          onContinue: _showSaveDialog,
        ),
      );
    } else if (report.errorCount > 0) {
      showDialog(
        context: context,
        builder: (_) => ImportReviewQualityDialog(
          title: '仍有严重问题',
          message: ImportReviewReportFormatter.formatDialogSummary(report),
          cancelLabel: '返回检查',
          confirmLabel: '仍然继续',
          confirmIsDanger: true,
          onContinue: _showSaveDialog,
        ),
      );
    } else if (report.warningCount > 0 || report.infoCount > 0) {
      showDialog(
        context: context,
        builder: (_) => ImportReviewQualityDialog(
          title: '普通确认摘要',
          message: ImportReviewReportFormatter.formatDialogSummary(report),
          cancelLabel: '取消',
          confirmLabel: '继续',
          confirmIsDanger: false,
          onContinue: _showSaveDialog,
        ),
      );
    } else {
      _showSaveDialog();
    }
  }

  void _deleteSelectedWithConfirm() {
    if (_state.isSaving) return;
    if (_state.selectedOriginalIndices.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除选中题目'),
        content: Text(
            '将删除 ${_state.selectedOriginalIndices.length} 道题，此操作仅影响本次导入暂存列表。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              _controller.deleteSelected();
            },
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }

  void _showChangeTypeDialog() {
    if (_state.selectedOriginalIndices.isEmpty) return;
    showDialog(
      context: context,
      builder: (_) => ImportReviewChangeTypeDialog(
        onTypeSelected: _controller.changeSelectedType,
      ),
    );
  }

  void _showSaveDialog() {
    final frozen = _controller.frozenDocumentTarget;
    if (frozen != null) {
      _confirmAndSave(frozen.bankName!, frozen.folderName ?? '');
      return;
    }
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => ImportReviewSaveDialog(
              bankNameController: _bankNameController,
              folderController: _folderController,
              existingFolders: _state.existingFolders,
              onInvalidBankName: () {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('请先输入目标题库名称')));
              },
              onConfirm: _confirmAndSave,
            ));
  }

  Future<void> _confirmAndSave(String bankName, String folderName) async {
    if (_controller.isBlockedByQualityGate) return;

    if (_state.allItems.isEmpty) {
      Navigator.pop(context);
      return;
    }

    await _controller.commit(bankName: bankName, folderName: folderName);
  }

  /// Opens the explanation editor for one review item.
  ///
  /// The field is seeded with the text the reviewer is currently looking at, so
  /// editing starts from what was rendered. Saving keeps the entered value as
  /// literal text and marks the explanation manually edited; dismissing the
  /// dialog without changing anything is not an edit and leaves the typed
  /// structure and its provenance untouched.
  Future<void> _editExplanation(ImportReviewItem item) async {
    if (_state.isSaving) return;
    final seed = _controller.explanationEditorSeed(item);
    final edited = await showDialog<String>(
      context: context,
      builder: (_) => ImportReviewExplanationEditDialog(initialText: seed),
    );
    if (edited == null || !mounted) return;
    // An edit means "did this interaction change what the editor was seeded
    // with". Comparing against the stored legacy text instead would misfire on
    // exactly the payload this contract exists for: the typed projection and
    // the legacy text are different representations, so a no-op save would look
    // like an edit and permanently flatten the structure.
    if (edited == seed) return;
    _controller.saveManualExplanationEdit(item, edited);
  }

  /// The document-level retention switch for tasks persisted before document
  /// import fixed the policy.
  ///
  /// New imports retain every recognized explanation, so they expose no
  /// document-level switch: the user edits or deletes explanations per question
  /// on the review card instead.
  Widget _buildExplanationRetentionControl() {
    return SwitchListTile.adaptive(
      key: const ValueKey('objective-explanation-document-switch'),
      value: _state.explanationRetentionMode ==
          ExplanationRetentionMode.allQuestionTypes,
      onChanged:
          _state.isSaving ? null : _controller.setDocumentExplanationRetention,
      title: const Text(
        '同时导入选择题、填空题解析',
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: const Text(
        '开启后保留选择题和填空题的已识别解析，可能增加需要校对的内容。',
        style: TextStyle(fontSize: 12),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }

  /// Opens the diagnostics bottom sheet. The sheet content lives in
  /// [ImportReviewDiagnosticsSheet]; this method only owns the route.
  void _showDiagnosticsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ImportReviewDiagnosticsSheet(
        messages: _state.diagnosticMessages,
        diagnostics: widget.diagnostics,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
            _state.selectionMode
                ? '已选 ${_state.selectedOriginalIndices.length} 题'
                : '解析结果校对',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        leading: _state.selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _controller.exitSelectionMode,
              )
            : null,
        actions: [
          if (!_state.selectionMode)
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: '批量操作',
              onPressed:
                  _state.isSaving ? null : _controller.enterSelectionMode,
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.orangeAccent.withValues(alpha: 0.1),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orangeAccent, size: 20),
                SizedBox(width: 8),
                Expanded(
                    child: Text('请核对 AI 解析结果。向左滑动卡片可删除识别错误的废题。',
                        style: TextStyle(
                            color: Colors.orangeAccent, fontSize: 13))),
              ],
            ),
          ),
          if (_controller.traceId != null)
            ImportReviewTraceBar(
              traceId: _controller.traceId!,
              onCopy: _copyTraceId,
            ),
          if (_controller.frozenDocumentTarget case final target?)
            ListTile(
              key: const ValueKey<String>('review-frozen-target'),
              title: const Text('导入到'),
              subtitle: Text(target.folderName?.trim().isNotEmpty == true
                  ? '${target.folderName} / ${target.bankName}'
                  : target.bankName!),
            ),
          if (_state.diagnosticMessages.isNotEmpty)
            ImportReviewDiagnosticsBanner(
              messages: _state.diagnosticMessages,
              onShowDetails: _showDiagnosticsSheet,
            ),
          if (_controller.hasLowQualityVision)
            ImportReviewVisionLowQualityBanner(diagnostics: widget.diagnostics),
          if (_controller.hasUnsupportedStructure)
            ImportReviewUnsupportedStructureBanner(
                diagnostics: widget.diagnostics),
          // Document import fixes retention, so only compatibility tasks keep
          // the document-level switch.
          if (!_state.isDocumentImportEntryTask)
            _buildExplanationRetentionControl(),
          ImportReviewDistillationBar(
            candidateCount: _controller.answerDistillationCandidateCount,
            isDistillingAnswers: _state.isDistillingAnswers,
            cancellationRequested:
                _state.answerDistillationCancellationRequested,
            completedCount: _state.answerDistillationCompletedCount,
            totalCount: _state.answerDistillationTotalCount,
            isSaving: _state.isSaving,
            onGenerateAll: _controller.distillAllAnswers,
            onCancel: _controller.cancelAnswerDistillation,
          ),
          const Divider(height: 1),
          ImportReviewSummaryBar(summary: _state.reviewResult.summary),
          const Divider(height: 1),
          ImportReviewToolbar(
            activeFilter: _state.activeFilter,
            activeSort: _state.activeSort,
            filterCounts: _controller.filterCounts,
            visibleItemCount: _state.visibleItems.length,
            onFilterChanged: _controller.setFilter,
            onSortChanged: _controller.setSort,
          ),
          const Divider(height: 1),
          Expanded(
            child: ImportReviewQuestionList(
              state: _state,
              isQuestionExplanationRetained:
                  _controller.isQuestionExplanationRetained,
              isAnswerDistillationCandidate:
                  _controller.isAnswerDistillationCandidate,
              isReviewRepairEligible: _controller.isReviewRepairEligible,
              onToggleSelection: _controller.toggleSelection,
              onRemoveItem: _controller.removeReviewItem,
              onEditExplanation: _editExplanation,
              onExplanationRetentionChanged:
                  _controller.setQuestionExplanationRetention,
              onDistillAnswer: _controller.distillSingleAnswer,
              onReviewRepair: _controller.requestReviewRepair,
            ),
          ),
        ],
      ),
      bottomNavigationBar: _state.selectionMode
          ? ImportReviewSelectionBar(
              selectedCount: _state.selectedOriginalIndices.length,
              isSaving: _state.isSaving,
              onSelectAllVisible: _controller.selectAllVisible,
              onChangeType: _showChangeTypeDialog,
              onDeleteSelected: _deleteSelectedWithConfirm,
            )
          : ImportReviewCommitBar(
              itemCount: _state.allItems.length,
              isSaving: _state.isSaving,
              isBlockedByQualityGate: _controller.isBlockedByQualityGate,
              isDistillingAnswers: _state.isDistillingAnswers,
              blockedLabel: _controller.confirmButtonText,
              onCommit: _validateBeforeSave,
            ),
    );
  }
}
