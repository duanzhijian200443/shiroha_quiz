import 'dart:async';
import '../../domain/attempt/answer_attempt.dart';
import 'package:flutter/material.dart';
import 'bank_detail_screen.dart';
import 'import_settings_screen.dart';
import 'photo_capture_screen.dart';
import 'mock_center_screen.dart';
import 'plan_config_screen.dart';
import 'practice_page.dart';
import '../../application/study_activity/study_activity_contracts.dart';
import '../../domain/study_activity/study_activity_values.dart';
import '../study_activity/study_activity_route_binding.dart';
import 'task_center_screen.dart';
import '../../application/study_plan/study_plan_command_service.dart';
import '../../application/study_plan/study_plan_selection_service.dart';
import '../../application/questions/folder_query_port.dart';
import '../../application/questions/question_bank_mutation_command.dart';
import '../../application/questions/question_list_query_port.dart';
import '../../application/questions/question_mutation_command.dart';
import '../dependencies/practice_command_dependencies.dart';
import '../../application/safe_write/typed_answer_command.dart';
import '../../application/today/today_context_query.dart';
import '../home/today_controller.dart';
import '../../domain/study_plan/active_study_plan.dart';
import '../../services/study_plan/study_plan_practice_session_launcher.dart';
import '../dependencies/task_center_dependencies.dart';
import '../../application/task_center/task_center_contracts.dart';
import '../../services/import_review/import_commit_service.dart';

import '../../application/practice/study_session_launch.dart';
import '../home/current_plan_screen.dart';
import '../home/today_plan_card.dart';
import '../home/today_welcome_banner.dart';
import '../home/today_visual_theme.dart';
import '../theme/design_tokens.dart';
import '../../application/home_training_result.dart';
import '../../application/training/today_training_contracts.dart';
import '../../application/training/training_contracts.dart';
import '../../application/training/training_session_contracts.dart';
import '../dependencies/home_training_dependencies.dart';
import '../training/training_configuration_controller.dart';
import '../training/training_configuration_page.dart';
import '../home/today_category_training_card.dart';
import '../home/weekly_activity_card.dart';

enum _CreateImportAction { file, photo }

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.taskCenter,
    this.todayContextQuery,
    this.homeTraining,
    this.studyActivityQuery,
    this.localNow,
    this.studySessionLauncher,
    this.onSwitchBank,
    this.onPracticeRequested,
    this.onImportRequested,
    this.onPhotoImportRequested,
    this.onAskAssistant,
    this.questionListQuery,
    this.questionMutationPersistence,
    this.typedAnswerPersistence,
    this.questionBankMutationPersistence,
    this.folderQuery,
    this.importCommitService,
    this.practiceCommands,
    this.studyPlanSelectionService,
    this.studyPlanCommandService,
    this.studyPlanSessionLauncher,
    this.todayActivationEpoch = 0,
  });

  final TaskCenterDependencies? taskCenter;
  final TodayContextQuery? todayContextQuery;
  final HomeTrainingDependencies? homeTraining;
  final StudyActivityQuery? studyActivityQuery;
  final DateTime Function()? localNow;
  final StudySessionLauncher? studySessionLauncher;
  final VoidCallback? onSwitchBank;
  final VoidCallback? onPracticeRequested;
  final VoidCallback? onImportRequested;
  final VoidCallback? onPhotoImportRequested;
  final ValueChanged<String>? onAskAssistant;
  final QuestionListQueryPort? questionListQuery;
  final QuestionMutationPersistencePort? questionMutationPersistence;
  final TypedAnswerPersistencePort? typedAnswerPersistence;
  final QuestionBankMutationPersistencePort? questionBankMutationPersistence;
  final FolderQueryPort? folderQuery;
  final ImportCommitService? importCommitService;

  /// Assembled practice mutation commands, supplied by the composition root
  /// and forwarded to every practice entry this page opens.
  final PracticeCommandDependencies? practiceCommands;

  /// Existing singleton-plan seams, supplied by the composition root.
  final StudyPlanSelectionService? studyPlanSelectionService;
  final StudyPlanCommandService? studyPlanCommandService;
  final StudyPlanPracticeSessionLauncher? studyPlanSessionLauncher;

  /// Returning to Today refreshes both ordinary and singleton-plan snapshots.
  final int todayActivationEpoch;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final TodayController _controller;
  int? _taskBadge;
  int _badgeGeneration = 0;
  String get _currentBank => _controller.contextSnapshot.bankName ?? '点击修改选择题库';
  int get _newCount => _controller.contextSnapshot.newCount;
  int get _reviewCount => _controller.contextSnapshot.reviewCount;
  int get _totalCount => _controller.contextSnapshot.totalCount;
  int get _masteredCount => _controller.contextSnapshot.masteredCount;
  bool get _isLoading => _controller.contextLoading;
  StudyPlanFocusedState? get _focusedState => _controller.focusedState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = TodayController(
      loadContext: () =>
          widget.todayContextQuery?.loadContext() ??
          Future<TodayContextSnapshot>.error(const TodayContextUnavailable()),
      loadFocusedState: () =>
          widget.studyPlanSelectionService?.loadFocusedState() ??
          Future<StudyPlanFocusedState>.value(
              const StudyPlanFocusedNoActivePlan()),
      training: widget.homeTraining,
      activityQuery: widget.studyActivityQuery,
    )..addListener(_onControllerChanged);
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.todayActivationEpoch != oldWidget.todayActivationEpoch) {
      // The shared detail route listens too; don't notify a sibling route
      // while the shell is rebuilding. Microtasks do not require a new frame.
      scheduleMicrotask(() {
        if (mounted) _refresh();
      });
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadContext() => _controller.loadContext();
  Future<void> _loadFocusedState() => _controller.loadFocusedState();
  Future<void> _refresh() async {
    unawaited(_loadTaskBadge());
    await Future.wait([
      widget.homeTraining == null ? _loadContext() : _controller.loadTraining(),
      if (widget.homeTraining != null) _controller.loadWeek(),
      _loadFocusedState()
    ]);
  }

  Future<void> _loadTaskBadge() async {
    final generation = ++_badgeGeneration;
    int? count;
    try {
      final result = await widget.taskCenter?.query.read();
      if (result case HomeTrainingSuccess(:final value)) {
        count = value.items
            .where((item) =>
                item.coarseStatus == TaskCenterCoarseStatus.inProgress)
            .length;
      }
    } catch (_) {
      count = null;
    }
    if (mounted && generation == _badgeGeneration) {
      setState(() => _taskBadge = count);
    }
  }

  TodayTrainingSnapshot? get _training => switch (_controller.trainingResult) {
        HomeTrainingSuccess(:final value) => value,
        _ => null,
      };
  TrainingContentSummary? get _trainingSummary =>
      !_controller.trainingLoading && !_controller.selectionBusy
          ? switch (_training?.summary) {
              HomeTrainingSuccess(:final value) => value,
              _ => null,
            }
          : null;
  String _summaryCount(int? legacy, int? current) =>
      widget.homeTraining == null ? _count(legacy) : current?.toString() ?? '—';

  bool get _contextReady =>
      !_isLoading &&
      !_controller.contextUnavailable &&
      _controller.contextSnapshot.bankName != null;
  String _count(int? value) => _contextReady && value != null ? '$value' : '—';

  Future<void> _openImport() async {
    final action = await showModalBottomSheet<_CreateImportAction>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => const _CreateImportSheet(),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case _CreateImportAction.file:
        _openFileImport();
        return;
      case _CreateImportAction.photo:
        await _openPhotoImport();
        return;
    }
  }

  void _openFileImport() {
    if (widget.onImportRequested != null) {
      widget.onImportRequested!();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ImportSettingsScreen(),
      ),
    ).then((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _openPhotoImport() async {
    if (widget.onPhotoImportRequested != null) {
      widget.onPhotoImportRequested!();
      return;
    }

    final dispatched = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(builder: (_) => const PhotoCaptureScreen()),
    );
    if (!mounted) return;
    await _refresh();
    if (!mounted || dispatched != true) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('识别任务已开始，可在解析任务中查看进度。')),
    );
  }

  ThemeData get _visualTheme => todayVisualTheme(Theme.of(context));

  @override
  Widget build(BuildContext context) =>
      Theme(data: _visualTheme, child: Builder(builder: _buildHome));

  Widget _buildHome(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
          child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: DesignTokens.contentMaxWidth),
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: SingleChildScrollView(
              key: const ValueKey('today-scroll'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _brand(),
                    const SizedBox(height: 22),
                    Text('今日',
                        style: theme.textTheme.headlineLarge?.copyWith(
                            fontSize: 30,
                            height: 1.2,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('继续你的学习节奏',
                        style: TextStyle(
                            fontSize: 15,
                            height: 1.3,
                            color: colors.onSurfaceVariant)),
                    const SizedBox(height: 14),
                    const TodayWelcomeBanner(),
                    const SizedBox(height: 10),
                    Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                              child: _summary(
                                  '题库题量',
                                  _summaryCount(_totalCount,
                                      _trainingSummary?.totalCount),
                                  Icons.local_fire_department_rounded)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: _summary(
                                  '已掌握',
                                  _summaryCount(_masteredCount,
                                      _trainingSummary?.masteredCount),
                                  Icons.bar_chart_rounded)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: _summary(
                                  '今日已练',
                                  _summaryCount(
                                      _controller
                                          .contextSnapshot.todayPracticeCount,
                                      _trainingSummary?.todayPracticedCount),
                                  Icons.article_rounded)),
                        ]),
                    const SizedBox(height: 12),
                    widget.homeTraining == null
                        ? _trainingCard()
                        : _trainingV2(),
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(
                          child: Text('训练计划',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700))),
                      TextButton(
                          key: const ValueKey('home-view-plan'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 36),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: _openPlan,
                          child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('查看计划'),
                                Icon(Icons.chevron_right_rounded, size: 18)
                              ])),
                    ]),
                    TodayPlanCard(
                        state: _focusedState,
                        onOpen: _openPlan,
                        onRetry: _loadFocusedState,
                        onAskAssistant: widget.onAskAssistant == null
                            ? null
                            : _askAssistant),
                    const SizedBox(height: 10),
                    widget.homeTraining == null
                        ? _activity()
                        : WeeklyActivityCard(
                            result: _controller.weekResult,
                            loading: _controller.weekLoading,
                            todayLocalDate:
                                (widget.localNow?.call() ?? DateTime.now())
                                    .toIso8601String()
                                    .substring(0, 10)),
                    const SizedBox(height: 10),
                    _exam(),
                    const SizedBox(height: 12),
                    _tools(),
                  ]),
            ),
          ),
        ),
      )),
    );
  }

  Widget _brand() => LayoutBuilder(builder: (context, constraints) {
        final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
        final brand = Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.import_contacts_outlined,
              size: 25, color: _visualTheme.colorScheme.outline),
          const SizedBox(width: 8),
          Flexible(
              child: Text('Shiroha Quiz',
                  key: const ValueKey('home-brand-title'),
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _visualTheme.colorScheme.onSurface))),
        ]);
        final tagline = Text('让每一次练习，靠近更好的你',
            style: TextStyle(
                fontSize: 9, color: _visualTheme.colorScheme.onSurfaceVariant));
        return largeText
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [brand, const SizedBox(height: 5), tagline])
            : Row(children: [
                brand,
                const SizedBox(width: 12),
                Expanded(
                    child:
                        Align(alignment: Alignment.centerRight, child: tagline))
              ]);
      });

  Widget _surface({Key? key, required Widget child, double padding = 12}) =>
      Container(
          key: key,
          padding: EdgeInsets.all(padding),
          decoration: BoxDecoration(
              color: _visualTheme.colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              boxShadow: DesignTokens.surfaceShadow(_visualTheme.brightness)),
          child: child);

  Widget _summary(String label, String count, IconData icon) => _surface(
      padding: 10,
      child: LayoutBuilder(builder: (context, constraints) {
        final texts =
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: TextStyle(
                  fontSize: 10,
                  height: 1.3,
                  color: _visualTheme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 3),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Flexible(
                child: Text(count,
                    style: const TextStyle(
                        fontSize: 19,
                        height: 1.1,
                        fontWeight: FontWeight.w600))),
            const SizedBox(width: 3),
            const Text('题', style: TextStyle(fontSize: 10, height: 1.3)),
          ]),
        ]);
        final tile = TodayIconTile(icon, size: 30, iconSize: 22);
        final stack = MediaQuery.textScalerOf(context).scale(14) > 18 ||
            count.length > 4 ||
            constraints.maxWidth < 96;
        return stack
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [tile, const SizedBox(height: 8), texts])
            : Row(children: [
                tile,
                const SizedBox(width: 8),
                Expanded(child: texts)
              ]);
      }));

  Widget _trainingV2() {
    final snapshot = _training;
    final busy = _controller.trainingLoading ||
        _controller.selectionBusy ||
        _controller.practiceStartPending;
    final newCount = snapshot?.newCount;
    final reviewCount = snapshot?.categoryReviewCount;
    bool positive(HomeTrainingResult<TrainingCount>? result) =>
        switch (result) {
          HomeTrainingSuccess(:final value) => value.value > 0,
          _ => false,
        };
    return _surface(
        key: const ValueKey('home-training-card'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const TodayIconTile(Icons.ads_click_rounded),
            const SizedBox(width: 10),
            const Expanded(
                child: Text('今日训练',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
            IconButton(
                key: const ValueKey('home-training-config'),
                tooltip: '管理训练内容',
                onPressed: busy ? null : _openTrainingConfig,
                icon: const Icon(Icons.tune_rounded)),
            if (snapshot?.selection.currentContent != null)
              IconButton(
                  key: const ValueKey('home-bank-detail'),
                  tooltip: '题库详情',
                  onPressed: busy ? null : _openMemberDetail,
                  icon: const Icon(Icons.chevron_right_rounded)),
          ]),
          if (_controller.trainingLoading)
            const LinearProgressIndicator(
                key: ValueKey('home-context-loading')),
          if (snapshot == null && !_controller.trainingLoading)
            Row(children: [
              const Expanded(child: Text('训练暂不可用')),
              TextButton(onPressed: _refresh, child: const Text('重试'))
            ]),
          if (snapshot != null && snapshot.selection.categoryKey != null)
            TodayCategoryTrainingCard(
                snapshot: snapshot,
                category: _controller.currentCategory,
                busy: busy,
                onCategory: (key) async {
                  final failure = await _controller.selectCategory(key);
                  if (mounted && failure != null) {
                    _showFocusedMessage(failure == HomeTrainingFailure.stale
                        ? '训练配置已变化'
                        : '切换暂不可用');
                  }
                },
                onCycle: () async {
                  final failure = await _controller.cycleContent();
                  if (mounted && failure != null) {
                    _showFocusedMessage(failure == HomeTrainingFailure.stale
                        ? '训练配置已变化'
                        : '切换暂不可用');
                  }
                },
                onConfig: _openTrainingConfig),
          if (snapshot != null && snapshot.selection.categoryKey == null)
            TextButton(
                onPressed: busy ? null : _openTrainingConfig,
                child: const Text('配置训练内容')),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: TodayTrainingActionCard(
                    key: const ValueKey('home-new-task'),
                    title: '新题挑战',
                    count: newCount,
                    icon: Icons.add_rounded,
                    enabled: !busy &&
                        snapshot?.selection.state ==
                            TrainingCurrentContentState.usable &&
                        positive(newCount),
                    onPressed: () => _startTraining(false))),
            const SizedBox(width: 10),
            Expanded(
                child: TodayTrainingActionCard(
                    key: const ValueKey('home-review-task'),
                    title: '复习巩固',
                    count: reviewCount,
                    icon: Icons.sync_rounded,
                    enabled: !busy &&
                        snapshot?.selection.categoryKey != null &&
                        positive(reviewCount),
                    onPressed: () => _startTraining(true))),
          ]),
        ]));
  }

  Future<void> _openTrainingConfig() async {
    final ports = widget.homeTraining;
    if (ports == null) {
      _showFocusedMessage('训练配置暂不可用');
      return;
    }
    final controller = TrainingConfigurationController(
        query: ports.configurationQuery,
        command: ports.command,
        orderCommand: ports.orderCommand);
    try {
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  TrainingConfigurationPage(controller: controller)));
    } finally {
      controller.dispose();
      if (mounted) await _refresh();
    }
  }

  Future<void> _openMemberDetail() async {
    final banks = _training?.selection.currentContent?.content.members
        .map((m) => m.bankName)
        .toList();
    if (banks == null || banks.isEmpty) return;
    final bank = banks.length == 1
        ? banks.single
        : await showModalBottomSheet<String>(
            context: context,
            showDragHandle: true,
            useSafeArea: true,
            builder: (context) => ListView(shrinkWrap: true, children: [
                  for (final name in banks)
                    ListTile(
                        title: Text(name),
                        onTap: () => Navigator.pop(context, name)),
                ]));
    if (mounted && bank != null) _openBankDetail(bank);
  }

  Future<void> _startTraining(bool review) async {
    final snapshot = _training;
    final ports = widget.homeTraining;
    if (snapshot == null ||
        ports == null ||
        _controller.trainingLoading ||
        _controller.selectionBusy) {
      return;
    }
    final selection = snapshot.selection;
    final key = selection.categoryKey;
    if (key == null) return;
    await _controller.runFocusedStart(() async {
      TrainingSessionLaunchResult result;
      try {
        if (review) {
          result = await ports.session.startCategoryReview(key);
        } else {
          final content = selection.currentContent?.content;
          if (content == null ||
              selection.state != TrainingCurrentContentState.usable) {
            return;
          }
          result = await ports.session.startNew(TrainingContentTarget(
              contentId: content.contentId,
              expectedRevision: content.revision));
        }
      } catch (_) {
        result = const TrainingSessionUnavailable();
      }
      if (!mounted) return;
      switch (result) {
        case TrainingSessionReady():
          await Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => PracticePage(
                        bankName: selection.currentContent?.content.members
                                .first.bankName ??
                            '',
                        usePreparedStudySession: true,
                        preparedSessionKind: AnswerAttemptSessionKind.normal,
                        practiceCommands: widget.practiceCommands,
                        studyActivity: StudyActivityRouteDescriptor(
                            scene: review
                                ? StudyActivityScene.categoryReview
                                : StudyActivityScene.ordinaryPractice,
                            context: StudyActivityContext(
                                categoryKey: key,
                                contentId: review
                                    ? null
                                    : selection
                                        .currentContent!.content.contentId)),
                      )));
          if (mounted) await _refresh();
        case TrainingSessionEmpty():
          _showFocusedMessage('当前没有可练习的题目');
          await _refresh();
        case TrainingSessionStaleConfiguration():
          _showFocusedMessage('训练配置已变化');
          await _refresh();
        case TrainingSessionUnavailable():
          _showFocusedMessage('训练准备暂不可用');
      }
    });
  }

  Widget _trainingCard() => _surface(
      key: const ValueKey('home-training-card'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const TodayIconTile(Icons.ads_click_rounded),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('今日训练',
                    style: _visualTheme.textTheme.titleMedium
                        ?.copyWith(fontSize: 17, fontWeight: FontWeight.w700)),
                InkWell(
                    key: const ValueKey('home-switch-bank'),
                    onTap: _handleSwitchBank,
                    child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                            key: const ValueKey('home-bank-card'),
                            children: [
                              Flexible(
                                  child: Text(
                                      _controller.contextSnapshot.bankName ??
                                          '选择题库',
                                      style: const TextStyle(fontSize: 12))),
                              const SizedBox(width: 4),
                              const Icon(Icons.keyboard_arrow_down_rounded,
                                  size: 16),
                            ]))),
              ])),
          if (_controller.contextSnapshot.bankName != null)
            IconButton(
                key: const ValueKey('home-bank-detail'),
                tooltip: '题库详情',
                onPressed: () => _openBankDetail(_currentBank),
                icon: const Icon(Icons.chevron_right_rounded)),
        ]),
        if (_isLoading)
          const LinearProgressIndicator(key: ValueKey('home-context-loading')),
        if (_controller.contextUnavailable)
          Row(children: [
            const Expanded(child: Text('暂时无法加载题库，请重试')),
            TextButton(onPressed: _refresh, child: const Text('重试')),
          ]),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: _trainingEntry('home-new-task', '新题挑战', _newCount,
                  Icons.add_rounded, StudySessionPool.newQuestions)),
          const SizedBox(width: 10),
          Expanded(
              child: _trainingEntry('home-review-task', '复习巩固', _reviewCount,
                  Icons.sync_rounded, StudySessionPool.dueReviews)),
        ]),
      ]));

  Widget _trainingEntry(String key, String title, int count, IconData icon,
      StudySessionPool pool) {
    final enabled = _contextReady &&
        count > 0 &&
        widget.studySessionLauncher != null &&
        !_controller.practiceStartPending;
    final colors = _visualTheme.colorScheme;
    return Semantics(
        button: true,
        enabled: enabled,
        child: Material(
            color: colors.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: colors.outlineVariant)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey(key),
              onTap: enabled ? () => _startOrdinary(pool) : null,
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 15),
                  child: LayoutBuilder(builder: (context, constraints) {
                    final texts = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
                              TextSpan(text: _count(count), children: [
                                const TextSpan(
                                    text: ' 题',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w400)),
                              ]),
                              style: TextStyle(
                                  fontSize: 21,
                                  height: 1.2,
                                  fontWeight: FontWeight.w600,
                                  color: enabled
                                      ? colors.onSurface
                                      : colors.onSurfaceVariant)),
                          const SizedBox(height: 6),
                          Text(title,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant)),
                        ]);
                    final tile = TodayIconTile(icon, size: 42, iconSize: 31);
                    final chevron = Icon(Icons.chevron_right_rounded,
                        size: 18, color: colors.outline);
                    if (MediaQuery.textScalerOf(context).scale(14) > 18 ||
                        constraints.maxWidth < 116) {
                      return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [tile, const Spacer(), chevron]),
                            const SizedBox(height: 10),
                            texts
                          ]);
                    }
                    return Row(children: [
                      tile,
                      const SizedBox(width: 10),
                      Expanded(child: texts),
                      chevron
                    ]);
                  })),
            )));
  }

  Widget _activity() => _surface(
      key: const ValueKey('home-learning-activity'),
      child: Row(children: [
        const TodayIconTile(Icons.calendar_today_rounded),
        const SizedBox(width: 10),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('学习动态',
              style: _visualTheme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          Text(
              _contextReady &&
                      _controller.contextSnapshot.todayPracticeCount != null
                  ? '今日已练 ${_controller.contextSnapshot.todayPracticeCount} 题 · 每一次练习，都让理解更进一步。'
                  : '选择题库并加载学习记录后，查看今日练习情况',
              style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: _visualTheme.colorScheme.onSurfaceVariant)),
        ])),
      ]));

  Widget _exam() => _surface(
      padding: 0,
      child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
              key: const ValueKey('home-exam-entry'),
              onTap: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const MockCenterScreen()));
                if (mounted) await _refresh();
              },
              child: Stack(children: [
                Positioned(
                    right: 20,
                    top: 0,
                    bottom: 0,
                    child: IgnorePointer(
                        child: Opacity(
                            opacity: .45,
                            child: Image.asset(
                                'assets/images/today/paper-pencil.png',
                                width: 120,
                                fit: BoxFit.contain,
                                excludeFromSemantics: true)))),
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      const TodayIconTile(Icons.description_rounded),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text('模考与试卷',
                                style: _visualTheme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 5),
                            Text('开始模考 / 生成试卷 / 历史试卷',
                                style: TextStyle(
                                    fontSize: 11,
                                    height: 1.5,
                                    color: _visualTheme
                                        .colorScheme.onSurfaceVariant)),
                          ])),
                      const Icon(Icons.chevron_right_rounded),
                    ])),
              ]))));

  Widget _tools() {
    return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
      if (widget.homeTraining != null)
        IconButton(
            key: const ValueKey('home-wrongbook-entry'),
            tooltip: '全局错题本',
            onPressed: () => _openBankDetail('🔥 全局错题本'),
            icon: const Icon(Icons.bookmark_outline_rounded)),
      TextButton.icon(
          key: const ValueKey('home-parse-action'),
          onPressed: widget.taskCenter == null
              ? null
              : () async {
                  await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => TaskCenterScreen(
                              dependencies: widget.taskCenter)));
                  if (mounted) await _refresh();
                },
          icon: Badge(
              isLabelVisible: (_taskBadge ?? 0) > 0,
              label: Text('$_taskBadge'),
              child: const Icon(Icons.task_outlined, size: 18)),
          label: const Text('解析')),
      IconButton(
          key: const ValueKey('home-import-action'),
          tooltip: '创建 / 导入',
          onPressed: _openImport,
          icon: const Icon(Icons.add_rounded)),
    ]);
  }

  Future<void> _startOrdinary(StudySessionPool pool) async {
    final bankName = _controller.contextSnapshot.bankName;
    final launcher = widget.studySessionLauncher;
    if (!_contextReady || bankName == null || launcher == null) return;
    await _controller.runFocusedStart(() async {
      final result = await launcher.launch(bankName: bankName, pool: pool);
      if (!mounted) return;
      switch (result) {
        case StudySessionReady():
          await Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => PracticePage(
                      studyActivity: StudyActivityRouteDescriptor(
                          scene: StudyActivityScene.ordinaryPractice,
                          context: StudyActivityContext(bankName: bankName)),
                      bankName: bankName,
                      usePreparedStudySession: true,
                      preparedSessionKind: AnswerAttemptSessionKind.normal,
                      practiceCommands: widget.practiceCommands)));
          if (mounted) await _refresh();
        case StudySessionEmpty():
          _showFocusedMessage('当前没有可练习的题目');
          await _refresh();
        case StudySessionUnavailable():
          _showFocusedMessage('训练准备失败，请重试');
      }
    });
  }

  void _askAssistant() => widget.onAskAssistant?.call('请根据我的学习情况，帮我制定并预览学习计划。');

  Future<void> _openPlan() async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => CurrentPlanScreen(
                controller: _controller,
                onStart: _handleFocusedStart,
                onStop: _handleFocusedStop,
                onAskAssistant: widget.onAskAssistant == null
                    ? null
                    : () {
                        Navigator.pop(context);
                        _askAssistant();
                      })));
    if (mounted) await _refresh();
  }

  /// 开始特训: fresh recomputation only. Never reuses a displayed snapshot;
  /// never persists selected IDs; never calls any provider.
  Future<void> _handleFocusedStart() async {
    final service = widget.studyPlanSelectionService;
    final launcher = widget.studyPlanSessionLauncher;
    if (service == null || launcher == null) return;
    await _controller.runFocusedStart(() async {
      final StudyPlanFocusedState state;
      try {
        state = await service.loadFocusedState();
      } catch (_) {
        if (mounted) _showFocusedMessage('特训暂时不可用，请稍后重试');
        return;
      }
      if (!mounted) return;
      switch (state) {
        case StudyPlanFocusedNoActivePlan():
          _controller.publishFocusedState(state);
          _showFocusedMessage('当前没有学习计划');
        case StudyPlanFocusedPlanUnavailable():
          _controller.publishFocusedState(state);
          _showFocusedMessage('当前计划题库已不可用');
        case StudyPlanFocusedNoCandidates():
          _controller.publishFocusedState(state);
          _showFocusedMessage('今日暂无任务');
        case StudyPlanFocusedReady(
            :final activePlan,
            :final selectedStorageIds
          ):
          final launch = await launcher.launch(selectedStorageIds);
          if (!mounted) return;
          if (launch is StudyPlanPracticeLaunchSuccess) {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PracticePage(
                  studyActivity: StudyActivityRouteDescriptor(
                    scene: StudyActivityScene.studyPlanPractice,
                    context: StudyActivityContext(
                        bankName: activePlan.bankName,
                        planId: activePlan.planId),
                  ),
                  bankName: activePlan.bankName,
                  usePreparedStudySession: true,
                  practiceCommands: widget.practiceCommands,
                ),
              ),
            );
            if (mounted) await _refresh();
          } else {
            _showFocusedMessage('特训准备失败，请重试');
          }
        case StudyPlanFocusedFailure():
          _showFocusedMessage('特训暂时不可用，请稍后重试');
      }
    });
  }

  /// 停止计划: destructive action with explicit confirmation bound to the
  /// exact [plan] observed when the confirmation was opened.
  Future<void> _handleFocusedStop(ActiveStudyPlan plan) async {
    final service = widget.studyPlanCommandService;
    if (service == null) return;
    final observedPlanId = plan.planId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('停止学习计划'),
        content: const Text(
          '只停止当前学习计划；不会删除题目、作答记录或学习历史。'
          '重要数据操作前建议先保留备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            key: const ValueKey<String>('today-focused-stop-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final result = await service.stopActivePlan(expectedPlanId: observedPlanId);
    if (!mounted) return;
    switch (result) {
      case StudyPlanStopResultSuccess():
        // Reload from live state: the no-plan surface appears.
        _loadFocusedState();
      case StudyPlanStopResultStaleActivePlan():
        // ZERO auto-retry: the plan changed under the confirmation; reload
        // current state and show a bounded message. An old confirmation must
        // never stop a newly replaced plan.
        _loadFocusedState();
        _showFocusedMessage('学习计划已变化，请重试');
      case StudyPlanStopResultFailed():
        _showFocusedMessage('停止失败，请重试');
    }
  }

  void _showFocusedMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openBankSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlanConfigScreen(currentBank: _currentBank),
      ),
    );
    if (mounted) await _refresh();
  }

  void _handleSwitchBank() {
    final callback = widget.onSwitchBank;
    if (callback != null) {
      callback();
      return;
    }
    _openBankSettings();
  }

  void _openBankDetail(String bankName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BankDetailScreen(
          bankName: bankName,
          questionListQuery: widget.questionListQuery,
          questionMutationPersistence: widget.questionMutationPersistence,
          typedAnswerPersistence: widget.typedAnswerPersistence,
          questionBankMutationPersistence:
              widget.questionBankMutationPersistence,
          practiceCommands: widget.practiceCommands,
        ),
      ),
    ).then((_) {
      if (mounted) _refresh();
    });
  }
}

class _CreateImportSheet extends StatelessWidget {
  const _CreateImportSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '创建 / 导入',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 18),
          _CreateImportOption(
            key: const ValueKey<String>('create-import-file-option'),
            icon: Icons.description_outlined,
            iconColor: colors.primary,
            title: '文件导入',
            subtitle: 'PDF、DOCX、Markdown、TXT 或已有图片',
            onTap: () => Navigator.pop(context, _CreateImportAction.file),
          ),
          const SizedBox(height: 12),
          _CreateImportOption(
            key: const ValueKey<String>('create-import-photo-option'),
            icon: Icons.photo_camera_outlined,
            iconColor: colors.primary,
            title: '拍照识题',
            subtitle: '拍摄照片，或从相册选择',
            onTap: () => Navigator.pop(context, _CreateImportAction.photo),
          ),
          const SizedBox(height: 10),
          TextButton(
            key: const ValueKey<String>('create-import-cancel'),
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}

class _CreateImportOption extends StatelessWidget {
  const _CreateImportOption({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: iconColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
