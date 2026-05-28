import 'package:flutter/material.dart';
import 'home_page.dart';
import 'data_center_screen.dart';
import 'mock_center_screen.dart';
import 'profile_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      const HomePage(),         // Tab 0
      const DataCenterScreen(), // Tab 1
      const MockCenterScreen(), // Tab 2 — 模考中心
      const ProfileScreen(),    // Tab 3
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard_rounded), label: '今日面板'),
          BottomNavigationBarItem(icon: Icon(Icons.library_books_rounded), label: '学科库'),
          BottomNavigationBarItem(icon: Icon(Icons.receipt_long_rounded), label: '模考中心'),
          BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: '我的'),
        ],
      ),
    );
  }
}
