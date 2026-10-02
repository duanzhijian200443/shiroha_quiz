import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../application/questions/folder_query_port.dart';
import '../../application/import_review/typed_review_snapshot.dart';
import '../../application/import/import_advanced_preferences.dart';
import '../../services/task_manager.dart';
import '../../services/import_pipeline/import_diagnostic_message.dart';
import '../../services/import_pipeline/import_question_field_policy.dart';
import '../../services/import_pipeline/subjective_answer_distillation_service.dart';
import '../../services/import_review/import_review_item.dart';
import '../../services/import_review/import_review_issue.dart';
import '../../services/import_review/import_review_badge_formatter.dart';
import '../../services/import_review/import_review_filter.dart';
import '../../services/import_review/import_review_metadata.dart';
import '../../services/import_review/import_review_report_formatter.dart';
import '../../services/import_review/import_commit_service.dart';
import '../../services/import_review/explanation_edit_provenance.dart';
import '../../services/import_review/review_legacy_field_content.dart';
import '../../services/import_review/review_repair_service.dart';
import '../../services/bank_update_notifier.dart';
import '../../data/models/question_draft.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../import_review/import_review_controller.dart';
import '../import_review/import_review_view_state.dart';
import '../widgets/markdown_extensions.dart';
import '../widgets/review_repair_proposal_dialog.dart';
import '../widgets/structured_content_renderer.dart';

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
          builder: (ctx) {
            return AlertDialog(
              title: const Text('本次导入报告',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: SelectableText(
                    ImportReviewReportFormatter.formatSuccessReport(
                        report, bankName, folderName),
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  ),
                ),
              ),
              actions: [
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('完成'),
                ),
              ],
            );
          },
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
        builder: (ctx) => AlertDialog(
          title: const Text('提取质量不佳',
              style: TextStyle(fontWeight: FontWeight.bold)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content:
              Text(ImportReviewReportFormatter.formatDialogSummary(report)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('返回检查', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _showSaveDialog();
              },
              child: const Text('仍然继续'),
            ),
          ],
        ),
      );
    } else if (report.errorCount > 0) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('仍有严重问题',
              style: TextStyle(fontWeight: FontWeight.bold)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content:
              Text(ImportReviewReportFormatter.formatDialogSummary(report)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('返回检查', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _showSaveDialog();
              },
              child: const Text('仍然继续'),
            ),
          ],
        ),
      );
    } else if (report.warningCount > 0 || report.infoCount > 0) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('普通确认摘要',
              style: TextStyle(fontWeight: FontWeight.bold)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content:
              Text(ImportReviewReportFormatter.formatDialogSummary(report)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _showSaveDialog();
              },
              child: const Text('继续'),
            ),
          ],
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
      builder: (ctx) => AlertDialog(
        title: const Text('批量修改题型'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('选择题'),
              leading: const Icon(Icons.radio_button_checked),
              onTap: () {
                Navigator.pop(ctx);
                _controller.changeSelectedType(QuestionType.singleChoice);
              },
            ),
            ListTile(
              title: const Text('填空题'),
              leading: const Icon(Icons.space_bar),
              onTap: () {
                Navigator.pop(ctx);
                _controller.changeSelectedType(QuestionType.fillBlank);
              },
            ),
            ListTile(
              title: const Text('简答题'),
              leading: const Icon(Icons.notes),
              onTap: () {
                Navigator.pop(ctx);
                _controller.changeSelectedType(QuestionType.shortAnswer);
              },
            ),
          ],
        ),
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
        builder: (ctx) {
          return StatefulBuilder(builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('选择保存位置',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                        controller: _bankNameController,
                        decoration: InputDecoration(
                            labelText: '目标题库名称',
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8)))),
                    const SizedBox(height: 16),
                    TextField(
                        controller: _folderController,
                        decoration: InputDecoration(
                            labelText: '所属学科分类 (选填)',
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8)))),
                    if (_state.existingFolders.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8.0,
                        runSpacing: 8.0,
                        children: _state.existingFolders
                            .map((folder) => ActionChip(
                                  label: Text(folder,
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.blueAccent)),
                                  backgroundColor: Colors.blue.shade50,
                                  side: BorderSide.none,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16)),
                                  onPressed: () {
                                    setDialogState(() {
                                      _folderController.text = folder;
                                    });
                                  },
                                ))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () {
                    final bankName = _bankNameController.text.trim();
                    if (bankName.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请先输入目标题库名称')));
                      return;
                    }
                    Navigator.pop(ctx);
                    _confirmAndSave(bankName, _folderController.text.trim());
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('确定入库'),
                ),
              ],
            );
          });
        });
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
      builder: (_) => _ExplanationEditDialog(initialText: seed),
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

  Widget _buildToolbar() {
    final theme = Theme.of(context);
    final counts = _controller.filterCounts;

    String getFilterLabel(ImportReviewFilter filter) {
      switch (filter) {
        case ImportReviewFilter.all:
          return '全部';
        case ImportReviewFilter.errorsOnly:
          return '严重';
        case ImportReviewFilter.warningsOnly:
          return '警告';
        case ImportReviewFilter.missingAnswer:
          return '缺答案';
        case ImportReviewFilter.choiceIssues:
          return '选择题';
        case ImportReviewFilter.fusionRisks:
          return '融合风险';
        case ImportReviewFilter.answerConflict:
          return '答案冲突';
        case ImportReviewFilter.orphanOrAnswerOnly:
          return '孤立/仅答案';
        case ImportReviewFilter.visionOnly:
          return '视觉';
        case ImportReviewFilter.fused:
          return '图文融合';
      }
    }

    String getSortLabel(ImportReviewSort sort) {
      switch (sort) {
        case ImportReviewSort.originalOrder:
          return '原始顺序';
        case ImportReviewSort.riskFirst:
          return '风险优先';
        case ImportReviewSort.missingFieldsFirst:
          return '缺失优先';
        case ImportReviewSort.sourceRiskFirst:
          return '来源风险优先';
      }
    }

    return Container(
      color: theme.cardColor,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: ImportReviewFilter.values.map((filter) {
                final count = counts[filter] ?? 0;
                final isSelected = _state.activeFilter == filter;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: FilterChip(
                    label: Text('${getFilterLabel(filter)} $count'),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        _controller.setFilter(filter);
                      }
                    },
                    selectedColor: theme.primaryColor.withValues(alpha: 0.2),
                    checkmarkColor: theme.primaryColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: isSelected
                            ? theme.primaryColor
                            : Colors.grey.shade300,
                      ),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  ),
                );
              }).toList(),
            ),
          ),
          const Divider(height: 8, thickness: 0.5),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '已筛选出 ${_state.visibleItems.length} 道题',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                PopupMenuButton<ImportReviewSort>(
                  initialValue: _state.activeSort,
                  onSelected: (sort) {
                    _controller.setSort(sort);
                  },
                  itemBuilder: (context) => ImportReviewSort.values.map((sort) {
                    return PopupMenuItem<ImportReviewSort>(
                      value: sort,
                      child: Text(getSortLabel(sort)),
                    );
                  }).toList(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.sort, size: 16, color: theme.primaryColor),
                      const SizedBox(width: 4),
                      Text(
                        getSortLabel(_state.activeSort),
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.primaryColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showDiagnosticsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '导入诊断详情',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).textTheme.titleLarge?.color,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (widget.diagnostics != null &&
                widget.diagnostics!.containsKey('rawTextPreview')) ...[
              _buildRawTextPreviewCard(context),
              const SizedBox(height: 16),
            ],
            Expanded(
              child: ListView.separated(
                itemCount: _state.diagnosticMessages.length,
                separatorBuilder: (_, __) => const Divider(height: 16),
                itemBuilder: (context, index) {
                  final msg = _state.diagnosticMessages[index];
                  IconData icon;
                  Color color;
                  switch (msg.severity) {
                    case ImportDiagnosticSeverity.error:
                      icon = Icons.error_outline_rounded;
                      color = Colors.redAccent;
                      break;
                    case ImportDiagnosticSeverity.warning:
                      icon = Icons.warning_amber_rounded;
                      color = Colors.orange;
                      break;
                    case ImportDiagnosticSeverity.info:
                      icon = Icons.info_outline_rounded;
                      color = Colors.blueAccent;
                      break;
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, color: color, size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              msg.title,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: color,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              msg.message,
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.color,
                                height: 1.4,
                              ),
                            ),
                            if (msg.source != null || msg.code != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                '${msg.source != null ? "来源: ${msg.source}" : ""}'
                                '${msg.source != null && msg.code != null ? " | " : ""}'
                                '${msg.code != null ? "代码: ${msg.code}" : ""}',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryBar() {
    final summary = _state.reviewResult.summary;
    Color scoreColor;
    if (summary.qualityScore >= 80) {
      scoreColor = Colors.green;
    } else if (summary.qualityScore >= 60) {
      scoreColor = Colors.orange;
    } else {
      scoreColor = Colors.redAccent;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Theme.of(context).cardColor,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scoreColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Text(
              '${summary.qualityScore}',
              style: TextStyle(
                color: scoreColor,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '质量摘要 (共 ${summary.totalCount} 题)',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  '错误: ${summary.errorCount} | 警告: ${summary.warningCount} | 缺答案: ${summary.missingAnswerCount}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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

  Widget _buildAnswerDistillationControl() {
    final candidateCount = _controller.answerDistillationCandidateCount;
    if (candidateCount == 0 && !_state.isDistillingAnswers) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.primaryColor.withValues(alpha: 0.05),
      child: Row(
        children: [
          Icon(Icons.auto_awesome_outlined,
              size: 20, color: theme.primaryColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _state.isDistillingAnswers
                      ? '正在生成答案 ${_state.answerDistillationCompletedCount}/${_state.answerDistillationTotalCount}'
                      : '可用解析补全 $candidateCount 道主观题标准答案',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Text(
                  '仅依据已有解析提取简洁答案，不会重新解题。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_state.isDistillingAnswers)
            TextButton(
              key: const ValueKey('answer-distillation-cancel'),
              onPressed: _state.answerDistillationCancellationRequested
                  ? null
                  : _controller.cancelAnswerDistillation,
              child: const Text('停止生成'),
            )
          else
            FilledButton(
              key: const ValueKey('answer-distillation-batch'),
              onPressed: _state.isSaving ? null : _controller.distillAllAnswers,
              child: Text('补全 $candidateCount 道'),
            ),
        ],
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
          if (_controller.traceId != null) _buildTraceBar(),
          if (_controller.frozenDocumentTarget case final target?)
            ListTile(
              key: const ValueKey<String>('review-frozen-target'),
              title: const Text('导入到'),
              subtitle: Text(target.folderName?.trim().isNotEmpty == true
                  ? '${target.folderName} / ${target.bankName}'
                  : target.bankName!),
            ),
          if (_state.diagnosticMessages.isNotEmpty) ...[
            _buildDiagnosticBanner(),
          ],
          if (_controller.hasLowQualityVision) _buildVisionLowQualityBanner(),
          if (_controller.hasUnsupportedStructure)
            _buildUnsupportedStructureBanner(),
          // Document import fixes retention, so only compatibility tasks keep
          // the document-level switch.
          if (!_state.isDocumentImportEntryTask)
            _buildExplanationRetentionControl(),
          _buildAnswerDistillationControl(),
          const Divider(height: 1),
          _buildSummaryBar(),
          const Divider(height: 1),
          _buildToolbar(),
          const Divider(height: 1),
          Expanded(
            child: _state.allItems.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.delete_outline,
                          size: 48,
                          color: Colors.grey.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '所有题目已被删除',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                : (_state.visibleItems.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.filter_list_off,
                              size: 48,
                              color: Colors.grey.withValues(alpha: 0.5),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '当前筛选下没有题目',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _state.visibleItems.length,
                        itemBuilder: (context, index) {
                          final visibleItem = _state.visibleItems[index];
                          final item = visibleItem.item;
                          return Dismissible(
                            key: ValueKey(item.originalIndex),
                            direction: (_state.selectionMode || _state.isSaving)
                                ? DismissDirection.none
                                : DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              color: Colors.redAccent,
                              child: const Icon(Icons.delete_sweep,
                                  color: Colors.white),
                            ),
                            onDismissed: (direction) {
                              _controller.removeReviewItem(item);
                            },
                            child: Row(
                              children: [
                                if (_state.selectionMode)
                                  Checkbox(
                                    value: _state.selectedOriginalIndices
                                        .contains(item.originalIndex),
                                    onChanged: (val) {
                                      _controller.toggleSelection(item);
                                    },
                                  ),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: _state.selectionMode
                                        ? () =>
                                            _controller.toggleSelection(item)
                                        : null,
                                    child: _QuestionCard(
                                      item: item,
                                      snapshot: _state.presentationSnapshots[
                                          item.originalIndex],
                                      index: visibleItem.canonicalIndex,
                                      issues: visibleItem.issues,
                                      explanationRetained: _controller
                                          .isQuestionExplanationRetained(item),
                                      onEditExplanation:
                                          (_state.selectionMode ||
                                                  _state.isSaving)
                                              ? null
                                              : () => _editExplanation(item),
                                      explanationProvenance:
                                          _state.explanationProvenance[
                                                  item.originalIndex] ??
                                              ExplanationEditProvenance
                                                  .legacyUnknown,
                                      onExplanationRetentionChanged: (_state
                                                  .selectionMode ||
                                              _state.isSaving ||
                                              _state.isDocumentImportEntryTask)
                                          ? null
                                          : (retain) => _controller
                                                  .setQuestionExplanationRetention(
                                                item,
                                                retain,
                                              ),
                                      answerDistillationCandidate: _controller
                                          .isAnswerDistillationCandidate(item),
                                      answerDistillationStatus:
                                          _state.answerDistillationStatuses[
                                              item.originalIndex],
                                      proofExplanationRecognized:
                                          _state.answerDistillationStatuses[
                                                  item.originalIndex] ==
                                              'proof_explanation_recognized',
                                      answerDistillationInProgress: _state
                                              .activeAnswerDistillationIndex ==
                                          item.originalIndex,
                                      onAnswerDistillation:
                                          _state.selectionMode ||
                                                  _state.isSaving ||
                                                  _state.activeRepairIndex !=
                                                      null ||
                                                  _state.isDistillingAnswers
                                              ? null
                                              : () => _controller
                                                  .distillSingleAnswer(item),
                                      reviewRepairEligible: _controller
                                          .isReviewRepairEligible(item),
                                      reviewRepairInProgress:
                                          _state.activeRepairIndex ==
                                              item.originalIndex,
                                      reviewRepairProposalReady: _state
                                          .autoRepairProposalIndices
                                          .contains(item.originalIndex),
                                      onReviewRepair: _state.selectionMode ||
                                              _state.isSaving ||
                                              _state.isDistillingAnswers ||
                                              _state.activeRepairIndex != null
                                          ? null
                                          : () => _controller
                                              .requestReviewRepair(item),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      )),
          ),
        ],
      ),
      bottomNavigationBar: _state.selectionMode
          ? SafeArea(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black12,
                        blurRadius: 4,
                        offset: Offset(0, -2))
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.select_all),
                      label: const Text('全选当前'),
                      onPressed: _controller.selectAllVisible,
                    ),
                    Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.edit),
                          label: const Text('改题型'),
                          onPressed: (_state.selectedOriginalIndices.isEmpty ||
                                  _state.isSaving)
                              ? null
                              : _showChangeTypeDialog,
                        ),
                        TextButton.icon(
                          icon:
                              const Icon(Icons.delete, color: Colors.redAccent),
                          label: const Text('删除',
                              style: TextStyle(color: Colors.redAccent)),
                          onPressed: (_state.selectedOriginalIndices.isEmpty ||
                                  _state.isSaving)
                              ? null
                              : _deleteSelectedWithConfirm,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: _controller.isBlockedByQualityGate
                        ? Colors.grey
                        : theme.primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: _state.isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : (_controller.isBlockedByQualityGate
                          ? const Icon(Icons.block)
                          : const Icon(Icons.check_circle_outline)),
                  label: Text(
                      _controller.isBlockedByQualityGate
                          ? _controller.confirmButtonText
                          : (_state.isSaving
                              ? '正在入库...'
                              : '确认无误，将 ${_state.allItems.length} 题收入题库'),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  onPressed: (_state.isSaving ||
                          _controller.isBlockedByQualityGate ||
                          _state.isDistillingAnswers)
                      ? null
                      : _validateBeforeSave,
                ),
              ),
            ),
    );
  }

  Widget _buildDiagnosticBanner() {
    // The original diagnostic banner logic extracted from inline in build().
    // Moved to a separate method so new banners (like vision low quality) can
    // live alongside it without nesting.
    return Builder(builder: (context) {
      final hasError = _state.diagnosticMessages
          .any((m) => m.severity == ImportDiagnosticSeverity.error);
      final hasWarning = _state.diagnosticMessages
          .any((m) => m.severity == ImportDiagnosticSeverity.warning);

      Color bannerBg;
      Color textAndIconColor;
      IconData bannerIcon;
      String bannerTitle;

      if (hasError) {
        bannerBg = Colors.redAccent.withValues(alpha: 0.1);
        textAndIconColor = Colors.redAccent;
        bannerIcon = Icons.error_outline_rounded;
        bannerTitle = '解析发生严重错误';
      } else if (hasWarning) {
        bannerBg = Colors.orangeAccent.withValues(alpha: 0.12);
        textAndIconColor = Colors.orange;
        bannerIcon = Icons.warning_amber_rounded;
        bannerTitle = '解析有注意事项';
      } else {
        bannerBg = Colors.blueAccent.withValues(alpha: 0.08);
        textAndIconColor = Colors.blueAccent;
        bannerIcon = Icons.info_outline_rounded;
        bannerTitle = '包含解析报告';
      }

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        color: bannerBg,
        child: Row(
          children: [
            Icon(bannerIcon, color: textAndIconColor, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$bannerTitle (${_state.diagnosticMessages.length} 条记录)',
                style: TextStyle(
                  color: textAndIconColor,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            TextButton(
              onPressed: () => _showDiagnosticsSheet(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                foregroundColor: textAndIconColor,
              ),
              child: const Row(
                children: [
                  Text('查看详情',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  Icon(Icons.arrow_right, size: 16),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildTraceBar() {
    final traceId = _controller.traceId!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).primaryColor.withValues(alpha: 0.06),
      child: Row(
        children: [
          Icon(Icons.hub_outlined,
              color: Theme.of(context).primaryColor, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              '导入追踪：$traceId',
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
          IconButton(
            key: const ValueKey('copy-staging-trace'),
            onPressed: _copyTraceId,
            icon: const Icon(Icons.copy_rounded, size: 18),
            tooltip: '复制 Trace ID',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildVisionLowQualityBanner() {
    final summary = widget.diagnostics?['visionQualitySummary'];
    if (summary is! Map) return const SizedBox.shrink();
    final issueSummary = _formatVisionIssueCounts(summary['issueCounts']);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.red.shade50,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.visibility_off, color: Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '视觉解析质量偏低',
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '建议人工复核，或切换更强视觉模型后重新导入。'
                  '风险题数：${summary['riskyCount'] ?? 0} / ${summary['total'] ?? 0}',
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12,
                  ),
                ),
                if (issueSummary != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    issueSummary,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnsupportedStructureBanner() {
    final summary = widget.diagnostics?['unsupportedStructureSummary'];
    final imageBlockCount = summary is Map ? summary['imageBlockCount'] : null;
    final tableBlockCount = summary is Map ? summary['tableBlockCount'] : null;
    final hasImage = imageBlockCount is int && imageBlockCount > 0;
    final hasTable = tableBlockCount is int && tableBlockCount > 0;
    final message = hasImage && hasTable
        ? '检测到图片和表格内容，当前版本尚不能完整呈现，请对照 PDF 校对。'
        : hasImage
            ? '检测到图片内容，但当前版本尚不能显示原图，请对照 PDF 校对。'
            : '检测到表格内容，当前可能以文本或 HTML 片段显示，请对照 PDF 校对。';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.orangeAccent.withValues(alpha: 0.12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.orange, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  String? _formatVisionIssueCounts(dynamic rawCounts) {
    if (rawCounts is! Map || rawCounts.isEmpty) return null;
    final entries = <MapEntry<String, int>>[];
    for (final entry in rawCounts.entries) {
      final count = _readPositiveInt(entry.value);
      if (count <= 0) continue;
      entries.add(MapEntry(entry.key.toString(), count));
    }
    if (entries.isEmpty) return null;

    entries.sort((a, b) => b.value.compareTo(a.value));
    final visible = entries.take(3).map((entry) {
      return '${_visionIssueLabel(entry.key)} ${entry.value}';
    }).join('，');
    return '主要风险：$visible';
  }

  int _readPositiveInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  String _visionIssueLabel(String code) {
    return switch (code) {
      'answer_leaked_to_content' => '答案混入题干',
      'missing_answer_or_explanation' => '缺少答案/解析',
      'type_options_mismatch' => '题型选项不匹配',
      'duplicate_q_num' => '重复题号',
      'q_num_drift' => '题号漂移',
      _ => code,
    };
  }

  // Replaced by _buildDiagnosticBanner() and _buildVisionLowQualityBanner().
  // _buildRawTextPreviewCard is used only from _showDiagnosticsSheet.

  Widget _buildRawTextPreviewCard(BuildContext context) {
    final theme = Theme.of(context);
    final rawText = widget.diagnostics!['rawTextPreview'] as String;
    final length = widget.diagnostics!['rawTextLength'] ?? rawText.length;
    final lineCount =
        widget.diagnostics!['rawTextLineCount'] ?? rawText.split('\n').length;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.primaryColor.withValues(alpha: 0.2)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.description_outlined,
                      color: theme.primaryColor, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '原始提取文本 (DOCX)',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: theme.textTheme.titleMedium?.color,
                    ),
                  ),
                ],
              ),
              ElevatedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: rawText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制原始文本预览到剪贴板'),
                      backgroundColor: Colors.green,
                    ),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 14),
                label: const Text('复制原始文本预览'),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: const Size(0, 28),
                  textStyle: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.bold),
                  backgroundColor: theme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '字符数: $length | 行数: $lineCount',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Container(
            height: 100,
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.brightness == Brightness.dark
                  ? Colors.black26
                  : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                rawText,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Colors.grey,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.item,
    this.snapshot,
    required this.index,
    required this.issues,
    required this.explanationRetained,
    required this.explanationProvenance,
    required this.onExplanationRetentionChanged,
    required this.onEditExplanation,
    required this.answerDistillationCandidate,
    required this.answerDistillationStatus,
    required this.proofExplanationRecognized,
    required this.answerDistillationInProgress,
    required this.onAnswerDistillation,
    required this.reviewRepairEligible,
    required this.reviewRepairInProgress,
    required this.reviewRepairProposalReady,
    required this.onReviewRepair,
  });

  final ImportReviewItem item;
  final TypedReviewSnapshot? snapshot;
  final int index;
  final List<ImportReviewIssue> issues;
  final bool explanationRetained;
  final ExplanationEditProvenance explanationProvenance;
  final ValueChanged<bool>? onExplanationRetentionChanged;
  final VoidCallback? onEditExplanation;
  final bool answerDistillationCandidate;
  final String? answerDistillationStatus;
  final bool proofExplanationRecognized;
  final bool answerDistillationInProgress;
  final VoidCallback? onAnswerDistillation;
  final bool reviewRepairEligible;
  final bool reviewRepairInProgress;
  final bool reviewRepairProposalReady;
  final VoidCallback? onReviewRepair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final question = item.draft;
    final standardAnswer = question.standardAnswer.trim();
    final explanation = question.explanation.trim();
    final baseline = snapshot?.baselineLegacy;
    final typed = snapshot?.draft;
    final typedAnswer = question.standardAnswer == baseline?.standardAnswer &&
            typed?.answer is ContentAnswer
        ? (typed!.answer as ContentAnswer).content
        : null;
    final typedExplanation = resolveExplanationReviewContent(
      originalContent: typed?.explanation,
      baselineText: baseline?.explanation ?? '',
      currentText: question.explanation,
      retained: explanationRetained,
      provenance: explanationProvenance,
    );
    final metadataAvailable = item.metadataProjectionState ==
        ImportReviewMetadataProjectionState.available;
    final metadataUnavailable = item.metadataProjectionState ==
        ImportReviewMetadataProjectionState.unavailable;
    final hasWarningOrError = issues.any(
      (issue) =>
          issue.severity == ImportReviewSeverity.warning ||
          issue.severity == ImportReviewSeverity.error,
    );
    final reviewOnly = metadataAvailable &&
        !reviewRepairEligible &&
        item.metadata.repairCandidateCodes.isEmpty &&
        hasWarningOrError;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    question.type.displayName,
                    style: TextStyle(
                      color: theme.primaryColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '第 ${index + 1} 题',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            if (item.metadata.riskHints.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6.0,
                runSpacing: 6.0,
                children: ImportReviewBadgeFormatter.formatRiskHints(
                        item.metadata.riskHints)
                    .map((badge) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: badge.backgroundColor,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            badge.label,
                            style: TextStyle(
                              color: badge.textColor,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ],
            if (issues.isNotEmpty) ...[
              const SizedBox(height: 8),
              _IssueSummary(issues: issues),
            ],
            if (metadataUnavailable) ...[
              const SizedBox(height: 8),
              _RepairEligibilityNotice(
                key: ValueKey(
                  'question-repair-metadata-unavailable-${item.originalIndex}',
                ),
                icon: Icons.error_outline,
                color: Colors.redAccent,
                message: '审核元数据不可用，无法判断 AI 修补资格，请人工核对或重试。',
              ),
            ],
            if (reviewOnly) ...[
              const SizedBox(height: 8),
              _RepairEligibilityNotice(
                key: ValueKey(
                  'question-repair-review-only-${item.originalIndex}',
                ),
                icon: Icons.person_search_outlined,
                color: Colors.orangeAccent,
                message: '本题存在解析风险，需要人工核对；当前不支持 AI 自动修补。',
              ),
            ],
            if (metadataAvailable &&
                item.metadata.repairCandidateCodes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Chip(
                key: ValueKey(
                  'question-repair-candidate-${item.originalIndex}',
                ),
                avatar: const Icon(Icons.auto_fix_high, size: 16),
                label: const Text('需要结构修复'),
              ),
            ],
            if (answerDistillationCandidate) ...[
              const SizedBox(height: 8),
              if (answerDistillationStatus == 'ai_rejected' ||
                  answerDistillationStatus == 'ai_failed') ...[
                Chip(
                  key: ValueKey(
                    'answer-distillation-status-${item.originalIndex}',
                  ),
                  avatar: Icon(
                    answerDistillationStatus == 'ai_failed'
                        ? Icons.error_outline
                        : Icons.info_outline,
                    size: 16,
                  ),
                  label: Text(
                    answerDistillationStatus == 'ai_failed'
                        ? '生成失败，可重试'
                        : '未找到可安全提炼的答案',
                  ),
                ),
                const SizedBox(height: 4),
              ],
              OutlinedButton.icon(
                key: ValueKey(
                  'answer-distillation-single-${item.originalIndex}',
                ),
                onPressed: onAnswerDistillation,
                icon: answerDistillationInProgress
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_outlined, size: 16),
                label: Text(
                  answerDistillationInProgress ? '正在生成答案' : '生成标准答案',
                ),
              ),
            ],
            if (proofExplanationRecognized) ...[
              const SizedBox(height: 8),
              const Chip(
                avatar: Icon(Icons.verified_outlined, size: 16),
                label: Text('证明过程已识别'),
              ),
            ],
            if (reviewRepairEligible) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: ValueKey(
                  'review-ai-repair-${item.originalIndex}',
                ),
                onPressed: onReviewRepair,
                icon: reviewRepairInProgress
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_fix_high_outlined, size: 16),
                label: Text(reviewRepairInProgress
                    ? '正在生成修补建议'
                    : reviewRepairProposalReady
                        ? '查看 AI 修补建议'
                        : 'AI 修补'),
              ),
            ],
            // Per-question keep/discard is meaningful only where a
            // document-level policy choice existed. New imports retain every
            // explanation, so they expose no retention control on the card.
            if (onExplanationRetentionChanged != null &&
                (question.type == QuestionType.singleChoice ||
                    question.type == QuestionType.fillBlank) &&
                (question.rawExplanation?.trim().isNotEmpty ?? false)) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    key: ValueKey(
                      'question-explanation-keep-${item.originalIndex}',
                    ),
                    label: const Text('保留解析'),
                    selected: explanationRetained,
                    onSelected: (_) => onExplanationRetentionChanged!(true),
                  ),
                  FilterChip(
                    key: ValueKey(
                      'question-explanation-discard-${item.originalIndex}',
                    ),
                    label: const Text('忽略解析'),
                    selected: !explanationRetained,
                    onSelected: (_) => onExplanationRetentionChanged!(false),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _buildContent(
              context,
              question.content,
              question.content == baseline?.content ? typed?.stem : null,
            ),
            if (question.options.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (var i = 0; i < question.options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: baseline != null &&
                          typed != null &&
                          question.options.length == baseline.options.length &&
                          question.options.length == typed.options.length &&
                          question.options[i] == baseline.options[i]
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${typed.options[i].label}. '),
                            Expanded(
                              child: _buildContent(context, question.options[i],
                                  typed.options[i].content),
                            ),
                          ],
                        )
                      : _buildMarkdown(context, question.options[i]),
                ),
            ],
            const Divider(height: 24),
            if (!question.hasAnswerOrExplanation &&
                typedAnswer == null &&
                typedExplanation == null)
              const _MissingAnswerNotice()
            else
              _AnswerBlock(
                standardAnswer: standardAnswer,
                explanation: explanation,
                typedAnswer: typedAnswer,
                typedExplanation: typedExplanation,
                onEditExplanation: onEditExplanation,
              ),
          ],
        ),
      ),
    );
  }

  static Widget _buildContent(
      BuildContext context, String text, RichContent? content) {
    return content == null
        ? _buildMarkdown(context, text)
        : RichContentRenderer(content: content, fontSize: 14);
  }

  static Widget _buildMarkdown(BuildContext context, String text) {
    return buildLatexWidget(
      context,
      text,
      textColor: Theme.of(context).textTheme.bodyLarge?.color,
      fontSize: 14.0,
    );
  }
}

class _IssueSummary extends StatelessWidget {
  const _IssueSummary({required this.issues});

  final List<ImportReviewIssue> issues;

  @override
  Widget build(BuildContext context) {
    final visibleIssues = issues.take(3).toList(growable: false);
    final hasError =
        issues.any((issue) => issue.severity == ImportReviewSeverity.error);
    final color = hasError ? Colors.redAccent : Colors.orangeAccent;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final issue in visibleIssues)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    issue.severity == ImportReviewSeverity.error
                        ? Icons.error_outline
                        : Icons.info_outline,
                    size: 14,
                    color: color,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      issue.message,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (issues.length > visibleIssues.length)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '另有 ${issues.length - visibleIssues.length} 条问题',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RepairEligibilityNotice extends StatelessWidget {
  const _RepairEligibilityNotice({
    super.key,
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExplanationEditDialog extends StatefulWidget {
  const _ExplanationEditDialog({required this.initialText});

  final String initialText;

  @override
  State<_ExplanationEditDialog> createState() => _ExplanationEditDialogState();
}

/// Owns its controller so the field stays valid for the closing animation.
class _ExplanationEditDialogState extends State<_ExplanationEditDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑解析'),
      content: SizedBox(
        width: 520,
        child: TextField(
          key: const ValueKey('explanation-edit-field'),
          controller: _controller,
          maxLines: 12,
          minLines: 6,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '解析内容',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('explanation-edit-save'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _MissingAnswerNotice extends StatelessWidget {
  const _MissingAnswerNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.3)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
            SizedBox(height: 4),
            Text(
              '暂无答案，导入后可编辑或使用 AI 解答',
              style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnswerBlock extends StatelessWidget {
  const _AnswerBlock({
    required this.standardAnswer,
    required this.explanation,
    this.typedAnswer,
    this.typedExplanation,
    this.onEditExplanation,
  });

  final String standardAnswer;
  final String explanation;
  final RichContent? typedAnswer;
  final RichContent? typedExplanation;
  final VoidCallback? onEditExplanation;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '标准答案：',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        _QuestionCard._buildContent(
          context,
          standardAnswer.isEmpty ? '无' : standardAnswer,
          typedAnswer,
        ),
        if (explanation.isNotEmpty || typedExplanation != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Text(
                '解析：',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (onEditExplanation != null) ...[
                const Spacer(),
                TextButton.icon(
                  key: const ValueKey('explanation-edit-open'),
                  onPressed: onEditExplanation,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('编辑', style: TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          _QuestionCard._buildContent(context, explanation, typedExplanation),
        ],
      ],
    );
  }
}
