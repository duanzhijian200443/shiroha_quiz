
import 'package:flutter/material.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/ui/pages/bank_detail_screen.dart';
import 'import_settings_screen.dart';
import '../../main.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  late Future<List<Map<String, dynamic>>> _banksFuture;

  @override
  void initState() {
    super.initState();
    _loadBanks();
    globalBankUpdateNotifier.addListener(_loadBanks);
  }

  @override
  void dispose() {
    globalBankUpdateNotifier.removeListener(_loadBanks);
    super.dispose();
  }

  void _loadBanks() {
    setState(() {
      _banksFuture = DatabaseHelper.instance.getQuestionBanksSummary();
    });
  }

  Future<void> _deleteBank(String bankName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除题库 "$bankName" 及所有记录吗？此操作不可逆！'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await DatabaseHelper.instance.deleteQuestionBank(bankName);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('题库 "$bankName" 已删除')),
        );
        _loadBanks(); // Refresh the list
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('数据中心'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_box),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ImportSettingsScreen()),
              ).then((_) => _loadBanks());
            },
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _banksFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text('加载失败: ${snapshot.error}'));
          } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('暂无题库，请先导入'));
          }

          final banks = snapshot.data!;

          return ListView.builder(
            itemCount: banks.length,
            itemBuilder: (context, index) {
              final bank = banks[index];
              final bankName = bank['bank_name'] as String;
              final totalCount = bank['total_count'] as int? ?? 0;

              return ListTile(
                leading: const Icon(Icons.library_books),
                title: Text(bankName),
                subtitle: Text('共 $totalCount 题'),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => BankDetailScreen(bankName: bankName),
                    ),
                  ).then((_) => _loadBanks());
                },
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () => _deleteBank(bankName),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
