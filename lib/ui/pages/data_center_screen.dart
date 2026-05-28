import 'package:flutter/material.dart';
import '../../core/database/database_helper.dart';
import 'bank_detail_screen.dart';
import 'import_settings_screen.dart';

class DataCenterScreen extends StatefulWidget {
  const DataCenterScreen({Key? key}) : super(key: key);

  @override
  State<DataCenterScreen> createState() => _DataCenterScreenState();
}

class _DataCenterScreenState extends State<DataCenterScreen> {
  Map<String, List<Map<String, dynamic>>> _subjectFolders = {};
  bool _isLoading = true;
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  Map<String, List<Map<String, dynamic>>> get _filteredFolders {
    if (_searchQuery.isEmpty) return _subjectFolders;
    
    final q = _searchQuery.toLowerCase();
    final Map<String, List<Map<String, dynamic>>> filtered = {};
    for (var entry in _subjectFolders.entries) {
      if (entry.key.toLowerCase().contains(q)) {
        filtered[entry.key] = entry.value;
      } else {
        final matches = entry.value.where((bank) {
          final bankName = bank['bank_name']?.toString().toLowerCase() ?? '';
          return bankName.contains(q);
        }).toList();
        if (matches.isNotEmpty) {
          filtered[entry.key] = matches;
        }
      }
    }
    return filtered;
  }

  @override
  void initState() {
    super.initState();
    _loadRealData();
  }

  Future<void> _loadRealData() async {
    setState(() => _isLoading = true);
    try {
      final data = await DatabaseHelper.instance.getSubjectTree();
      if (mounted) {
        setState(() {
          _subjectFolders = data;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('加载题库树失败: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _createNewFolder() async {
    final controller = TextEditingController();
    final folderName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建学科文件夹', style: TextStyle(fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '例如：📚 考研政治', labelText: '文件夹名称'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消', style: TextStyle(color: Colors.grey))),
          ElevatedButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('创建')),
        ],
      ),
    );

    if (folderName != null && folderName.isNotEmpty) {
      await DatabaseHelper.instance.addCustomFolder(folderName);
      await _loadRealData();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已创建文件夹: $folderName')));
    }
  }

  Future<void> _showMoveFolderDialog(String bankName) async {
    final controller = TextEditingController();
    final existingFolders = _subjectFolders.keys.where((k) => k != '📁 未分类题库').toList();

    final newFolder = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('归类题库', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('目标题库: $bankName', style: const TextStyle(fontSize: 14, color: Colors.grey)),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: '输入目标学科/文件夹',
                  hintText: '手动输入，或点击下方标签',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                autofocus: true,
              ),
              if (existingFolders.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('快速选择已有分类：', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8.0, runSpacing: 8.0,
                  children: existingFolders.map((folder) {
                    return ActionChip(
                      label: Text(folder, style: const TextStyle(fontSize: 12, color: Colors.blueAccent)),
                      backgroundColor: Colors.blue.shade50, side: BorderSide.none,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      onPressed: () { controller.text = folder; },
                    );
                  }).toList(),
                ),
              ]
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消', style: TextStyle(color: Colors.grey))),
            ElevatedButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('移动')),
          ],
        );
      },
    );

    if (newFolder != null && newFolder.isNotEmpty) {
      await DatabaseHelper.instance.updateBankFolder(bankName, newFolder);
      await _loadRealData();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已移动至: $newFolder')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 核心热修复：极致防晕影的透明灰阶体系
    final textLevel1 = isDark ? Colors.white.withOpacity(0.87) : Colors.black87;
    final textLevel2 = isDark ? Colors.white.withOpacity(0.60) : Colors.black54;
    final iconLevel3 = isDark ? Colors.white38 : Colors.black38;
    final cardBorder = isDark ? Colors.white.withOpacity(0.1) : Colors.grey.shade200;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: _isSearching 
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: TextStyle(color: textLevel1),
                decoration: InputDecoration(
                  hintText: '搜索学科或题库...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: textLevel2),
                ),
                onChanged: (val) => setState(() => _searchQuery = val),
              )
            : const Text('学科树', style: TextStyle(fontWeight: FontWeight.w800)),
        centerTitle: false,
        actions: [
          if (!_isSearching)
            IconButton(
              icon: Icon(Icons.create_new_folder_outlined, color: textLevel1),
              tooltip: '新建学科',
              onPressed: _createNewFolder,
            ),
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search, color: textLevel1),
            tooltip: _isSearching ? '取消搜索' : '搜索题库',
            onPressed: () {
              setState(() {
                if (_isSearching) {
                  _isSearching = false;
                  _searchController.clear();
                  _searchQuery = '';
                } else {
                  _isSearching = true;
                }
              });
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                if (_filteredFolders.isEmpty)
                  const Padding(padding: EdgeInsets.only(top: 32.0), child: Center(child: Text('暂无题库', style: TextStyle(color: Colors.grey))))
                else
                  ..._filteredFolders.keys.map((folderName) {
                    List<Map<String, dynamic>> banks = _filteredFolders[folderName]!;
                    return Card(
                      elevation: 0, margin: const EdgeInsets.only(bottom: 12),
                      color: theme.cardTheme.color,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: cardBorder)),
                      child: Theme(
                        data: theme.copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          initiallyExpanded: folderName == _subjectFolders.keys.first,
                          iconColor: theme.primaryColor,
                          collapsedIconColor: textLevel1,
                          textColor: theme.primaryColor,
                          collapsedTextColor: textLevel1,
                          // 注意此处不在 Text 内写死 color，交由 ExpansionTile 根据展开状态自动接管颜色变化
                          title: Text(folderName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          children: banks.map((bank) {
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                              title: Text(bank['name'] as String, style: TextStyle(fontWeight: FontWeight.w500, color: textLevel1)),
                              subtitle: Text('共 ${bank['count']} 题 · 长按移动', style: TextStyle(fontSize: 12, color: textLevel2)),
                              trailing: Icon(Icons.arrow_forward_ios_rounded, size: 14, color: iconLevel3),
                              onTap: () {
                                Navigator.push(context, MaterialPageRoute(builder: (context) => BankDetailScreen(bankName: bank['name'] as String)))
                                  .then((_) => _loadRealData()); // 退出时刷新题库概览
                              },
                              onLongPress: () => _showMoveFolderDialog(bank['name'] as String),
                            );
                          }).toList(),
                        ),
                      ),
                    );
                  }).toList(),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ImportSettingsScreen())).then((_) => _loadRealData()),
        backgroundColor: theme.primaryColor,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('导入题库', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }
}
