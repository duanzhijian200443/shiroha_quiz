import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../application/import_review/typed_review_snapshot.dart';
import '../../data/repositories/question_repository.dart';
import '../../services/task_manager.dart';
import '../../services/import_pipeline/final_question_latex_audit.dart';
import '../../services/import_pipeline/import_diagnostic_message.dart';
import '../../services/import_pipeline/import_diagnostic_formatter.dart';
import '../../services/import_pipeline/import_question_field_policy.dart';
import '../../services/import_pipeline/subjective_answer_distillation_policy.dart';
import '../../services/import_pipeline/subjective_answer_distillation_service.dart';
import '../../services/import_pipeline/subjective_answer_distillation_snapshot_policy.dart';
import '../../services/import_pipeline/subjective_answer_expectation.dart';
import '../../services/import_pipeline/subjective_answer_extractor.dart';
import '../../services/import_pipeline/import_parse_result.dart';
import '../../services/import_pipeline/ocr_typed_candidate.dart';
import '../../services/import_review/import_review_analyzer.dart';
import '../../services/import_review/import_review_blocking_policy.dart';
import '../../services/import_review/import_review_item.dart';
import '../../services/import_review/import_review_issue.dart';
import '../../services/import_review/import_review_badge_formatter.dart';
import '../../services/import_review/import_review_batch_controller.dart';
import '../../services/import_review/import_review_filter.dart';
import '../../services/import_review/import_review_visible_item.dart';
import '../../services/import_review/import_review_report.dart';
import '../../services/import_review/import_review_report_builder.dart';
import '../../services/import_review/import_review_report_formatter.dart';
import '../../services/import_review/import_commit_service.dart';
import '../../services/import_review/typed_review_result_builder.dart';
import '../../services/bank_update_notifier.dart';
import '../../data/models/question_draft.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../widgets/markdown_extensions.dart';

class ImportStagingScreen extends StatefulWidget {
  final List<Map<String, dynamic>> parsedQuestions;
  final String? taskId;
  final List<String>? warnings;
  final Map<String, dynamic>? diagnostics;
  final QuestionRepository? questionRepository;
  final ImportCommitService? commitService;
  final SubjectiveAnswerDistiller? answerDistiller;
  final TaskManager? taskManager;
  final ExplanationRetentionMode initialExplanationRetentionMode;

  const ImportStagingScreen({
    super.key,
    required this.parsedQuestions,
    this.taskId,
    this.warnings,
    this.diagnostics,
    this.questionRepository,
    this.commitService,
    this.answerDistiller,
    this.taskManager,
    this.initialExplanationRetentionMode =
        ExplanationRetentionMode.subjectiveOnly,
  });

  @override
  State<ImportStagingScreen> createState() => _ImportStagingScreenState();
}

class _ImportStagingScreenState extends State<ImportStagingScreen> {
  static const _explanationOverrideKey = '_explanation_override';
  static const _typedCommitBlockedText = '结构化题目缺少必要的审核信息，无法入库，请检查后重试';
  static const _typedCommitFailedText = '结构化题库入库失败，题目保持待审状态，请检查后重试';
  static const _typedOptionsBlockedText = '当前结构化题目暂不支持修改选项数量、顺序或标签，请恢复后再入库';
  static const _invalidStorageRouteText = '当前任务的存储路线无效，无法入库';
  static const _reviewDraftUnsafeText = '校对结果尚未安全保存，无法入库，请重试';
  static const _answerDistillationInProgressText = '答案仍在生成中，请等待完成后再入库';
  static const _typedTaskExpiredText = '任务已过期或已被替换，请检查后重试';
  static const _typedCommitInProgressText = '已有入库操作正在进行，请稍后重试';
  static const _safeSnapshotProvenanceKeys = {
    'q_num',
    'question_number',
    'source_page_indices',
    'source_block_ids',
    '_import_diagnostics',
    TypedReviewSnapshotCodec.mapKey,
  };

  late List<ImportReviewItem> _allItems;
  late List<ImportReviewVisibleItem> _visibleItems;
  late List<String> _importDiagnostics;
  late List<ImportDiagnosticMessage> _diagnosticMessages;
  late ImportReviewAnalyzerResult _reviewResult;
  ImportReviewFilter _activeFilter = ImportReviewFilter.all;
  ImportReviewSort _activeSort = ImportReviewSort.originalOrder;
  bool _isSaving = false;
  bool _selectionMode = false;
  final Set<int> _selectedOriginalIndices = {};
  late ExplanationRetentionMode _explanationRetentionMode;
  final Map<int, QuestionExplanationOverride> _explanationOverrides = {};
  final Map<int, String> _answerDistillationStatuses = {};
  final Map<int, String> _answerDistillationReasons = {};
  final Map<int, String> _reviewItemIds = {};
  final Map<int, Map<String, dynamic>> _snapshotProvenance = {};
  Future<void> _reviewDraftOperationTail = Future<void>.value();
  final SubjectiveAnswerDistillationPolicy _answerDistillationPolicy =
      const SubjectiveAnswerDistillationPolicy();
  SubjectiveAnswerDistiller? _answerDistiller;
  bool _isDistillingAnswers = false;
  bool _answerDistillationCancellationRequested = false;
  int _answerDistillationOperationId = 0;
  int _answerDistillationCompletedCount = 0;
  int _answerDistillationTotalCount = 0;
  int? _activeAnswerDistillationIndex;

  String? get _traceId {
    final value =
        widget.diagnostics?[TaskManager.keyTraceId]?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  final TextEditingController _bankNameController = TextEditingController();
  final TextEditingController _folderController = TextEditingController();
  late final QuestionRepository _questionRepository =
      widget.questionRepository ?? QuestionRepository.instance;
  late final ImportCommitService _commitService = widget.commitService ??
      ImportCommitService(questionRepository: _questionRepository);
  late final TaskManager _taskManager =
      widget.taskManager ?? TaskManager.instance;
  List<String> _existingFolders = [];

  bool get _isBlockedByQualityGate =>
      ImportReviewBlockingPolicy.isBlocked(_reviewResult);

  bool get _isStemOnlyDocument =>
      widget.diagnostics?['documentRole']?.toString() == 'stemOnly';

  SubjectiveAnswerDistiller get _resolvedAnswerDistiller {
    return _answerDistiller ??= widget.answerDistiller ??
        SubjectiveAnswerDistillationService(
          engineRepository: AiDependenciesScope.of(context).engineRepository,
        );
  }

  String? get _qualityGateReason {
    if (ImportReviewBlockingPolicy.isBlocked(_reviewResult)) {
      return '题目结构错误，请修正或删除后再入库';
    }
    return null;
  }

  String get _confirmButtonText {
    final reason = _qualityGateReason;
    if (reason != null) return '解析不完整，禁止入库：$reason';
    if (_isBlockedByQualityGate) return '解析不完整，禁止入库';
    return '确认无误，收入题库';
  }

  bool get _hasLowQualityVision {
    final summary = widget.diagnostics?['visionQualitySummary'];
    if (summary is! Map) return false;
    return summary['hasLowQualityVisionParse'] == true;
  }

  bool get _hasUnsupportedStructure {
    final summary = widget.diagnostics?['unsupportedStructureSummary'];
    if (summary is! Map) return false;
    final imageBlockCount = summary['imageBlockCount'];
    final tableBlockCount = summary['tableBlockCount'];
    return (imageBlockCount is int && imageBlockCount > 0) ||
        (tableBlockCount is int && tableBlockCount > 0);
  }

  @override
  void initState() {
    super.initState();
    _explanationRetentionMode = widget.initialExplanationRetentionMode;
    final messages = ImportDiagnosticFormatter.format(
      warnings: widget.warnings,
      diagnostics: widget.diagnostics,
    );
    if (messages.isNotEmpty) {
      _diagnosticMessages = messages;
      _importDiagnostics = const [];
    } else {
      _importDiagnostics = _readImportDiagnostics(widget.parsedQuestions);
      _diagnosticMessages = _importDiagnostics
          .map((w) => ImportDiagnosticMessage(
                severity: ImportDiagnosticSeverity.warning,
                title: '导入警告',
                message: w,
              ))
          .toList();
    }
    final historicalGateMessage = _historicalQualityGateMessage();
    if (historicalGateMessage != null) {
      _diagnosticMessages = [
        ..._diagnosticMessages,
        historicalGateMessage,
      ];
    }
    _allItems = widget.parsedQuestions
        .asMap()
        .entries
        .map((e) => ImportReviewItem.fromMap(e.value, e.key))
        .toList();
    final snapshotNormalizationNeeded =
        _restoreReviewDraftMarkers(widget.parsedQuestions);
    final extractedLocally = _applyLocalSubjectiveAnswers();
    _reapplyExplanationPolicy();
    _refreshReviewState();
    _loadExistingFolders();
    if (extractedLocally || snapshotNormalizationNeeded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_persistReviewDraft());
      });
    }
  }

  @override
  void dispose() {
    _answerDistillationCancellationRequested = true;
    _answerDistillationOperationId++;
    super.dispose();
  }

  ImportDiagnosticMessage? _historicalQualityGateMessage() {
    final gate = widget.diagnostics?['qualityGate'];
    if (gate is! Map || gate['blocked'] != true) return null;
    return ImportDiagnosticMessage(
      severity: ImportDiagnosticSeverity.warning,
      title: '初始质量门禁',
      message: '初始解析曾被质量门禁标记为阻断；最终门禁以当前校对结果为准。',
      source: 'quality_gate',
      code: 'HISTORICAL_GATE_BLOCKED',
    );
  }

  List<String> _readImportDiagnostics(List<Map<String, dynamic>> questions) {
    if (questions.isEmpty) return const [];

    final raw = questions.first['_import_diagnostics'];
    if (raw is List) {
      return raw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }

    return const [];
  }

  Future<void> _loadExistingFolders() async {
    final folders = await _questionRepository.getAvailableFolders();
    if (mounted) {
      setState(() {
        _existingFolders = folders;
      });
    }
  }

  Future<void> _copyTraceId() async {
    final traceId = _traceId;
    if (traceId == null) return;
    await Clipboard.setData(ClipboardData(text: traceId));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Trace ID 已复制')),
    );
  }

  void _validateBeforeSave() {
    if (_isBlockedByQualityGate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('解析不完整，禁止入库'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    if (_allItems.isEmpty) {
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

    final report = ImportReviewReportBuilder.build(_allItems, _reviewResult);

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

  void _enterSelectionMode() {
    setState(() {
      _selectionMode = true;
      _selectedOriginalIndices.clear();
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedOriginalIndices.clear();
    });
  }

  void _toggleSelection(ImportReviewItem item) {
    setState(() {
      if (_selectedOriginalIndices.contains(item.originalIndex)) {
        _selectedOriginalIndices.remove(item.originalIndex);
      } else {
        _selectedOriginalIndices.add(item.originalIndex);
      }
    });
  }

  void _selectAllVisible() {
    setState(() {
      for (final vi in _visibleItems) {
        _selectedOriginalIndices.add(vi.item.originalIndex);
      }
    });
  }

  void _applyBatchResult(List<ImportReviewItem> nextItems) {
    setState(() {
      _allItems = nextItems;
      _reapplyExplanationPolicy();
      _selectedOriginalIndices.clear();
      _selectionMode = false;
      _refreshReviewState();
    });
    unawaited(_persistReviewDraft());
  }

  void _deleteSelectedWithConfirm() {
    if (_selectedOriginalIndices.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除选中题目'),
        content:
            Text('将删除 ${_selectedOriginalIndices.length} 道题，此操作仅影响本次导入暂存列表。'),
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
              final nextItems = ImportReviewBatchController.deleteSelected(
                items: _allItems,
                selectedOriginalIndices: _selectedOriginalIndices,
              );
              _applyBatchResult(nextItems);
            },
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }

  void _changeSelectedType(QuestionType targetType) {
    final nextItems = ImportReviewBatchController.changeTypeSelected(
      items: _allItems,
      selectedOriginalIndices: _selectedOriginalIndices,
      targetType: targetType,
    );
    _applyBatchResult(nextItems);
  }

  void _showChangeTypeDialog() {
    if (_selectedOriginalIndices.isEmpty) return;
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
                _changeSelectedType(QuestionType.singleChoice);
              },
            ),
            ListTile(
              title: const Text('填空题'),
              leading: const Icon(Icons.space_bar),
              onTap: () {
                Navigator.pop(ctx);
                _changeSelectedType(QuestionType.fillBlank);
              },
            ),
            ListTile(
              title: const Text('简答题'),
              leading: const Icon(Icons.notes),
              onTap: () {
                Navigator.pop(ctx);
                _changeSelectedType(QuestionType.shortAnswer);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSaveDialog() {
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
                    if (_existingFolders.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8.0,
                        runSpacing: 8.0,
                        children: _existingFolders
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
    if (_isBlockedByQualityGate) return;

    if (_allItems.isEmpty) {
      Navigator.pop(context);
      return;
    }

    final report = ImportReviewReportBuilder.build(_allItems, _reviewResult);

    final route = _resolveStorageRoute();
    if (route == null) {
      _showFixedError(_invalidStorageRouteText);
      return;
    }
    if (route == ImportStorageRoute.typedV2) {
      await _confirmAndSaveTyped(bankName, folderName, report);
      return;
    }
    await _confirmAndSaveLegacy(bankName, folderName, report);
  }

  Future<void> _confirmAndSaveLegacy(
    String bankName,
    String folderName,
    ImportReviewReport report,
  ) async {
    setState(() => _isSaving = true);
    try {
      await _commitService.commit(
        bankName: bankName,
        folderName: folderName,
        questions: _allItems.map((item) => item.draft).toList(),
        taskId: widget.taskId,
        diagnostics: widget.diagnostics ?? const <String, dynamic>{},
        explanationRetentionMode: _explanationRetentionMode,
        explanationOverrides: _allItems
            .map(
              (item) =>
                  _explanationOverrides[item.originalIndex] ??
                  QuestionExplanationOverride.inherit,
            )
            .toList(growable: false),
      );

      _showSuccessAfterCommit(report, bankName, folderName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('入库失败: $e'), backgroundColor: Colors.redAccent));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _confirmAndSaveTyped(
    String bankName,
    String folderName,
    ImportReviewReport report,
  ) async {
    // Programmatic distillation gate: the disabled button must never be the
    // only protection. A bypassed save flow still blocks while answers are
    // being generated so the commit snapshot cannot race the distillation.
    if (_isDistillingAnswers) {
      _showFixedError(_answerDistillationInProgressText);
      return;
    }

    final taskId = widget.taskId?.trim() ?? '';
    final attemptToken =
        widget.diagnostics?[TaskManager.keyAttemptToken]?.toString().trim() ??
            '';
    final attemptNumber = _readAttemptNumber();
    if (taskId.isEmpty || attemptToken.isEmpty || attemptNumber == null) {
      _showFixedError(_typedCommitBlockedText);
      return;
    }

    setState(() => _isSaving = true);
    try {
      // Commit-time review draft flush: wait for the queued tail, persist the
      // latest draft, and require a successful save before committing. The
      // payload must be rebuilt afterwards so revision N is bound to the
      // post-flush snapshot, never to an entry-time capture.
      final flushResult = await _persistReviewDraft(showFailurePrompt: false);
      if (flushResult == null || !flushResult.saved) {
        _showFixedError(_reviewDraftUnsafeText);
        return;
      }
      final items = _buildCurrentTypedCommitInputs();
      if (items == null) {
        _showFixedError(_typedCommitBlockedText);
        return;
      }
      await _commitService.commitTyped(
        bankName: bankName,
        folderName: folderName,
        items: items,
        taskId: taskId,
        attemptToken: attemptToken,
        attemptNumber: attemptNumber,
        expectedReviewDraftRevision: flushResult.revision,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: _explanationRetentionMode,
        explanationOverrides: _allItems
            .map(
              (item) =>
                  _explanationOverrides[item.originalIndex] ??
                  QuestionExplanationOverride.inherit,
            )
            .toList(growable: false),
      );
      _showSuccessAfterCommit(report, bankName, folderName);
    } on TypedReviewCommitException catch (error) {
      _showTypedCommitError(error.failure);
    } on TypedReviewCommitAttemptException catch (error) {
      _showTypedCommitAttemptError(error.failure);
    } catch (_) {
      _showFixedError(_typedCommitFailedText);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Builds typed commit inputs from the current `_allItems` snapshot,
  /// preserving the `originalIndex` association to the review markers and
  /// typed snapshot envelopes. Strictly validates the envelope presence and
  /// returns null when any item cannot be bound to its snapshot, so the
  /// caller can show the fixed blocked text without exposing raw state.
  List<TypedReviewCommitInput>? _buildCurrentTypedCommitInputs() {
    final items = <TypedReviewCommitInput>[];
    for (final item in _allItems) {
      final marker = _reviewItemIds[item.originalIndex];
      final provenance = _snapshotProvenance[item.originalIndex];
      if (marker == null ||
          provenance == null ||
          !provenance.containsKey(TypedReviewSnapshotCodec.mapKey)) {
        return null;
      }
      items.add(
        TypedReviewCommitInput(
          reviewItemId: marker,
          envelope: provenance[TypedReviewSnapshotCodec.mapKey],
          currentDraft: item.draft,
        ),
      );
    }
    if (items.isEmpty) return null;
    return items;
  }

  void _showTypedCommitError(TypedReviewCommitFailure failure) {
    _showFixedError(
      failure == TypedReviewCommitFailure.unsupportedOptionEdit
          ? _typedOptionsBlockedText
          : _typedCommitFailedText,
    );
  }

  void _showTypedCommitAttemptError(
    TypedReviewCommitAttemptFailure failure,
  ) {
    _showFixedError(
      switch (failure) {
        TypedReviewCommitAttemptFailure.taskMissing ||
        TypedReviewCommitAttemptFailure.taskNotPendingReview ||
        TypedReviewCommitAttemptFailure.staleAttempt ||
        TypedReviewCommitAttemptFailure.staleReviewDraft =>
          _typedTaskExpiredText,
        TypedReviewCommitAttemptFailure.commitInProgress =>
          _typedCommitInProgressText,
        TypedReviewCommitAttemptFailure.persistenceFailed =>
          _typedCommitFailedText,
      },
    );
  }

  void _showSuccessAfterCommit(
    ImportReviewReport report,
    String bankName,
    String folderName,
  ) {
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                ImportReviewReportFormatter.formatSuccessReport(
                    report, bankName, folderName),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
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
  }

  void _showFixedError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: Colors.redAccent,
    ));
  }

  /// Strict route resolution: missing route -> legacyV1, legacyV1 with any
  /// legal reason -> legacyV1, typedV2 + typed_candidate_ready -> typedV2,
  /// every other combination -> null (block).
  ImportStorageRoute? _resolveStorageRoute() {
    final value = widget.diagnostics?[TaskManager.keyImportStorageRoute];
    final ImportStorageRoute route;
    try {
      route = value == null
          ? ImportStorageRoute.legacyV1
          : decodeImportStorageRoute(value);
    } on TypedReviewSnapshotException {
      return null;
    }
    try {
      validateImportStorageMetadata(
        route: route,
        reason: widget.diagnostics?[TaskManager.keyImportStorageReason],
      );
    } on TypedReviewSnapshotException {
      return null;
    }
    return route;
  }

  int? _readAttemptNumber() {
    final value = widget.diagnostics?[TaskManager.keyAttemptNumber];
    if (value is int && value > 0) return value;
    if (value is num && value > 0) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  void _refreshReviewState() {
    _reviewResult = ImportReviewAnalyzer.analyzeItems(_allItems);
    _refreshVisibleItems();
  }

  bool _restoreReviewDraftMarkers(List<Map<String, dynamic>> questions) {
    var normalizationNeeded = false;
    for (var index = 0; index < questions.length; index++) {
      final source = questions[index];
      _snapshotProvenance[index] = <String, dynamic>{
        for (final key in _safeSnapshotProvenanceKeys)
          if (source.containsKey(key)) key: source[key],
      };
      final storedItemId = source[TaskManager.keyReviewItemId]?.toString();
      String? envelopeReviewItemId;
      final envelope = source[TypedReviewSnapshotCodec.mapKey];
      if (envelope is Map && envelope['reviewItemId'] is String) {
        envelopeReviewItemId = envelope['reviewItemId'] as String;
      }
      _reviewItemIds[index] = storedItemId ??
          envelopeReviewItemId ??
          '${widget.taskId ?? 'local'}:${source['question_number'] ?? source['q_num'] ?? 'unknown'}:$index';
      normalizationNeeded |= storedItemId == null;
      final override = questions[index][_explanationOverrideKey]?.toString();
      for (final value in QuestionExplanationOverride.values) {
        if (value.name == override) {
          _explanationOverrides[index] = value;
          break;
        }
      }
      final status = SubjectiveAnswerDistillationSnapshotPolicy.sanitizeStatus(
        questions[index][TaskManager.keyAnswerDistillationStatus],
      );
      if (status != null) {
        _answerDistillationStatuses[index] = status;
      }
      final reason = SubjectiveAnswerDistillationSnapshotPolicy.sanitizeReason(
        status: status,
        value: questions[index][TaskManager.keyAnswerDistillationReason],
      );
      if (reason != null) {
        _answerDistillationReasons[index] = reason;
      }
    }
    return normalizationNeeded;
  }

  bool _applyLocalSubjectiveAnswers() {
    if (_isStemOnlyDocument) return false;
    const extractor = SubjectiveAnswerExtractor();
    const expectationPolicy = SubjectiveAnswerExpectationPolicy();
    var changed = false;

    for (var index = 0; index < _allItems.length; index++) {
      final item = _allItems[index];
      final question = item.draft;
      if (question.type != QuestionType.shortAnswer) continue;

      final expectation = expectationPolicy.classify(question);
      if (expectation == SubjectiveAnswerExpectation.proofExplanation &&
          question.explanation.trim().isNotEmpty) {
        if (_answerDistillationStatuses[item.originalIndex] !=
            'proof_explanation_recognized') {
          _answerDistillationStatuses[item.originalIndex] =
              'proof_explanation_recognized';
          _answerDistillationReasons.remove(item.originalIndex);
          changed = true;
        }
        continue;
      }

      final result = extractor.extract(
        questionNumber: item.originalIndex + 1,
        content: question.content,
        standardAnswer: question.standardAnswer,
        explanation: question.explanation,
      );
      if (!result.matched || result.answer == null) continue;

      _allItems[index] = item.copyWith(
        draft: question.copyWith(standardAnswer: result.answer),
      );
      _answerDistillationStatuses[item.originalIndex] = 'local_extracted';
      _answerDistillationReasons.remove(item.originalIndex);
      changed = true;
    }
    return changed;
  }

  Future<T> _enqueueReviewDraftOperation<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _reviewDraftOperationTail = _reviewDraftOperationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<ReviewDraftSaveResult?> _persistReviewDraft({
    bool showFailurePrompt = true,
  }) {
    final taskId = widget.taskId;
    if (taskId == null || taskId.trim().isEmpty) {
      return Future<ReviewDraftSaveResult?>.value();
    }

    return _enqueueReviewDraftOperation(() async {
      final questions = _allItems.map((item) {
        final question = <String, dynamic>{
          ...?_snapshotProvenance[item.originalIndex],
          ...item.draft.toMap(),
          '_import_review': item.metadata.toMap(),
          TaskManager.keyReviewItemId: _reviewItemIds[item.originalIndex],
          _explanationOverrideKey: (_explanationOverrides[item.originalIndex] ??
                  QuestionExplanationOverride.inherit)
              .name,
        };
        final status =
            SubjectiveAnswerDistillationSnapshotPolicy.sanitizeStatus(
          _answerDistillationStatuses[item.originalIndex],
        );
        if (status != null) {
          question[TaskManager.keyAnswerDistillationStatus] = status;
        }
        final reason =
            SubjectiveAnswerDistillationSnapshotPolicy.sanitizeReason(
          status: status,
          value: _answerDistillationReasons[item.originalIndex],
        );
        if (reason != null) {
          question[TaskManager.keyAnswerDistillationReason] = reason;
        }
        return question;
      }).toList(growable: false);

      final result = await _taskManager.saveReviewDraft(
        taskId,
        questions: questions,
        explanationRetentionMode: _explanationRetentionMode,
      );
      if (!result.saved && showFailurePrompt && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('校对结果尚未保存，请重试')),
        );
      }
      return result;
    });
  }

  List<ImportReviewItem> get _answerDistillationCandidates {
    return _allItems
        .where(
          (item) => _answerDistillationPolicy.isCandidate(
            item.draft,
            isStemOnly: _isStemOnlyDocument,
          ),
        )
        .toList(growable: false);
  }

  bool _isAnswerDistillationCandidate(ImportReviewItem item) {
    return _answerDistillationPolicy.isCandidate(
      item.draft,
      isStemOnly: _isStemOnlyDocument,
    );
  }

  Future<SubjectiveAnswerDistillationResult> _distillAnswer(
    ImportReviewItem item, {
    required Duration timeout,
  }) async {
    try {
      return await _resolvedAnswerDistiller.distill(
        questionNumber: item.originalIndex + 1,
        question: item.draft,
        isStemOnly: _isStemOnlyDocument,
        timeout: timeout,
      );
    } catch (error) {
      return SubjectiveAnswerDistillationResult.failed(
        diagnostics: [
          'answer_distillation_failed',
          'answer_distillation_failure_type:${error.runtimeType}',
        ],
      );
    }
  }

  bool _applyDistillationResult(
    int originalIndex,
    SubjectiveAnswerDistillationResult result,
  ) {
    final answer = result.standardAnswer?.trim();
    if (result.applied && (answer == null || answer.isEmpty)) return false;

    final itemIndex = _allItems.indexWhere(
      (item) => item.originalIndex == originalIndex,
    );
    if (itemIndex < 0) return false;
    if (result.applied) {
      final current = _allItems[itemIndex];
      _allItems[itemIndex] = current.copyWith(
        draft: current.draft.copyWith(standardAnswer: answer),
      );
      _answerDistillationReasons.remove(originalIndex);
    } else {
      final reason = SubjectiveAnswerDistillationSnapshotPolicy.sanitizeReason(
        status: result.snapshotStatus,
        value: result.safeReasonCode,
      );
      if (reason == null) {
        _answerDistillationReasons.remove(originalIndex);
      } else {
        _answerDistillationReasons[originalIndex] = reason;
      }
    }
    _answerDistillationStatuses[originalIndex] = result.snapshotStatus;
    return true;
  }

  Future<bool> _mergeDistillationResult(
    ImportReviewItem item,
    SubjectiveAnswerDistillationResult result, {
    required int? expectedRevision,
  }) async {
    final answer = result.standardAnswer?.trim();
    if (result.applied && (answer == null || answer.isEmpty)) return false;

    final taskId = widget.taskId;
    if (taskId == null || taskId.trim().isEmpty) {
      if (!mounted) return false;
      return _applyDistillationResult(item.originalIndex, result);
    }
    if (expectedRevision == null) return false;

    return _enqueueReviewDraftOperation(() async {
      final saveResult = await _taskManager.mergeReviewDraftAnswerDistillation(
        taskId,
        reviewItemId: _reviewItemIds[item.originalIndex]!,
        expectedRevision: expectedRevision,
        standardAnswer: result.applied ? answer : null,
        status: result.snapshotStatus,
        reasonCode: result.safeReasonCode,
      );
      if (!saveResult.saved) {
        if (mounted && saveResult.status == ReviewDraftSaveStatus.failed) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('答案已生成，但校对快照保存失败')),
          );
        }
        return false;
      }
      return _applyDistillationResult(item.originalIndex, result);
    });
  }

  Future<void> _distillSingleAnswer(ImportReviewItem item) async {
    if (_isDistillingAnswers || !_isAnswerDistillationCandidate(item)) return;
    final operationId = ++_answerDistillationOperationId;
    setState(() {
      _isDistillingAnswers = true;
      _answerDistillationCancellationRequested = false;
      _answerDistillationCompletedCount = 0;
      _answerDistillationTotalCount = 1;
      _activeAnswerDistillationIndex = item.originalIndex;
    });

    final baseSnapshot = await _persistReviewDraft();
    if (widget.taskId != null && baseSnapshot?.saved != true) {
      if (!mounted || operationId != _answerDistillationOperationId) return;
      setState(() {
        _isDistillingAnswers = false;
        _activeAnswerDistillationIndex = null;
      });
      return;
    }
    final result = await _distillAnswer(
      item,
      timeout: const Duration(seconds: 30),
    );
    if (mounted && operationId != _answerDistillationOperationId) return;

    final recorded = await _mergeDistillationResult(
      item,
      result,
      expectedRevision: baseSnapshot?.revision,
    );
    if (!mounted || operationId != _answerDistillationOperationId) return;
    setState(() {
      _answerDistillationCompletedCount = 1;
      _isDistillingAnswers = false;
      _activeAnswerDistillationIndex = null;
      if (recorded && result.applied) _refreshReviewState();
    });
    _showAnswerDistillationOutcome(
      single: true,
      appliedCount: recorded && result.applied ? 1 : 0,
      rejectedCount: recorded &&
              result.outcome == SubjectiveAnswerDistillationOutcome.rejected
          ? 1
          : 0,
      failedCount: !recorded ||
              result.outcome == SubjectiveAnswerDistillationOutcome.failed
          ? 1
          : 0,
    );
  }

  Future<void> _distillAllAnswers() async {
    if (_isDistillingAnswers) return;
    final candidates = _answerDistillationCandidates;
    if (candidates.isEmpty) return;

    final operationId = ++_answerDistillationOperationId;
    final stopwatch = Stopwatch()..start();
    var appliedCount = 0;
    var rejectedCount = 0;
    var failedCount = 0;
    setState(() {
      _isDistillingAnswers = true;
      _answerDistillationCancellationRequested = false;
      _answerDistillationCompletedCount = 0;
      _answerDistillationTotalCount = candidates.length;
      _activeAnswerDistillationIndex = null;
    });

    for (var index = 0; index < candidates.length; index++) {
      if (_answerDistillationCancellationRequested) break;
      final remaining = const Duration(seconds: 90) - stopwatch.elapsed;
      if (remaining <= Duration.zero) break;
      final timeout = remaining.compareTo(const Duration(seconds: 30)) < 0
          ? remaining
          : const Duration(seconds: 30);
      final candidate = candidates[index];
      if (!mounted || operationId != _answerDistillationOperationId) return;
      setState(() {
        _activeAnswerDistillationIndex = candidate.originalIndex;
      });

      final baseSnapshot = await _persistReviewDraft();
      if (widget.taskId != null && baseSnapshot?.saved != true) break;
      final result = await _distillAnswer(candidate, timeout: timeout);
      if (mounted && operationId != _answerDistillationOperationId) return;
      final recorded = await _mergeDistillationResult(
        candidate,
        result,
        expectedRevision: baseSnapshot?.revision,
      );
      if (recorded) {
        switch (result.outcome) {
          case SubjectiveAnswerDistillationOutcome.applied:
            appliedCount++;
            break;
          case SubjectiveAnswerDistillationOutcome.rejected:
            rejectedCount++;
            break;
          case SubjectiveAnswerDistillationOutcome.failed:
            failedCount++;
            break;
        }
      } else {
        failedCount++;
      }
      if (!mounted || operationId != _answerDistillationOperationId) return;
      setState(() {
        _answerDistillationCompletedCount = index + 1;
        if (recorded && result.applied) _refreshReviewState();
      });
      if (_answerDistillationCancellationRequested) break;
    }
    stopwatch.stop();
    if (!mounted || operationId != _answerDistillationOperationId) return;
    final cancelled = _answerDistillationCancellationRequested;
    setState(() {
      _isDistillingAnswers = false;
      _activeAnswerDistillationIndex = null;
    });
    _showAnswerDistillationOutcome(
      cancelled: cancelled,
      appliedCount: appliedCount,
      rejectedCount: rejectedCount,
      failedCount: failedCount,
    );
  }

  void _cancelAnswerDistillation() {
    if (!_isDistillingAnswers) return;
    setState(() {
      _answerDistillationCancellationRequested = true;
    });
  }

  void _showAnswerDistillationOutcome({
    required int appliedCount,
    required int rejectedCount,
    required int failedCount,
    bool cancelled = false,
    bool single = false,
  }) {
    if (!mounted) return;
    final message = cancelled
        ? '已停止生成：补全 $appliedCount 道，未提炼 $rejectedCount 道，失败 $failedCount 道'
        : single && appliedCount == 1
            ? '标准答案已生成'
            : single && rejectedCount == 1
                ? '解析中未找到可安全提炼的明确答案'
                : single && failedCount == 1
                    ? '标准答案生成失败，可重试'
                    : '处理完成：补全 $appliedCount 道，未提炼 $rejectedCount 道，失败 $failedCount 道';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _reapplyExplanationPolicy() {
    _allItems = _allItems.map((item) {
      final question = <String, dynamic>{
        ...item.draft.toMap(),
        '_import_review': item.metadata.toMap(),
      };
      final finalized = finalizeAndAuditImportQuestion(
        question,
        mode: _explanationRetentionMode,
        override: _explanationOverrides[item.originalIndex] ??
            QuestionExplanationOverride.inherit,
      );
      return ImportReviewItem.fromMap(finalized, item.originalIndex);
    }).toList();
  }

  void _setDocumentExplanationRetention(bool retainObjectiveExplanations) {
    setState(() {
      _explanationRetentionMode = retainObjectiveExplanations
          ? ExplanationRetentionMode.allQuestionTypes
          : ExplanationRetentionMode.subjectiveOnly;
      _reapplyExplanationPolicy();
      _refreshReviewState();
    });
    unawaited(_persistReviewDraft());
  }

  void _setQuestionExplanationRetention(
    ImportReviewItem item,
    bool retain,
  ) {
    setState(() {
      _explanationOverrides[item.originalIndex] = retain
          ? QuestionExplanationOverride.keep
          : QuestionExplanationOverride.discard;
      _reapplyExplanationPolicy();
      _refreshReviewState();
    });
    unawaited(_persistReviewDraft());
  }

  bool _isQuestionExplanationRetained(ImportReviewItem item) {
    return const ImportQuestionFieldPolicy().shouldRetainExplanation(
      type: item.draft.type.code,
      mode: _explanationRetentionMode,
      override: _explanationOverrides[item.originalIndex] ??
          QuestionExplanationOverride.inherit,
    );
  }

  void _refreshVisibleItems() {
    _visibleItems = ImportReviewFilterService.apply(
      items: _allItems,
      analysis: _reviewResult,
      filter: _activeFilter,
      sort: _activeSort,
    );
  }

  Widget _buildToolbar() {
    final theme = Theme.of(context);
    final counts = ImportReviewFilterService.countByFilter(
      items: _allItems,
      analysis: _reviewResult,
    );

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
                final isSelected = _activeFilter == filter;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: FilterChip(
                    label: Text('${getFilterLabel(filter)} $count'),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() {
                          _activeFilter = filter;
                          _selectionMode = false;
                          _selectedOriginalIndices.clear();
                          _refreshVisibleItems();
                        });
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
                  '已筛选出 ${_visibleItems.length} 道题',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                PopupMenuButton<ImportReviewSort>(
                  initialValue: _activeSort,
                  onSelected: (sort) {
                    setState(() {
                      _activeSort = sort;
                      _selectionMode = false;
                      _selectedOriginalIndices.clear();
                      _refreshVisibleItems();
                    });
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
                        getSortLabel(_activeSort),
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
                itemCount: _diagnosticMessages.length,
                separatorBuilder: (_, __) => const Divider(height: 16),
                itemBuilder: (context, index) {
                  final msg = _diagnosticMessages[index];
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
    final summary = _reviewResult.summary;
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

  Widget _buildExplanationRetentionControl() {
    return SwitchListTile.adaptive(
      key: const ValueKey('objective-explanation-document-switch'),
      value: _explanationRetentionMode ==
          ExplanationRetentionMode.allQuestionTypes,
      onChanged: _setDocumentExplanationRetention,
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
    final candidateCount = _answerDistillationCandidates.length;
    if (candidateCount == 0 && !_isDistillingAnswers) {
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
                  _isDistillingAnswers
                      ? '正在生成答案 $_answerDistillationCompletedCount/$_answerDistillationTotalCount'
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
          if (_isDistillingAnswers)
            TextButton(
              key: const ValueKey('answer-distillation-cancel'),
              onPressed: _answerDistillationCancellationRequested
                  ? null
                  : _cancelAnswerDistillation,
              child: const Text('停止生成'),
            )
          else
            FilledButton(
              key: const ValueKey('answer-distillation-batch'),
              onPressed: _distillAllAnswers,
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
            _selectionMode
                ? '已选 ${_selectedOriginalIndices.length} 题'
                : '解析结果校对',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectionMode,
              )
            : null,
        actions: [
          if (!_selectionMode)
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: '批量操作',
              onPressed: _enterSelectionMode,
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
          if (_traceId != null) _buildTraceBar(),
          if (_diagnosticMessages.isNotEmpty) ...[
            _buildDiagnosticBanner(),
          ],
          if (_hasLowQualityVision) _buildVisionLowQualityBanner(),
          if (_hasUnsupportedStructure) _buildUnsupportedStructureBanner(),
          _buildExplanationRetentionControl(),
          _buildAnswerDistillationControl(),
          const Divider(height: 1),
          _buildSummaryBar(),
          const Divider(height: 1),
          _buildToolbar(),
          const Divider(height: 1),
          Expanded(
            child: _allItems.isEmpty
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
                : (_visibleItems.isEmpty
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
                        itemCount: _visibleItems.length,
                        itemBuilder: (context, index) {
                          final visibleItem = _visibleItems[index];
                          final item = visibleItem.item;
                          return Dismissible(
                            key: ValueKey(item.originalIndex),
                            direction: _selectionMode
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
                              setState(() {
                                _allItems.removeWhere((it) =>
                                    it.originalIndex == item.originalIndex);
                                _refreshReviewState();
                              });
                              unawaited(_persistReviewDraft());
                            },
                            child: Row(
                              children: [
                                if (_selectionMode)
                                  Checkbox(
                                    value: _selectedOriginalIndices
                                        .contains(item.originalIndex),
                                    onChanged: (val) {
                                      _toggleSelection(item);
                                    },
                                  ),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: _selectionMode
                                        ? () => _toggleSelection(item)
                                        : null,
                                    child: _QuestionCard(
                                      item: item,
                                      index: visibleItem.canonicalIndex,
                                      issues: visibleItem.issues,
                                      explanationRetained:
                                          _isQuestionExplanationRetained(item),
                                      onExplanationRetentionChanged:
                                          _selectionMode
                                              ? null
                                              : (retain) =>
                                                  _setQuestionExplanationRetention(
                                                    item,
                                                    retain,
                                                  ),
                                      answerDistillationCandidate:
                                          _isAnswerDistillationCandidate(item),
                                      answerDistillationStatus:
                                          _answerDistillationStatuses[
                                              item.originalIndex],
                                      proofExplanationRecognized:
                                          _answerDistillationStatuses[
                                                  item.originalIndex] ==
                                              'proof_explanation_recognized',
                                      answerDistillationInProgress:
                                          _activeAnswerDistillationIndex ==
                                              item.originalIndex,
                                      onAnswerDistillation: _selectionMode ||
                                              _isDistillingAnswers
                                          ? null
                                          : () => _distillSingleAnswer(item),
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
      bottomNavigationBar: _selectionMode
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
                      onPressed: _selectAllVisible,
                    ),
                    Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.edit),
                          label: const Text('改题型'),
                          onPressed: _selectedOriginalIndices.isEmpty
                              ? null
                              : _showChangeTypeDialog,
                        ),
                        TextButton.icon(
                          icon:
                              const Icon(Icons.delete, color: Colors.redAccent),
                          label: const Text('删除',
                              style: TextStyle(color: Colors.redAccent)),
                          onPressed: _selectedOriginalIndices.isEmpty
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
                    backgroundColor: _isBlockedByQualityGate
                        ? Colors.grey
                        : theme.primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : (_isBlockedByQualityGate
                          ? const Icon(Icons.block)
                          : const Icon(Icons.check_circle_outline)),
                  label: Text(
                      _isBlockedByQualityGate
                          ? _confirmButtonText
                          : (_isSaving
                              ? '正在入库...'
                              : '确认无误，将 ${_allItems.length} 题收入题库'),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  onPressed: (_isSaving ||
                          _isBlockedByQualityGate ||
                          _isDistillingAnswers)
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
      final hasError = _diagnosticMessages
          .any((m) => m.severity == ImportDiagnosticSeverity.error);
      final hasWarning = _diagnosticMessages
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
                '$bannerTitle (${_diagnosticMessages.length} 条记录)',
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
    final traceId = _traceId!;
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
    required this.index,
    required this.issues,
    required this.explanationRetained,
    required this.onExplanationRetentionChanged,
    required this.answerDistillationCandidate,
    required this.answerDistillationStatus,
    required this.proofExplanationRecognized,
    required this.answerDistillationInProgress,
    required this.onAnswerDistillation,
  });

  final ImportReviewItem item;
  final int index;
  final List<ImportReviewIssue> issues;
  final bool explanationRetained;
  final ValueChanged<bool>? onExplanationRetentionChanged;
  final bool answerDistillationCandidate;
  final String? answerDistillationStatus;
  final bool proofExplanationRecognized;
  final bool answerDistillationInProgress;
  final VoidCallback? onAnswerDistillation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final question = item.draft;
    final standardAnswer = question.standardAnswer.trim();
    final explanation = question.explanation.trim();

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
            if (item.metadata.repairCandidateCodes.isNotEmpty) ...[
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
            if ((question.type == QuestionType.singleChoice ||
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
                    onSelected: onExplanationRetentionChanged == null
                        ? null
                        : (_) => onExplanationRetentionChanged!(true),
                  ),
                  FilterChip(
                    key: ValueKey(
                      'question-explanation-discard-${item.originalIndex}',
                    ),
                    label: const Text('忽略解析'),
                    selected: !explanationRetained,
                    onSelected: onExplanationRetentionChanged == null
                        ? null
                        : (_) => onExplanationRetentionChanged!(false),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _buildMarkdown(context, question.content),
            const Divider(height: 24),
            if (!question.hasAnswerOrExplanation)
              const _MissingAnswerNotice()
            else
              _AnswerBlock(
                standardAnswer: standardAnswer,
                explanation: explanation,
              ),
          ],
        ),
      ),
    );
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
  });

  final String standardAnswer;
  final String explanation;

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
        _QuestionCard._buildMarkdown(
          context,
          standardAnswer.isEmpty ? '无' : standardAnswer,
        ),
        if (explanation.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            '解析：',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          _QuestionCard._buildMarkdown(context, explanation),
        ],
      ],
    );
  }
}
