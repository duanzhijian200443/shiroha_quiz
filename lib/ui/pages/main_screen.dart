import 'package:flutter/material.dart';
import 'home_page.dart';
import 'data_center_screen.dart';
import 'mock_center_screen.dart';
import 'profile_screen.dart';
import '../dependencies/ai_dependencies_scope.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
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
      const DataCenterScreen(), // Tab 1
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
        selectedItemColor: const Color(0xFF5B8DF8),
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.psychology_outlined), label: '今日面板'),
          BottomNavigationBarItem(
              icon: Icon(Icons.my_library_books_outlined), label: '学科库'),
          BottomNavigationBarItem(
              icon: Icon(Icons.pending_actions_outlined), label: '模考中心'),
          BottomNavigationBarItem(
              icon: Icon(Icons.school_outlined), label: '我的'),
        ],
      ),
    );
  }
}
