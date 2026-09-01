import 'package:flutter/material.dart';

import '../../application/agent/agent_config_service.dart';
import '../../application/backup/backup_restore_coordinator.dart';
import '../../data/repositories/ai_engine_repository.dart';
import '../../data/repositories/question_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../main.dart';
import 'backup/backup_restore_screen.dart';
import 'ai_settings_screen.dart';
import 'wrong_book_page.dart';

typedef ProfileHeatmapLoader = Future<Map<DateTime, int>> Function();

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.engineRepository,
    required this.agentSettingsService,
    this.heatmapLoader,
    this.backupRestore,
    this.onRestoreCompleted,
    this.onOpenFileLibrary,
  });

  final AiEngineRepository engineRepository;
  final AgentSettingsService agentSettingsService;
  final ProfileHeatmapLoader? heatmapLoader;
  final BackupRestoreCoordinator? backupRestore;
  final VoidCallback? onRestoreCompleted;
  final VoidCallback? onOpenFileLibrary;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<DateTime, int> _heatmapData = const {};
  int _totalReviewed = 0;
  int _learningDays = 0;
  bool _isLoading = true;
  String? _loadErrorMessage;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadErrorMessage = null;
      });
    }
    try {
      final heatmap = await (widget.heatmapLoader?.call() ??
          QuestionRepository.instance.getHeatmapData());
      final total = heatmap.values.fold<int>(0, (sum, value) => sum + value);
      final learningDays = heatmap.values.where((value) => value > 0).length;

      if (!mounted) return;
      setState(() {
        _heatmapData = heatmap;
        _totalReviewed = total;
        _learningDays = learningDays;
        _isLoading = false;
        _loadErrorMessage = null;
      });
    } catch (error) {
      debugPrint('Profile data load failed: ${error.runtimeType}');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadErrorMessage = '暂时无法读取学习记录';
        });
      }
    }
  }

  Future<void> _setTheme(String themeName) async {
    globalThemeNotifier.value = themeName;
    await SettingsRepository.instance.setAppTheme(themeName);
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Widget _buildHeatmap(ThemeData theme) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startDate = today.subtract(const Duration(days: 83));

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List<Widget>.generate(12, (week) {
        return Column(
          children: List<Widget>.generate(7, (day) {
            final currentDate = startDate.add(Duration(days: week * 7 + day));
            final count = _heatmapData[currentDate] ?? 0;

            final Color cellColor;
            if (count == 0) {
              cellColor = theme.brightness == Brightness.dark
                  ? theme.colorScheme.outlineVariant.withValues(alpha: 0.72)
                  : theme.colorScheme.outlineVariant;
            } else if (count < 10) {
              cellColor = theme.colorScheme.primary.withValues(alpha: 0.3);
            } else if (count < 30) {
              cellColor = theme.colorScheme.primary.withValues(alpha: 0.6);
            } else if (count < 60) {
              cellColor = theme.colorScheme.primary.withValues(alpha: 0.8);
            } else {
              cellColor = theme.colorScheme.primary;
            }

            return Padding(
              padding: const EdgeInsets.all(1.5),
              child: Container(
                key: ValueKey<String>('profile-heatmap-cell-$week-$day'),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: cellColor,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
            );
          }),
        );
      }),
    );
  }

  Widget _buildOverviewCard(ThemeData theme) {
    final colors = theme.colorScheme;

    return _SurfaceCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 27,
                  backgroundColor: colors.primaryContainer,
                  child: Icon(
                    Icons.face_retouching_natural,
                    size: 31,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              'Shiroha 学员',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.onSurface,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: colors.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '学员',
                              style: TextStyle(
                                color: colors.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '累计完成 $_totalReviewed 题 · 学习 $_learningDays 天',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '最近 12 周学习记录',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Center(child: _buildHeatmap(theme)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        centerTitle: true,
        title: const Text('我的', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        top: false,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _loadErrorMessage != null
                ? _ProfileLoadError(
                    message: _loadErrorMessage!,
                    onRetry: _loadData,
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    children: [
                      _buildOverviewCard(theme),
                      const SizedBox(height: 24),
                      const _SectionTitle('学习记录'),
                      const SizedBox(height: 8),
                      _SettingsCard(
                        children: [
                          _SettingsRow(
                            key: const ValueKey<String>(
                                'profile-wrong-book-row'),
                            icon: Icons.assignment_late_outlined,
                            title: '错题记录',
                            subtitle: '集中查看练习与考试中的错题',
                            onTap: () => _push(const WrongBookPage()),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const _SectionTitle('AI 与知识库'),
                      const SizedBox(height: 8),
                      _SettingsCard(
                        children: [
                          _SettingsRow(
                            key: const ValueKey<String>(
                                'profile-ai-service-row'),
                            icon: Icons.auto_awesome_outlined,
                            title: 'AI 服务',
                            subtitle: '探索 AI 模型与文档 AI 能力管理',
                            accentColor: theme.colorScheme.secondary,
                            onTap: () => _push(
                              AiSettingsScreen(
                                engineRepository: widget.engineRepository,
                                agentSettingsService:
                                    widget.agentSettingsService,
                              ),
                            ),
                          ),
                          _SettingsRow(
                            key: const ValueKey<String>(
                                'profile-file-library-row'),
                            icon: Icons.auto_stories_outlined,
                            title: '资料库',
                            subtitle: '管理个人笔记与学习资料（与助手共享）',
                            onTap: widget.onOpenFileLibrary ??
                                () =>
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('资料库暂不可用')),
                                    ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const _SectionTitle('设置与数据'),
                      const SizedBox(height: 8),
                      ValueListenableBuilder<String>(
                        valueListenable: globalThemeNotifier,
                        builder: (context, currentTheme, _) {
                          final isDarkTheme = currentTheme == 'dark';
                          return _SettingsCard(
                            children: [
                              if (widget.backupRestore != null)
                                _SettingsRow(
                                  key: const ValueKey<String>(
                                      'profile-backup-row'),
                                  icon: Icons.settings_backup_restore,
                                  title: '备份与数据管理',
                                  subtitle: '导出备份、恢复与清理数据',
                                  onTap: () => _push(
                                    BackupRestoreScreen(
                                      backupRestore: widget.backupRestore!,
                                      onRestoreCompleted:
                                          widget.onRestoreCompleted ?? () {},
                                    ),
                                  ),
                                ),
                              _SettingsRow(
                                key: const ValueKey<String>(
                                  'profile-appearance-row',
                                ),
                                icon: Icons.palette_outlined,
                                title: '外观设置',
                                subtitle: isDarkTheme ? '深色模式' : '浅色模式',
                                trailing: Switch(
                                  key: const ValueKey<String>(
                                    'profile-appearance-switch',
                                  ),
                                  value: isDarkTheme,
                                  activeTrackColor: theme.colorScheme.primary,
                                  onChanged: (value) =>
                                      _setTheme(value ? 'dark' : 'light'),
                                ),
                                onTap: () =>
                                    _setTheme(isDarkTheme ? 'light' : 'dark'),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _ProfileLoadError extends StatelessWidget {
  const _ProfileLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 52,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              message,
              key: const ValueKey<String>('profile-load-error'),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '请稍后重试，现有学习数据不会改变。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const ValueKey<String>('profile-load-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          color: colors.onSurfaceVariant,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: theme.brightness == Brightness.dark
            ? const []
            : [
                BoxShadow(
                  color: const Color(0xFF375078).withValues(alpha: 0.06),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: child,
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final dividerColor = Theme.of(context).colorScheme.outlineVariant;
    return _SurfaceCard(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 64,
                  color: dividerColor,
                ),
              children[index],
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.accentColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = accentColor ?? colors.primary;
    return ListTile(
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: accent.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.18 : 0.1,
          ),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, color: accent, size: 21),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.onSurface,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colors.onSurfaceVariant,
            fontSize: 12,
            height: 1.3,
          ),
        ),
      ),
      trailing: trailing ??
          Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
      onTap: onTap,
    );
  }
}
