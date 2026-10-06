import 'package:flutter/material.dart';

import '../../application/agent/agent_config_service.dart';
import '../../application/ai_config/ai_config_service.dart';
import '../../application/backup/backup_restore_coordinator.dart';
import '../../data/repositories/question_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../main.dart';
import 'backup/backup_restore_screen.dart';
import 'ai_settings_screen.dart';
import 'wrong_book_page.dart';
import '../theme/design_tokens.dart';
import '../theme/app_theme.dart';
import '../theme/shiroha_theme_tokens.dart';

typedef ProfileHeatmapLoader = Future<Map<DateTime, int>> Function();

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.aiConfigService,
    required this.agentSettingsService,
    this.heatmapLoader,
    this.backupRestore,
    this.onRestoreCompleted,
    this.onOpenFileLibrary,
    this.appearanceSettings,
  });

  final AiConfigPresentationService aiConfigService;
  final AgentSettingsService agentSettingsService;
  final ProfileHeatmapLoader? heatmapLoader;
  final BackupRestoreCoordinator? backupRestore;
  final VoidCallback? onRestoreCompleted;
  final VoidCallback? onOpenFileLibrary;
  final SettingsRepository? appearanceSettings;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<DateTime, int> _heatmapData = const {};
  int _totalReviewed = 0;
  int _learningDays = 0;
  bool _isLoading = true;
  String? _loadErrorMessage;
  final ValueNotifier<bool> _themeSaving = ValueNotifier(false);

  @override
  void dispose() {
    _themeSaving.dispose();
    super.dispose();
  }

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
    themeName = AppTheme.normalizeName(themeName);
    if (_themeSaving.value || themeName == globalThemeNotifier.value) return;
    final previous = globalThemeNotifier.value;
    final settings = widget.appearanceSettings ?? SettingsRepository.instance;
    _themeSaving.value = true;
    globalThemeNotifier.value = themeName;
    try {
      await settings.setAppTheme(themeName);
    } catch (_) {
      // The existing repository caches before writing. Invalidate on failure.
      settings.clearCache();
      globalThemeNotifier.value = previous;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('外观保存失败，已恢复原设置，请重试')),
        );
      }
    } finally {
      if (mounted) _themeSaving.value = false;
    }
  }

  String _themeLabel(String value) => switch (AppTheme.normalizeName(value)) {
        'dark' => '深色',
        'colorful' => '彩色',
        _ => '浅色',
      };

  void _showAppearance() {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (context) => AnimatedBuilder(
        animation: Listenable.merge([globalThemeNotifier, _themeSaving]),
        builder: (context, _) => SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_themeSaving.value ? '正在保存外观…' : '外观设置',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final name in ['light', 'dark', 'colorful'])
              Semantics(
                checked:
                    AppTheme.normalizeName(globalThemeNotifier.value) == name,
                inMutuallyExclusiveGroup: true,
                child: ListTile(
                  key: ValueKey('appearance-option-$name'),
                  title: Text(_themeLabel(name)),
                  selected:
                      AppTheme.normalizeName(globalThemeNotifier.value) == name,
                  enabled: !_themeSaving.value,
                  trailing: Icon(
                      AppTheme.normalizeName(globalThemeNotifier.value) == name
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked),
                  onTap: _themeSaving.value ? null : () => _setTheme(name),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Widget _buildHeatmap(ThemeData theme) {
    final tokens = theme.extension<ShirohaThemeTokens>()!;
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
              cellColor = Color.lerp(
                  theme.colorScheme.outlineVariant, tokens.brandAccent, .30)!;
            } else if (count < 30) {
              cellColor = Color.lerp(
                  theme.colorScheme.outlineVariant, tokens.brandAccent, .55)!;
            } else if (count < 60) {
              cellColor = Color.lerp(
                  theme.colorScheme.outlineVariant, tokens.brandAccent, .78)!;
            } else {
              cellColor = tokens.brandAccent;
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
    final tokens = theme.extension<ShirohaThemeTokens>()!;

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
                  backgroundColor: tokens.brandFill,
                  child: Icon(
                    Icons.face_retouching_natural,
                    size: 31,
                    color: tokens.brandAccent,
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
                              color: tokens.subtleFill,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '学员',
                              style: TextStyle(
                                color: tokens.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
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
    final tokens = theme.extension<ShirohaThemeTokens>()!;
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        centerTitle: true,
        title: const Text('我的', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: DesignTokens.contentMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                DesignTokens.pageHorizontalPadding,
                DesignTokens.pageHorizontalPadding,
                DesignTokens.pageHorizontalPadding,
                DesignTokens.pageBottomPadding,
              ),
              children: [
                if (_isLoading)
                  const _ProfileOverviewLoading()
                else if (_loadErrorMessage case final message?)
                  _ProfileLoadError(message: message, onRetry: _loadData)
                else
                  _buildOverviewCard(theme),
                const SizedBox(height: DesignTokens.sectionGap),
                const _SectionTitle('学习记录'),
                const SizedBox(height: 8),
                _SettingsCard(
                  children: [
                    _SettingsRow(
                      key: const ValueKey<String>('profile-wrong-book-row'),
                      icon: Icons.assignment_late_outlined,
                      title: '错题记录',
                      subtitle: '集中查看练习与考试中的错题',
                      onTap: () => _push(const WrongBookPage()),
                    ),
                  ],
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                const _SectionTitle('AI 与知识库'),
                const SizedBox(height: 8),
                _SettingsCard(
                  children: [
                    _SettingsRow(
                      key: const ValueKey<String>('profile-ai-service-row'),
                      icon: Icons.auto_awesome_outlined,
                      title: 'AI 服务',
                      subtitle: '探索 AI 模型与文档 AI 能力管理',
                      accentColor: tokens.featureAi,
                      iconBackground: tokens.featureAiFill,
                      onTap: () => _push(
                        AiSettingsScreen(
                          configService: widget.aiConfigService,
                          agentSettingsService: widget.agentSettingsService,
                        ),
                      ),
                    ),
                    _SettingsRow(
                      key: const ValueKey<String>('profile-file-library-row'),
                      icon: Icons.auto_stories_outlined,
                      title: '资料库',
                      subtitle: '管理个人笔记与学习资料（与助手共享）',
                      accentColor: tokens.featureLibrary,
                      iconBackground: tokens.featureLibraryFill,
                      onTap: widget.onOpenFileLibrary ??
                          () => ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('资料库暂不可用')),
                              ),
                    ),
                  ],
                ),
                const SizedBox(height: DesignTokens.sectionGap),
                const _SectionTitle('设置与数据'),
                const SizedBox(height: 8),
                ValueListenableBuilder<String>(
                  valueListenable: globalThemeNotifier,
                  builder: (context, currentTheme, _) {
                    return _SettingsCard(
                      children: [
                        if (widget.backupRestore != null)
                          _SettingsRow(
                            key: const ValueKey<String>('profile-backup-row'),
                            icon: Icons.settings_backup_restore,
                            title: '备份与数据管理',
                            subtitle: '导出与恢复完整备份',
                            onTap: () => _push(
                              BackupRestoreScreen(
                                backupRestore: widget.backupRestore!,
                                onRestoreCompleted:
                                    widget.onRestoreCompleted ?? () {},
                              ),
                            ),
                          ),
                        _SettingsRow(
                          key: const ValueKey<String>('profile-appearance-row'),
                          icon: Icons.palette_outlined,
                          title: '外观设置',
                          subtitle: _themeLabel(currentTheme),
                          onTap: _showAppearance,
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileOverviewLoading extends StatelessWidget {
  const _ProfileOverviewLoading();

  @override
  Widget build(BuildContext context) {
    return const _SurfaceCard(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
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
    return _SurfaceCard(
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
        borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: DesignTokens.surfaceShadow(theme.brightness),
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
        borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
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
    this.accentColor,
    this.iconBackground,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? accentColor;
  final Color? iconBackground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = theme.extension<ShirohaThemeTokens>()!;
    final accent = accentColor ?? tokens.featureNeutral;
    return ListTile(
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: iconBackground ?? tokens.featureNeutralFill,
          borderRadius: BorderRadius.circular(
            DesignTokens.compactIconContainerRadius,
          ),
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
      trailing:
          Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
      onTap: onTap,
    );
  }
}
