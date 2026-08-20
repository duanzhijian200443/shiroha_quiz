import 'package:flutter/material.dart';

import 'package:shiroha_quiz/ui/pages/ai_settings_screen.dart';
import 'package:shiroha_quiz/ui/pages/data_center_screen.dart';
import 'package:shiroha_quiz/ui/dependencies/ai_dependencies_scope.dart';

import 'package:shiroha_quiz/core/review_engine_service.dart';
import '../../core/state/dashboard_notifier.dart';
import 'wrong_book_page.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    this.clearAllDataAction,
    this.avatarImage,
  });

  @visibleForTesting
  final Future<void> Function()? clearAllDataAction;

  @visibleForTesting
  final ImageProvider<Object>? avatarImage;

  static const Color _bgColor = Color(0xFFF4F6FA);
  static const Color _primaryColor = Color(0xFF4C6ED7);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              const SizedBox(height: 24),
              _buildHeader(),
              const SizedBox(height: 28),
              _buildMenu(context),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 用户头像 + 名称 ----

  Widget _buildHeader() {
    return Column(
      children: [
        ClipOval(
          child: SizedBox(
            width: 80,
            height: 80,
            child: Image(
              image: avatarImage ?? const AssetImage('assets/流萤.png'),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: const Color(0xFFE8ECF4),
                child: const Icon(Icons.person, color: _primaryColor, size: 40),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Shiroha 学员',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Colors.grey.shade900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '坚持刷题，一战成硕',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
        ),
      ],
    );
  }

  // ---- 功能菜单 ----

  Widget _buildMenu(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildTile(
            icon: Icons.error_outline,
            iconColor: const Color(0xFFFF3B30),
            iconBg: const Color(0xFFFFEDEC),
            title: '错题本',
            subtitle: '按掌握程度沉淀错题，集中复习',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const WrongBookPage()),
              );
            },
          ),
          const Divider(height: 1, indent: 60),
          _buildTile(
            icon: Icons.bar_chart_rounded,
            iconColor: const Color(0xFF4C6ED7),
            iconBg: const Color(0xFFEDF1FD),
            title: '题库管理',
            subtitle: '查看各题库统计数据与管理',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DataCenterScreen()),
              );
            },
          ),
          const Divider(height: 1, indent: 60),
          _buildTile(
            icon: Icons.smart_toy,
            iconColor: Colors.blueAccent,
            iconBg: Colors.blue.shade50,
            title: 'AI 引擎配置',
            subtitle: '设置大模型 API Key 与基础路径',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AiSettingsScreen(
                    engineRepository:
                        AiDependenciesScope.of(context).engineRepository,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1, indent: 60),
          const Divider(height: 1, indent: 60),
          _buildTile(
            icon: Icons.delete_outline_rounded,
            iconColor: Colors.grey.shade600,
            iconBg: Colors.grey.shade100,
            title: '清除缓存 / 重置数据库',
            subtitle: '清空所有题库与答题记录',
            onTap: () => _confirmClear(context),
          ),
        ],
      ),
    );
  }

  Widget _buildTile({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: iconBg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: iconColor, size: 20),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.grey.shade800,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
      ),
      trailing:
          Icon(Icons.chevron_right, color: Colors.grey.shade400, size: 20),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    );
  }

  // ---- 清除确认 ----

  void _confirmClear(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认重置'),
        content: const Text(
          '这是批量永久清除：Questions、ReviewState、ReviewLog 和 '
          'AnswerAttempt 都会删除。此操作不可撤销。\n\n建议先在数据中心导出备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                final clearAll =
                    clearAllDataAction ?? ReviewEngineService().clearAllData;
                await clearAll();
                DashboardNotifier.notify();
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(
                      SnackBar(
                        content: const Text('数据已清空'),
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        margin: const EdgeInsets.all(12),
                      ),
                    );
                }
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('清除失败，请稍后重试；现有数据状态未确认改变')),
                  );
                }
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
  }
}
