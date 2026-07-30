import 'package:flutter/material.dart';

import '../../data/repositories/ai_engine_repository.dart';
import '../../data/repositories/question_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../main.dart';
import 'ai_settings_screen.dart';
import 'knowledge_base_screen.dart';
import 'wrong_book_page.dart';

typedef ProfileHeatmapLoader = Future<Map<DateTime, int>> Function();

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.engineRepository,
    this.heatmapLoader,
  });

  final AiEngineRepository engineRepository;
  final ProfileHeatmapLoader? heatmapLoader;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const Color _pageBackground = Color(0xFFF4F7FB);
  static const Color _primaryText = Color(0xFF17233D);
  static const Color _secondaryText = Color(0xFF73809A);
  static const Color _brandBlue = Color(0xFF4C6ED7);
  static const Color _iconBackground = Color(0xFFEEF3FF);
  static const Color _divider = Color(0xFFE8EEF7);

  Map<DateTime, int> _heatmapData = const {};
  int _totalReviewed = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final heatmap = await (widget.heatmapLoader?.call() ??
          QuestionRepository.instance.getHeatmapData());
      final total = heatmap.values.fold<int>(0, (sum, value) => sum + value);

      if (!mounted) return;
      setState(() {
        _heatmapData = heatmap;
        _totalReviewed = total;
        _isLoading = false;
      });
    } catch (error) {
      debugPrint('Profile data load failed: ${error.runtimeType}');
      if (mounted) {
        setState(() => _isLoading = false);
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
                  ? Colors.white10
                  : const Color(0xFFE9EEF6);
            } else if (count < 10) {
              cellColor = theme.primaryColor.withValues(alpha: 0.3);
            } else if (count < 30) {
              cellColor = theme.primaryColor.withValues(alpha: 0.6);
            } else if (count < 60) {
              cellColor = theme.primaryColor.withValues(alpha: 0.8);
            } else {
              cellColor = theme.primaryColor;
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
    final isDark = theme.brightness == Brightness.dark;
    final primaryText = isDark ? Colors.white : _primaryText;
    final secondaryText = isDark ? Colors.white60 : _secondaryText;

    return _SurfaceCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  radius: 27,
                  backgroundColor: Color(0xFFE8EEFC),
                  child: Icon(
                    Icons.face_retouching_natural,
                    size: 31,
                    color: _brandBlue,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Shiroha 学员',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: primaryText,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '累计完成 $_totalReviewed 道题',
                        style: TextStyle(
                          color: secondaryText,
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
                color: secondaryText,
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
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? theme.scaffoldBackgroundColor : _pageBackground,
      appBar: AppBar(
        centerTitle: true,
        title: const Text(
          '我的',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
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
                        key: const ValueKey<String>('profile-wrong-book-row'),
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
                            'profile-knowledge-base-row'),
                        icon: Icons.auto_stories_outlined,
                        title: '我的知识库',
                        subtitle: '管理个人笔记与学习资料',
                        onTap: () => _push(const KnowledgeBaseScreen()),
                      ),
                      _SettingsRow(
                        key: const ValueKey<String>('profile-ai-service-row'),
                        icon: Icons.smart_toy_outlined,
                        title: 'AI 服务',
                        subtitle: '文本解答、图片理解与文档识别',
                        onTap: () => _push(
                          AiSettingsScreen(
                            engineRepository: widget.engineRepository,
                          ),
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
                              activeTrackColor: _brandBlue,
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          color: isDark ? Colors.white70 : _ProfileScreenState._secondaryText,
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
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFE9EEF6),
        ),
        boxShadow: isDark
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
    return _SurfaceCard(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                const Divider(
                  height: 1,
                  thickness: 1,
                  indent: 64,
                  color: _ProfileScreenState._divider,
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
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: isDark
              ? _ProfileScreenState._brandBlue.withValues(alpha: 0.18)
              : _ProfileScreenState._iconBackground,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(
          icon,
          color: isDark
              ? Theme.of(context).colorScheme.primary
              : _ProfileScreenState._brandBlue,
          size: 21,
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isDark ? Colors.white : _ProfileScreenState._primaryText,
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
            color: isDark ? Colors.white60 : _ProfileScreenState._secondaryText,
            fontSize: 12,
            height: 1.3,
          ),
        ),
      ),
      trailing: trailing ??
          Icon(
            Icons.chevron_right_rounded,
            color: isDark ? Colors.white38 : const Color(0xFFA5AFC0),
          ),
      onTap: onTap,
    );
  }
}
