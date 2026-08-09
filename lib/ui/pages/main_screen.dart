import 'package:flutter/material.dart';
import '../../application/u1_workspace/u1_workspace_facade.dart';
import 'home_page.dart';
import 'mock_center_screen.dart';
import 'profile_screen.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../assistant/assistant_workspace_shell.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, required this.u1WorkspaceFacade});

  final U1WorkspaceFacade u1WorkspaceFacade;
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final dependencies = AiDependenciesScope.of(context);
    final pages = <Widget>[
      const HomePage(), // Tab 0
      AssistantWorkspaceShell(facade: widget.u1WorkspaceFacade), // Tab 1
      const MockCenterScreen(), // Tab 2 — 模考中心
      ProfileScreen(engineRepository: dependencies.engineRepository), // Tab 3
    ];
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: Theme.of(context).colorScheme.onSurfaceVariant,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.psychology_outlined),
            activeIcon: _SelectedNavigationIcon(
              icon: Icons.psychology_outlined,
              itemKey: ValueKey<String>('main-nav-selected-home'),
            ),
            label: '今日',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.auto_awesome_outlined),
            activeIcon: _SelectedNavigationIcon(
              icon: Icons.auto_awesome_outlined,
              itemKey: ValueKey<String>('main-nav-selected-assistant'),
            ),
            label: '助手',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.pending_actions_outlined),
            activeIcon: _SelectedNavigationIcon(
              icon: Icons.pending_actions_outlined,
              itemKey: ValueKey<String>('main-nav-selected-mock'),
            ),
            label: '模考',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.school_outlined),
            activeIcon: _SelectedNavigationIcon(
              icon: Icons.school_outlined,
              itemKey: ValueKey<String>('main-nav-selected-profile'),
            ),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

class _SelectedNavigationIcon extends StatelessWidget {
  const _SelectedNavigationIcon({
    required this.icon,
    required this.itemKey,
  });

  final IconData icon;
  final Key itemKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      key: itemKey,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.primary.withValues(alpha: 0.16)
            : const Color(0xFFEAF1FF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: theme.colorScheme.primary),
    );
  }
}
