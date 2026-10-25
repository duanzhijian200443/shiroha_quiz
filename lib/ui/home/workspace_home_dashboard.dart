import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/home_training_result.dart';
import '../../application/study_activity/study_activity_contracts.dart';
import '../../application/study_query/study_query_dtos.dart';
import '../../application/today/workspace_dashboard_query.dart';
import '../../application/u1_workspace/u1_workspace_dtos.dart';
import '../theme/shiroha_theme_tokens.dart';
import '../theme/design_tokens.dart';

/// Desktop presentation of existing learning, asset and Assistant capabilities.
class WorkspaceHomeDashboard extends StatefulWidget {
  const WorkspaceHomeDashboard({
    super.key,
    required this.snapshot,
    required this.week,
    required this.newCount,
    required this.reviewCount,
    required this.onRefresh,
    required this.onTraining,
    required this.onSpaces,
    required this.onImport,
    required this.onBanks,
    required this.onLibrary,
    required this.onParse,
    required this.onSettings,
    this.onOpenFile,
    this.onAssistant,
    this.taskCount,
    this.composer,
  });

  final WorkspaceDashboardSnapshot? snapshot;
  final HomeTrainingResult<StudyActivityWeekSnapshot>? week;
  final String newCount;
  final String reviewCount;
  final Future<void> Function() onRefresh;
  final VoidCallback onTraining, onSpaces, onImport, onBanks, onLibrary;
  final VoidCallback? onParse;
  final VoidCallback onSettings;
  final ValueChanged<String>? onOpenFile, onAssistant;
  final int? taskCount;
  final TextEditingController? composer;

  @override
  State<WorkspaceHomeDashboard> createState() => _WorkspaceHomeDashboardState();
}

class _WorkspaceHomeDashboardState extends State<WorkspaceHomeDashboard> {
  late final _composer = widget.composer ?? TextEditingController();
  final _searchInput = TextEditingController();

  @override
  void dispose() {
    if (widget.composer == null) _composer.dispose();
    _searchInput.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final input = _searchInput..clear();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 600),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: StatefulBuilder(builder: (context, update) {
              final query = input.text.trim().toLowerCase();
              final files = widget.snapshot?.recentFiles?.where(
                  (file) => file.displayName.toLowerCase().contains(query));
              final banks = widget.snapshot?.banks?.where(
                  (bank) => bank.bankName.toLowerCase().contains(query));
              return Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  key: const ValueKey('workspace-search-input'),
                  controller: input,
                  autofocus: true,
                  onChanged: (_) => update(() {}),
                  decoration: const InputDecoration(
                      hintText: '搜索题库或最近添加的资料', prefixIcon: Icon(Icons.search)),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    if (widget.snapshot == null)
                      const ListTile(title: Text('正在加载…')),
                    if (files == null && widget.snapshot != null)
                      const ListTile(title: Text('最近资料暂不可用')),
                    for (final file
                        in files?.take(20) ?? <LibraryFileSummary>[])
                      ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text(file.displayName),
                        subtitle: const Text('资料'),
                        onTap: () {
                          Navigator.pop(dialogContext);
                          widget.onOpenFile?.call(file.fileId);
                        },
                      ),
                    if (banks == null && widget.snapshot != null)
                      const ListTile(title: Text('题库目录暂不可用')),
                    for (final bank
                        in banks?.take(30) ?? <QuestionBankSummary>[])
                      ListTile(
                        leading: const Icon(Icons.grid_view_outlined),
                        title: Text(bank.bankName),
                        subtitle: Text('${bank.questionCount} 题 · 前往题库管理'),
                        onTap: () {
                          Navigator.pop(dialogContext);
                          widget.onBanks();
                        },
                      ),
                    if (files?.isEmpty == true && banks?.isEmpty == true)
                      const ListTile(title: Text('没有匹配的资料或题库')),
                  ]),
                ),
              ]);
            }),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor:
              Color.lerp(colors.surface, theme.scaffoldBackgroundColor, .4),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                    maxWidth: DesignTokens.workspaceDashboardMaxWidth),
                child: LayoutBuilder(builder: (context, constraints) {
                  final padding = constraints.maxWidth >= 800 ? 24.0 : 16.0;
                  final width = constraints.maxWidth - padding * 2;
                  final twoColumns = width >= 900 &&
                      MediaQuery.textScalerOf(context).scale(16) <= 24;
                  return Column(children: [
                    _toolbar(width, padding),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: widget.onRefresh,
                        child: SingleChildScrollView(
                          key: const ValueKey('workspace-home-scroll'),
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(padding, 0, padding, 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _hero(width),
                              const SizedBox(height: 16),
                              _shortcuts(width),
                              const SizedBox(height: 16),
                              Wrap(spacing: 16, runSpacing: 16, children: [
                                SizedBox(
                                    width:
                                        twoColumns ? (width - 16) * .58 : width,
                                    child: _activity()),
                                SizedBox(
                                    width:
                                        twoColumns ? (width - 16) * .42 : width,
                                    child: _recentFiles()),
                              ]),
                              const SizedBox(height: 16),
                              _assistant(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ]);
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(double width, double padding) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(padding, 10, padding, 14),
      child: Row(children: [
        Text('首页',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const Spacer(),
        if (width >= 700)
          SizedBox(
              width: 320,
              child: OutlinedButton.icon(
                onPressed: _search,
                icon: const Icon(Icons.search, size: 19),
                label: const Row(children: [
                  Expanded(
                      child: Text('搜索题库、最近资料…', textAlign: TextAlign.left)),
                  Text('Ctrl K', style: TextStyle(fontSize: 11)),
                ]),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.onSurfaceVariant,
                  backgroundColor: colors.surface,
                  side: BorderSide(color: colors.outlineVariant),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ))
        else
          IconButton(
              onPressed: _search,
              tooltip: '搜索',
              icon: const Icon(Icons.search)),
        const SizedBox(width: 12),
        IconButton(
          key: const ValueKey('workspace-parse-action'),
          onPressed: widget.onParse,
          tooltip: '解析任务',
          icon: Badge(
              isLabelVisible: (widget.taskCount ?? 0) > 0,
              label: Text('${widget.taskCount ?? 0}'),
              child: const Icon(Icons.notifications_none_outlined)),
        ),
        IconButton(
            onPressed: widget.onSettings,
            tooltip: '外观与设置',
            icon: const Icon(Icons.light_mode_outlined)),
      ]),
    );
  }

  Widget _hero(double width) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final compact = width < 650;
    return ClipRRect(
      key: const ValueKey('workspace-home-hero'),
      borderRadius: BorderRadius.circular(14),
      child: Stack(children: [
        Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: width * .7,
            child: Image.asset('assets/images/today/workspace-seaside.png',
                fit: BoxFit.cover,
                alignment: Alignment.centerRight,
                excludeFromSemantics: true)),
        Positioned.fill(
            child: DecoratedBox(
                decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            colors.surface,
            colors.surface.withValues(alpha: .98),
            colors.surface.withValues(alpha: dark ? .78 : .5),
            colors.surface.withValues(alpha: dark ? .5 : 0),
          ], stops: const [
            0,
            .35,
            .6,
            .85
          ]),
        ))),
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: compact ? 254 : 286),
          child: Padding(
            padding: EdgeInsets.all(compact ? 24 : 32),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('GOOD STUDY  BETTER TOMORROW',
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 3,
                      color: colors.onSurfaceVariant)),
              const SizedBox(height: 10),
              Text('Shiroha',
                  style: TextStyle(
                      fontSize: compact ? 44 : 62,
                      height: 1.05,
                      fontWeight: FontWeight.w800,
                      color: colors.onSurface)),
              const SizedBox(height: 8),
              Text('专注而温柔的学习工作空间',
                  style: TextStyle(
                      fontSize: compact ? 18 : 23, color: colors.onSurface)),
              const SizedBox(height: 10),
              Text('整理知识 · 高效练习 · 持续进步',
                  style:
                      TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: widget.onTraining,
                style: FilledButton.styleFrom(
                    minimumSize: const Size(174, 46),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('开始今日训练'),
                  SizedBox(width: 20),
                  Icon(Icons.arrow_forward, size: 20),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _shortcuts(double width) {
    final tokens = Theme.of(context).extension<ShirohaThemeTokens>()!;
    final columns = width >= 940
        ? 4
        : width >= 500
            ? 2
            : 1;
    final cardWidth = (width - (columns - 1) * 14) / columns;
    final cards = [
      (
        '今日训练',
        '定制你的专属练习',
        '新题 ${widget.newCount} · 复习 ${widget.reviewCount}',
        Icons.track_changes_outlined,
        tokens.success,
        widget.onTraining
      ),
      (
        '学习空间',
        '让知识有序生长',
        '资料 · 题库 · 对话',
        Icons.menu_book_outlined,
        tokens.featureLibrary,
        widget.onSpaces
      ),
      (
        '资料导入',
        '导入文档，整理题目',
        '支持 PDF / Word / TXT',
        Icons.cloud_upload_outlined,
        tokens.featureAi,
        widget.onImport
      ),
      (
        '题库管理',
        '管理与编辑你的题库',
        widget.snapshot?.questionCount == null
            ? '题量暂不可用'
            : '已收录 ${widget.snapshot!.questionCount} 道题',
        Icons.description_outlined,
        tokens.warning,
        widget.onBanks
      ),
    ];
    return Wrap(spacing: 14, runSpacing: 14, children: [
      for (var i = 0; i < cards.length; i++)
        SizedBox(
            width: cardWidth,
            child: _WorkspaceSurface(
              padding: EdgeInsets.zero,
              child: InkWell(
                key: ValueKey('workspace-shortcut-$i'),
                borderRadius: BorderRadius.circular(12),
                onTap: cards[i].$6,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                      color: cards[i].$5.withValues(alpha: .09),
                                      borderRadius: BorderRadius.circular(17)),
                                  child: Icon(cards[i].$4,
                                      color: cards[i].$5, size: 27)),
                              const SizedBox(width: 14),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(cards[i].$1,
                                        style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 6),
                                    Text(cards[i].$2,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: tokens.textSecondary)),
                                  ])),
                              const Icon(Icons.arrow_forward, size: 17),
                            ]),
                        const SizedBox(height: 16),
                        Text(cards[i].$3,
                            style: TextStyle(
                                fontSize: 13, color: tokens.textSecondary)),
                      ]),
                ),
              ),
            )),
    ]);
  }

  Widget _heading(String label, IconData icon, {Widget? trailing}) =>
      Row(children: [
        Icon(icon, size: 21, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700))),
        if (trailing != null) trailing,
      ]);

  Widget _activity() {
    final calendar = widget.snapshot?.calendar;
    final week = switch (widget.week) {
      HomeTrainingSuccess(:final value) => value,
      _ => null
    };
    final duration = week?.totalDurationMs;
    final durationText = duration == null
        ? '—'
        : duration > 0 && duration < 60000
            ? '<1 分钟'
            : '${duration ~/ 60000} 分钟';
    return _WorkspaceSurface(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _heading('学习动态', Icons.bar_chart_rounded,
          trailing: Text('近 12 个月',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant))),
      const SizedBox(height: 16),
      if (widget.snapshot == null)
        const LinearProgressIndicator()
      else if (calendar == null)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 26),
            child: Text('学习记录暂不可用'))
      else
        _ReviewCalendar(calendar: calendar),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, constraints) {
        final metrics = [
          ('${calendar?.learningDays ?? '—'}', '学习天数'),
          ('${calendar?.reviewCount ?? '—'}', '练习记录'),
          ('${widget.snapshot?.questionCount ?? '—'}', '题库题量'),
          (durationText, '本周学习时长'),
        ];
        final columns = constraints.maxWidth < 460 ||
                MediaQuery.textScalerOf(context).scale(14) > 19
            ? 2
            : 4;
        return Container(
          decoration: BoxDecoration(
              border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Wrap(runSpacing: 16, children: [
            for (final metric in metrics)
              SizedBox(
                  width: (constraints.maxWidth - 2) / columns,
                  child: Column(children: [
                    Text(metric.$1,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 5),
                    Text(metric.$2,
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ])),
          ]),
        );
      }),
      if (week?.recordingQuality == StudyActivityRecordingQuality.partial)
        const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('本周时长记录可能不完整', style: TextStyle(fontSize: 11))),
    ]));
  }

  Widget _recentFiles() {
    final files = widget.snapshot?.recentFiles;
    final colors = Theme.of(context).colorScheme;
    return _WorkspaceSurface(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _heading('最近资料', Icons.history_outlined,
          trailing: TextButton(
              onPressed: widget.onLibrary,
              child: const Text('查看全部  →', style: TextStyle(fontSize: 12)))),
      if (widget.snapshot == null)
        const LinearProgressIndicator()
      else if (files == null)
        const Padding(padding: EdgeInsets.all(24), child: Text('最近资料暂不可用'))
      else if (files.isEmpty)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Column(children: [
              Icon(Icons.folder_open_outlined, size: 36, color: colors.outline),
              const SizedBox(height: 12),
              const Text('还没有学习资料'),
              const SizedBox(height: 6),
              Text('导入一份资料，开始积累知识',
                  style:
                      TextStyle(color: colors.onSurfaceVariant, fontSize: 12)),
              TextButton(onPressed: widget.onImport, child: const Text('导入资料')),
            ]))
      else
        for (final file in files.take(5))
          ListTile(
              contentPadding: EdgeInsets.zero,
              minLeadingWidth: 28,
              leading: Container(
                  width: 30,
                  height: 34,
                  decoration: BoxDecoration(
                      color: colors.primaryContainer.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(6)),
                  child: Icon(Icons.description_outlined,
                      color: colors.primary, size: 20)),
              title: Text(file.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: Text('添加于 ${_date(file.createdAt.toLocal())}',
                  style: const TextStyle(fontSize: 11)),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: widget.onOpenFile == null
                  ? null
                  : () => widget.onOpenFile!(file.fileId)),
    ]));
  }

  Widget _assistant() {
    final colors = Theme.of(context).colorScheme;
    return _WorkspaceSurface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading('学习助手', Icons.auto_awesome_outlined),
      const SizedBox(height: 8),
      Text('有问题就问我，一起进步吧！',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
      const SizedBox(height: 14),
      Container(
        decoration: BoxDecoration(
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          TextField(
              key: const ValueKey('workspace-assistant-input'),
              controller: _composer,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                  hintText: '输入问题，开始学习…',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isDense: true)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: widget.onLibrary,
                  icon: const Icon(Icons.attach_file, size: 16),
                  label: const Text('查看资料')),
              OutlinedButton.icon(
                  onPressed: () {
                    _composer.text = '请根据我的学习情况，帮我制定并预览学习计划。';
                  },
                  icon: const Icon(Icons.menu_book_outlined, size: 16),
                  label: const Text('学习建议')),
            ])),
            const SizedBox(width: 12),
            IconButton.filled(
                key: const ValueKey('workspace-assistant-continue'),
                tooltip: '在助手中继续',
                onPressed: widget.onAssistant == null
                    ? null
                    : () => widget.onAssistant!(_composer.text.trim()),
                icon: const Icon(Icons.arrow_upward)),
          ]),
        ]),
      ),
    ]));
  }
}

class _WorkspaceSurface extends StatelessWidget {
  const _WorkspaceSurface(
      {required this.child, this.padding = const EdgeInsets.all(18)});
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: .6))),
        child: Padding(padding: padding, child: child),
      );
}

class _ReviewCalendar extends StatelessWidget {
  const _ReviewCalendar({required this.calendar});
  final ReviewCalendarSnapshot calendar;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final first = DateTime.utc(calendar.firstDate.year,
        calendar.firstDate.month, calendar.firstDate.day);
    final last = DateTime.utc(
        calendar.lastDate.year, calendar.lastDate.month, calendar.lastDate.day);
    final monday = first.subtract(Duration(days: first.weekday - 1));
    final weeks = (last.difference(monday).inDays + 7) ~/ 7;
    return LayoutBuilder(builder: (context, constraints) {
      final cell = (constraints.maxWidth - (weeks - 1) * 2) / weeks;
      final monthStep = constraints.maxWidth < 480 ||
              MediaQuery.textScalerOf(context).scale(10) > 15
          ? 3
          : 1;
      return Column(
          key: const ValueKey('workspace-review-calendar'),
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var week = 0; week < weeks; week++) ...[
                if (week > 0) const SizedBox(width: 2),
                Column(children: [
                  for (var day = 0; day < 7; day++)
                    Builder(builder: (context) {
                      final date = DateTime.utc(monday.year, monday.month,
                          monday.day + week * 7 + day);
                      final active =
                          !date.isBefore(first) && !date.isAfter(last);
                      final count = calendar.dailyCounts[
                              DateTime(date.year, date.month, date.day)] ??
                          0;
                      return Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Tooltip(
                            message:
                                active ? '${_date(date)} · $count 条练习记录' : '',
                            child: Semantics(
                              label:
                                  active ? '${_date(date)} $count 条练习记录' : null,
                              child: Container(
                                width: cell,
                                height: cell.clamp(5, 11),
                                decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(2),
                                    color: !active
                                        ? Colors.transparent
                                        : count == 0
                                            ? colors.surfaceContainerHighest
                                                .withValues(alpha: .7)
                                            : Color.lerp(
                                                colors.primaryContainer,
                                                colors.primary,
                                                count < 10
                                                    ? .3
                                                    : count < 30
                                                        ? .55
                                                        : .9)),
                              ),
                            ),
                          ));
                    }),
                ]),
              ],
            ]),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              for (var month = 0; month < 12; month += monthStep)
                Text('${DateTime(first.year, first.month + month).month}月',
                    style:
                        TextStyle(fontSize: 9, color: colors.onSurfaceVariant)),
            ]),
          ]);
    });
  }
}

String _date(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
