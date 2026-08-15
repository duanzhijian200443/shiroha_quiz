import 'package:flutter/material.dart';
import 'bank_detail_screen.dart';
import 'mock_center_screen.dart';
import 'plan_config_screen.dart';
import 'practice_page.dart';
import 'task_center_screen.dart';
import '../../application/study_plan/study_plan_command_service.dart';
import '../../application/study_plan/study_plan_selection_service.dart';
import '../../core/review_engine_service.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/study_plan/active_study_plan.dart';
import '../../domain/study_plan/study_plan_values.dart';
import '../../services/study_plan/study_plan_practice_session_launcher.dart';
import '../../services/task_manager.dart';

/// Final Today mode organization (UI-R1 freeze): 普通 / 特训 / 考试.
///
/// This is Presentation-only state; it is never persisted.
enum _TodayMode { ordinary, focused, exam }

/// Focused plan-surface status derived from the typed focused state.
enum _FocusedPlanStatus { ready, noCandidates, unavailable }

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.taskManager,
    this.onSwitchBank,
    this.onPracticeRequested,
    this.studyPlanSelectionService,
    this.studyPlanCommandService,
    this.studyPlanSessionLauncher,
    this.todayActivationEpoch = 0,
  });

  final TaskManager? taskManager;
  final VoidCallback? onSwitchBank;
  final VoidCallback? onPracticeRequested;

  /// SPL-1-U0 focused seams. When null (legacy embedding), the 特训 surface
  /// shows the real no-plan state without querying. Production composition
  /// (main.dart) always wires them.
  final StudyPlanSelectionService? studyPlanSelectionService;
  final StudyPlanCommandService? studyPlanCommandService;
  final StudyPlanPracticeSessionLauncher? studyPlanSessionLauncher;

  /// Monotonic Today-activation signal owned by MainScreen: incremented each
  /// time bottom navigation transitions INTO Today. HomePage never recreates
  /// itself on epoch changes (ordinary-mode state must be preserved); it
  /// only requests a focused refresh through the safe refresh coordinator.
  final int todayActivationEpoch;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _currentBank = '点击修改选择题库';
  int _newCount = 0;
  int _reviewCount = 0;
  int _totalCount = 0;
  int _masteredCount = 0;
  bool _isLoading = true;

  /// Current Today mode; defaults to 普通. Presentation-only, never
  /// persisted. Mode switching uses an IndexedStack so each mode keeps its
  /// own state instead of being recreated.
  _TodayMode _todayMode = _TodayMode.ordinary;

  /// SPL-1-U0 focused surface state. Null means "not loaded yet".
  StudyPlanFocusedState? _focusedState;
  bool _focusedLoadScheduled = false;

  /// Bounded focused refresh coordinator:
  /// - [_focusedLoadInFlight] guards against concurrent live reads;
  /// - a request made while a load is in flight is NEVER dropped: it becomes
  ///   [_focusedRefreshPending] and a follow-up refresh is scheduled after
  ///   the in-flight load settles;
  /// - [_focusedLoadGeneration] implements latest-wins: only the newest
  ///   generation may publish its result, so an older in-flight load can
  ///   never overwrite the result of a newer required refresh.
  bool _focusedLoadInFlight = false;
  bool _focusedRefreshPending = false;
  int _focusedLoadGeneration = 0;

  /// Duplicate-start guard: while a start action is in flight no second
  /// session may be opened.
  bool _focusedStartPending = false;

  @override
  void initState() {
    super.initState();
    _loadContext();
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Today became active again (bottom navigation returned to 今日): if the
    // user is still in 特训 mode, refresh the live focused state so an
    // adopted/replaced plan appears automatically. Ordinary mode state is
    // preserved because the widget itself is never recreated.
    if (widget.todayActivationEpoch != oldWidget.todayActivationEpoch &&
        _todayMode == _TodayMode.focused) {
      _loadFocusedState();
    }
  }

  Future<void> _loadContext() async {
    setState(() => _isLoading = true);
    try {
      final bank = await SettingsRepository.instance.getCurrentBank();

      String targetBank = bank ?? '点击修改选择题库';

      int newC = 0, reviewC = 0, totalC = 0, masteredC = 0;

      if (targetBank != '点击修改选择题库') {
        final stats = await ReviewEngineService().getBankStats(targetBank);
        totalC = stats['total'] ?? 0;
        newC = stats['new_count'] ?? 0;
        reviewC = stats['review_count'] ?? 0;
        masteredC = stats['mastered_count'] ?? 0;
      }

      if (mounted) {
        setState(() {
          _currentBank = targetBank;
          _totalCount = totalC;
          _newCount = newC;
          _reviewCount = reviewC;
          _masteredCount = masteredC;
        });
      }
    } catch (e) {
      debugPrint('首页状态加载失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor =
        isDark ? theme.scaffoldBackgroundColor : const Color(0xFFF4F6FC);
    final cardColor = theme.cardTheme.color ?? theme.colorScheme.surface;
    final textColor = isDark ? Colors.white : const Color(0xFF18213A);
    final subTextColor = isDark ? Colors.white60 : const Color(0xFF78839A);
    final primaryColor = theme.colorScheme.primary;
    final taskManager = widget.taskManager ?? TaskManager.instance;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text.rich(
          key: const ValueKey<String>('home-brand-title'),
          TextSpan(
            children: [
              TextSpan(
                text: 'Shiroha',
                style: TextStyle(color: textColor),
              ),
              TextSpan(
                text: ' Quiz',
                style: TextStyle(color: primaryColor),
              ),
            ],
          ),
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: bgColor,
        surfaceTintColor: Colors.transparent,
        leading: AnimatedBuilder(
          animation: taskManager,
          builder: (context, child) {
            final count = taskManager.processingCount;
            return IconButton(
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(Icons.swap_vert_rounded, color: textColor, size: 28),
                  if (count > 0)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 16,
                          minHeight: 16,
                        ),
                        child: Text(
                          '$count',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                ],
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const TaskCenterScreen(),
                  ),
                );
              },
            );
          },
        ),
        actions: const [SizedBox(width: 56)],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              top: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                    child: _buildModeSelector(),
                  ),
                  Expanded(
                    child: IndexedStack(
                      index: _todayMode.index,
                      children: <Widget>[
                        _buildOrdinaryMode(
                          cardColor,
                          textColor,
                          subTextColor,
                          primaryColor,
                        ),
                        _buildFocusedMode(textColor, subTextColor),
                        const MockCenterScreen(
                          embedded: true,
                          key: ValueKey<String>('today-exam-surface'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// Compact three-option Today mode selector (普通 / 特训 / 考试). Stable
  /// keys are provided for acceptance tests on narrow viewports.
  Widget _buildModeSelector() {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<_TodayMode>(
        segments: const <ButtonSegment<_TodayMode>>[
          ButtonSegment<_TodayMode>(
            value: _TodayMode.ordinary,
            label: KeyedSubtree(
              key: ValueKey<String>('today-mode-ordinary'),
              child: Text('普通'),
            ),
          ),
          ButtonSegment<_TodayMode>(
            value: _TodayMode.focused,
            label: KeyedSubtree(
              key: ValueKey<String>('today-mode-focused'),
              child: Text('特训'),
            ),
          ),
          ButtonSegment<_TodayMode>(
            value: _TodayMode.exam,
            label: KeyedSubtree(
              key: ValueKey<String>('today-mode-exam'),
              child: Text('考试'),
            ),
          ),
        ],
        selected: <_TodayMode>{_todayMode},
        onSelectionChanged: (Set<_TodayMode> selection) {
          final mode = selection.single;
          setState(() => _todayMode = mode);
          // 特训 loads its live focused snapshot on entry.
          if (mode == _TodayMode.focused) _loadFocusedState();
        },
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          textStyle: WidgetStatePropertyAll<TextStyle>(
            TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  /// 普通: existing regular-learning Presentation continuation.
  Widget _buildOrdinaryMode(
    Color cardColor,
    Color textColor,
    Color subTextColor,
    Color primaryColor,
  ) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          sliver: SliverList.list(
            children: [
              _buildBankCard(
                cardColor,
                textColor,
                subTextColor,
                primaryColor,
              ),
              const SizedBox(height: 18),
              _buildTrainingCard(
                cardColor,
                textColor,
                subTextColor,
                primaryColor,
              ),
            ],
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
            child: _buildReviewState(
              textColor,
              subTextColor,
              primaryColor,
            ),
          ),
        ),
      ],
    );
  }

  /// 特训: consumes only a real ActiveStudyPlan (SPL-1-U0). Without a plan a
  /// genuine no-plan state is shown — never fabricated counts or
  /// recommendations, and no provider call ever happens.
  Widget _buildFocusedMode(Color textColor, Color subTextColor) {
    if (_focusedState == null) {
      _scheduleFocusedLoad();
      return const Center(child: CircularProgressIndicator());
    }
    return switch (_focusedState!) {
      StudyPlanFocusedNoActivePlan() =>
        _buildFocusedNoPlan(textColor, subTextColor),
      StudyPlanFocusedPlanUnavailable(:final activePlan) =>
        _buildFocusedPlanCard(
          textColor,
          subTextColor,
          activePlan,
          status: _FocusedPlanStatus.unavailable,
          selectedCount: null,
          advisory: const StudyPlanFocusedAdvisory(
            masteryReached: false,
            horizonElapsed: false,
          ),
        ),
      StudyPlanFocusedNoCandidates(:final activePlan, :final advisory) =>
        _buildFocusedPlanCard(
          textColor,
          subTextColor,
          activePlan,
          status: _FocusedPlanStatus.noCandidates,
          selectedCount: null,
          advisory: advisory,
        ),
      StudyPlanFocusedReady(
        :final activePlan,
        :final selectedStorageIds,
        :final advisory
      ) =>
        _buildFocusedPlanCard(
          textColor,
          subTextColor,
          activePlan,
          status: _FocusedPlanStatus.ready,
          selectedCount: selectedStorageIds.length,
          advisory: advisory,
        ),
      StudyPlanFocusedFailure() =>
        _buildFocusedFailure(textColor, subTextColor),
    };
  }

  void _scheduleFocusedLoad() {
    if (_focusedLoadScheduled) return;
    _focusedLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusedLoadScheduled = false;
      _loadFocusedState();
    });
  }

  /// Loads the live focused snapshot through the bounded refresh
  /// coordinator. Every call re-queries live state; the Start action
  /// re-invokes this (or a fresh selection) and never reuses a previously
  /// displayed snapshot.
  ///
  /// Safety guarantees:
  /// - a request made while a load is in flight is NEVER dropped: it is
  ///   recorded as pending and a follow-up refresh runs after the in-flight
  ///   load settles;
  /// - the pending request immediately invalidates the in-flight load's
  ///   generation, so an older in-flight load can never publish (or overwrite
  ///   the result of) a newer required refresh.
  Future<void> _loadFocusedState() async {
    if (_focusedLoadInFlight) {
      _focusedRefreshPending = true;
      _focusedLoadGeneration++;
      return;
    }
    _focusedLoadInFlight = true;
    final generation = ++_focusedLoadGeneration;
    try {
      final service = widget.studyPlanSelectionService;
      if (service == null) {
        if (mounted && generation == _focusedLoadGeneration) {
          setState(() => _focusedState = const StudyPlanFocusedNoActivePlan());
        }
        return;
      }
      try {
        final state = await service.loadFocusedState();
        if (mounted && generation == _focusedLoadGeneration) {
          setState(() => _focusedState = state);
        }
      } catch (_) {
        if (mounted && generation == _focusedLoadGeneration) {
          setState(() => _focusedState = const StudyPlanFocusedFailure(
                StudyPlanFocusedFailureKind.internalError,
              ));
        }
      }
    } finally {
      _focusedLoadInFlight = false;
      if (_focusedRefreshPending) {
        _focusedRefreshPending = false;
        // Start the required follow-up refresh INDEPENDENTLY of frame
        // production. A post-frame callback does not by itself schedule a
        // frame, so a slow stale load finishing after all current
        // frame/animation activity could leave the follow-up waiting until
        // an unrelated future frame. A microtask begins the follow-up on the
        // current event-loop turn instead; the latest-wins generation guard
        // already ensured the settled load published nothing stale.
        Future<void>.microtask(() {
          if (!mounted) return;
          _loadFocusedState();
        });
      }
    }
  }

  /// 特训 without an adopted plan: genuine no-plan state, no fake counts.
  Widget _buildFocusedNoPlan(Color textColor, Color subTextColor) {
    return Center(
      key: const ValueKey<String>('today-focused-unavailable'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.assignment_outlined, size: 56, color: subTextColor),
            const SizedBox(height: 16),
            Text(
              '特训需要学习计划',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: textColor,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '尚未采用学习计划。\n请先在助手中制定并采用学习计划。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: subTextColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Bounded infrastructure failure surface. No raw database/provider text is
  /// ever shown.
  Widget _buildFocusedFailure(Color textColor, Color subTextColor) {
    return Center(
      key: const ValueKey<String>('today-focused-failure'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, size: 56, color: subTextColor),
            const SizedBox(height: 16),
            Text(
              '特训暂时不可用，请稍后重试',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey<String>('today-focused-retry'),
              onPressed: _loadFocusedState,
              child: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }

  /// Compact real plan surface: bank, goal, daily target, priority, horizon,
  /// current selected workload and Start/Stop actions. Advisory states are
  /// display-only and never deactivate the plan.
  Widget _buildFocusedPlanCard(
    Color textColor,
    Color subTextColor,
    ActiveStudyPlan plan, {
    required _FocusedPlanStatus status,
    required int? selectedCount,
    required StudyPlanFocusedAdvisory advisory,
  }) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final cardColor = theme.cardTheme.color ?? theme.colorScheme.surface;
    final priorityLabel = switch (plan.priority) {
      StudyPlanPriority.balanced => '均衡',
      StudyPlanPriority.dueFirst => '到期优先',
      StudyPlanPriority.weakFirst => '薄弱优先',
      StudyPlanPriority.newFirst => '新题优先',
    };
    final statusLine = switch (status) {
      _FocusedPlanStatus.ready => '今日可特训：$selectedCount 题',
      _FocusedPlanStatus.noCandidates => '今日暂无任务',
      _FocusedPlanStatus.unavailable => '当前计划题库已不可用',
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Container(
        key: const ValueKey<String>('today-focused-plan-card'),
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: primaryColor.withValues(alpha: 0.08),
          ),
          boxShadow: [
            BoxShadow(
              color: primaryColor.withValues(alpha: 0.08),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.flag_rounded, color: primaryColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '学习计划',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: textColor,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey<String>('today-focused-stop'),
                  onPressed: () => _handleFocusedStop(plan),
                  style: TextButton.styleFrom(foregroundColor: subTextColor),
                  child: const Text('停止计划'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildFocusedPlanInfo('题库', plan.bankName, textColor, subTextColor),
            if (plan.goal != null) ...[
              const SizedBox(height: 8),
              _buildFocusedPlanInfo('目标', plan.goal!, textColor, subTextColor),
            ],
            const SizedBox(height: 8),
            _buildFocusedPlanInfo(
                '每日特训量', '${plan.dailyTarget} 题', textColor, subTextColor),
            const SizedBox(height: 8),
            _buildFocusedPlanInfo(
                '优先级', priorityLabel, textColor, subTextColor),
            if (plan.horizonDays != null) ...[
              const SizedBox(height: 8),
              _buildFocusedPlanInfo(
                  '期限', '${plan.horizonDays} 天', textColor, subTextColor),
            ],
            const SizedBox(height: 16),
            Container(
              key: const ValueKey<String>('today-focused-status'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: status == _FocusedPlanStatus.ready
                    ? primaryColor.withValues(alpha: 0.10)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                statusLine,
                style: TextStyle(
                  color: status == _FocusedPlanStatus.ready
                      ? primaryColor
                      : textColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (advisory.masteryReached || advisory.horizonElapsed) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (advisory.masteryReached)
                    _buildFocusedAdvisoryChip('已掌握全部题目', primaryColor),
                  if (advisory.horizonElapsed)
                    _buildFocusedAdvisoryChip('计划期已结束', primaryColor),
                ],
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                key: const ValueKey<String>('today-focused-start'),
                onPressed: status == _FocusedPlanStatus.unavailable
                    ? null
                    : _handleFocusedStart,
                style: FilledButton.styleFrom(
                  backgroundColor: primaryColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.play_circle_fill_rounded),
                label: const Text(
                  '开始特训',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFocusedAdvisoryChip(String label, Color primaryColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: primaryColor.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: primaryColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildFocusedPlanInfo(
    String label,
    String value,
    Color textColor,
    Color subTextColor,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: TextStyle(color: subTextColor, fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: textColor,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// 开始特训: fresh recomputation only. Never reuses a displayed snapshot;
  /// never persists selected IDs; never calls any provider.
  Future<void> _handleFocusedStart() async {
    final service = widget.studyPlanSelectionService;
    final launcher = widget.studyPlanSessionLauncher;
    if (service == null || launcher == null) return;
    if (_focusedStartPending) return; // duplicate start action prevention
    _focusedStartPending = true;
    try {
      final state = await service.loadFocusedState();
      if (!mounted) return;
      switch (state) {
        case StudyPlanFocusedNoActivePlan():
          setState(() => _focusedState = state);
          _showFocusedMessage('当前没有学习计划');
        case StudyPlanFocusedPlanUnavailable():
          setState(() => _focusedState = state);
          _showFocusedMessage('当前计划题库已不可用');
        case StudyPlanFocusedNoCandidates():
          setState(() => _focusedState = state);
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
                  bankName: activePlan.bankName,
                  usePreparedStudySession: true,
                ),
              ),
            );
            if (mounted) _loadFocusedState();
          } else {
            _showFocusedMessage('特训准备失败，请重试');
          }
        case StudyPlanFocusedFailure():
          _showFocusedMessage('特训暂时不可用，请稍后重试');
      }
    } finally {
      _focusedStartPending = false;
    }
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
        content: const Text('确定停止当前学习计划？'),
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

  Widget _buildBankCard(
    Color cardColor,
    Color textColor,
    Color subTextColor,
    Color primaryColor,
  ) {
    final hasSelectedBank = _currentBank != '点击修改选择题库';
    final title = hasSelectedBank ? _currentBank : '请选择题库';
    final statusText = _totalCount == 0
        ? '暂无学习记录'
        : (_masteredCount == _totalCount ? '已完成本题库' : '学习进行中');

    return Container(
      key: const ValueKey<String>('home-bank-card'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: primaryColor.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 58,
            height: 68,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  primaryColor.withValues(alpha: 0.82),
                  primaryColor,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: primaryColor.withValues(alpha: 0.22),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: const Center(
              child: Icon(
                Icons.menu_book_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      key: const ValueKey<String>('home-switch-bank'),
                      onPressed: _handleSwitchBank,
                      style: TextButton.styleFrom(
                        foregroundColor: subTextColor,
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '切换',
                            style: TextStyle(
                              color: subTextColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: subTextColor,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: _totalCount == 0
                        ? 0
                        : (_masteredCount / _totalCount).clamp(0, 1),
                    backgroundColor: primaryColor.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    minHeight: 7,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  runSpacing: 4,
                  spacing: 12,
                  children: [
                    Text(
                      statusText,
                      style: TextStyle(
                        color: subTextColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      '已掌握 $_masteredCount / $_totalCount',
                      style: TextStyle(
                        color: subTextColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrainingCard(
    Color cardColor,
    Color textColor,
    Color subTextColor,
    Color primaryColor,
  ) {
    return Container(
      key: const ValueKey<String>('home-training-card'),
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: primaryColor.withValues(alpha: 0.07),
        ),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withValues(alpha: 0.07),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '今日训练',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: textColor,
            ),
          ),
          const SizedBox(height: 16),
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: Ink(
              height: 56,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    primaryColor,
                    themeSafeLerp(primaryColor, Colors.lightBlue, 0.2),
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.25),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: InkWell(
                key: const ValueKey<String>('home-start-training'),
                onTap: _handlePracticeRequest,
                borderRadius: BorderRadius.circular(16),
                child: const Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '开始今日训练',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _buildTaskEntry(
                    key: const ValueKey<String>('home-new-task'),
                    title: '新题挑战',
                    countText: '$_newCount 道新题',
                    icon: Icons.auto_stories_rounded,
                    accentColor: const Color(0xFF4CAFC8),
                    accentBackground: const Color(0xFFE8F8FC),
                    textColor: textColor,
                    subTextColor: subTextColor,
                    onTap: _handlePracticeRequest,
                  ),
                ),
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: subTextColor.withValues(alpha: 0.16),
                ),
                Expanded(
                  child: _buildTaskEntry(
                    key: const ValueKey<String>('home-review-task'),
                    title: '复习巩固',
                    countText: '$_reviewCount 道待复习',
                    icon: Icons.fact_check_outlined,
                    accentColor: const Color(0xFFE99042),
                    accentBackground: const Color(0xFFFFF1E5),
                    textColor: textColor,
                    subTextColor: subTextColor,
                    onTap: _handlePracticeRequest,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskEntry({
    required Key key,
    required String title,
    required String countText,
    required IconData icon,
    required Color accentColor,
    required Color accentBackground,
    required Color textColor,
    required Color subTextColor,
    required VoidCallback onTap,
  }) {
    return Material(
      key: key,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: accentBackground,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: accentColor, size: 23),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                          letterSpacing: 0.15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        countText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: subTextColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReviewState(
    Color textColor,
    Color subTextColor,
    Color primaryColor,
  ) {
    if (_reviewCount > 0) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 62,
              color: primaryColor.withValues(alpha: 0.48),
            ),
            const SizedBox(height: 14),
            Text(
              '继续保持学习！',
              style: TextStyle(
                color: textColor,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '今日有 $_reviewCount 道题等待复习',
              textAlign: TextAlign.center,
              style: TextStyle(color: subTextColor, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 100,
            height: 84,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.menu_book_rounded,
                  size: 68,
                  color: primaryColor.withValues(alpha: 0.28),
                ),
                Positioned(
                  right: 7,
                  top: 5,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: primaryColor.withValues(alpha: 0.26),
                      ),
                    ),
                    child: Icon(
                      Icons.schedule_rounded,
                      size: 24,
                      color: primaryColor.withValues(alpha: 0.62),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '暂无待复习题目',
            style: TextStyle(
              color: textColor,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            '完成新题或产生错题后，将自动生成复习任务',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: subTextColor,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openBankSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlanConfigScreen(currentBank: _currentBank),
      ),
    );
    await _loadContext();
  }

  void _handleSwitchBank() {
    final callback = widget.onSwitchBank;
    if (callback != null) {
      callback();
      return;
    }
    _openBankSettings();
  }

  void _handlePracticeRequest() {
    final callback = widget.onPracticeRequested;
    if (callback != null) {
      callback();
      return;
    }
    _gotoPractice();
  }

  Color themeSafeLerp(Color from, Color to, double amount) {
    return Color.lerp(from, to, amount) ?? from;
  }

  void _gotoPractice() {
    if (_currentBank == '点击修改选择题库') {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先选择题库')));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => BankDetailScreen(bankName: _currentBank)),
    ).then((_) => _loadContext());
  }
}
