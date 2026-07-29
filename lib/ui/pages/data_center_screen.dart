import 'package:flutter/material.dart';
import '../../data/models/subject_tree_index.dart';
import '../../data/repositories/question_repository.dart';
import '../../services/latex_migration_service.dart';
import '../dependencies/ai_dependencies_scope.dart';
import 'bank_detail_screen.dart';
import 'import_settings_screen.dart';

class DataCenterScreen extends StatefulWidget {
  const DataCenterScreen({Key? key}) : super(key: key);

  @override
  State<DataCenterScreen> createState() => _DataCenterScreenState();
}

class _DataCenterScreenState extends State<DataCenterScreen> {
  SubjectTreeIndex? _subjectTreeIndex;
  bool _isLoading = true;
  bool _isSearching = false;
  bool _isMigrating = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  List<SubjectFolderNode> get _visibleFolders {
    final index = _subjectTreeIndex;
    if (index == null) return const [];

    final folders = index.foldersByName.values.toList();
    if (_searchQuery.trim().isEmpty) return folders;

    final query = _searchQuery.trim().toLowerCase();

    return folders
        .map((folder) {
          if (folder.name.toLowerCase().contains(query)) {
            return folder;
          }

          final matchedBanks = folder.banks
              .where((bank) => bank.name.toLowerCase().contains(query))
              .toList();

          if (matchedBanks.isEmpty) return null;

          return folder.copyWithBanks(matchedBanks);
        })
        .whereType<SubjectFolderNode>()
        .toList();
  }

  String? get _firstFolderName {
    final index = _subjectTreeIndex;
    if (index == null || index.foldersByName.isEmpty) return null;
    return index.foldersByName.keys.first;
  }

  @override
  void initState() {
    super.initState();
    _loadRealData();
  }

  Future<void> _loadRealData() async {
    setState(() => _isLoading = true);
    try {
      final data = await QuestionRepository.instance.getSubjectTreeIndex();
      if (mounted) {
        setState(() {
          _subjectTreeIndex = data;
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
        title: const Text('新建学科文件夹',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          decoration:
              const InputDecoration(hintText: '例如：📚 考研政治', labelText: '文件夹名称'),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('创建')),
        ],
      ),
    );

    if (folderName != null && folderName.isNotEmpty) {
      await QuestionRepository.instance.addCustomFolder(folderName);
      await _loadRealData();
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已创建文件夹: $folderName')));
    }
  }

  Future<void> _runLatexMigration() async {
    // 确认对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修复历史 LaTeX 数据',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text(
          '此操作将扫描所有题目，对含有裸露 LaTeX 命令的字段调用 AI 引擎添加正确的定界符。\n\n'
          '• 仅修改未被正确包裹的公式\n'
          '• 不会修改公式内容本身\n'
          '• 需要消耗少量 AI Token\n\n'
          '确认开始？',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始修复')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 进度日志弹窗
    final logLines = <String>[];
    late StateSetter setDialogState;

    setState(() => _isMigrating = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState2) {
          setDialogState = setState2;
          return AlertDialog(
            title: Row(
              children: [
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                const Text('正在修复...', style: TextStyle(fontSize: 16)),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 280,
              child: ListView.builder(
                itemCount: logLines.length,
                itemBuilder: (_, i) => Text(
                  logLines[i],
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            ),
          );
        },
      ),
    );

    final result = await LatexMigrationService(
      engineRepository: AiDependenciesScope.of(context).engineRepository,
    ).runMigration(
      onProgress: (processed, total, status) {
        setDialogState(() => logLines.add(status));
      },
    );

    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop(); // 关闭进度弹窗
      setState(() => _isMigrating = false);
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(result.success ? '✅ 修复完成' : '⚠️ 部分失败',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          content: Text(result.message),
          actions: [
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('确定'))
          ],
        ),
      );
    }
  }

  Future<void> _showMoveFolderDialog(String bankName) async {
    final controller = TextEditingController();
    final existingFolders =
        _subjectTreeIndex?.availableFolders.toList() ?? const <String>[];

    final newFolder = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('归类题库',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('目标题库: $bankName',
                  style: const TextStyle(fontSize: 14, color: Colors.grey)),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: '输入目标学科/文件夹',
                  hintText: '手动输入，或点击下方标签',
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                autofocus: true,
              ),
              if (existingFolders.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('快速选择已有分类：',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8.0,
                  runSpacing: 8.0,
                  children: existingFolders.map((folder) {
                    return ActionChip(
                      label: Text(folder,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.blueAccent)),
                      backgroundColor: Colors.blue.shade50,
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      onPressed: () {
                        controller.text = folder;
                      },
                    );
                  }).toList(),
                ),
              ]
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, controller.text.trim()),
                child: const Text('移动')),
          ],
        );
      },
    );

    if (newFolder != null && newFolder.isNotEmpty) {
      await QuestionRepository.instance.updateBankFolder(bankName, newFolder);
      await _loadRealData();
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已移动至: $newFolder')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 核心热修复：极致防晕影的透明灰阶体系
    final textLevel1 =
        isDark ? Colors.white.withValues(alpha: 0.87) : Colors.black87;
    final textLevel2 =
        isDark ? Colors.white.withValues(alpha: 0.60) : Colors.black54;
    final iconLevel3 = isDark ? Colors.white38 : Colors.black38;
    final cardBorder =
        isDark ? Colors.white.withValues(alpha: 0.1) : Colors.grey.shade200;

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
          if (!_isSearching)
            IconButton(
              icon: _isMigrating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.auto_fix_high_outlined, color: textLevel1),
              tooltip: '一键修复历史 LaTeX',
              onPressed: _isMigrating ? null : _runLatexMigration,
            ),
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search,
                color: textLevel1),
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
                if (_visibleFolders.isEmpty)
                  const Padding(
                      padding: EdgeInsets.only(top: 32.0),
                      child: Center(
                          child: Text('暂无题库',
                              style: TextStyle(color: Colors.grey))))
                else
                  ..._visibleFolders.map((folder) {
                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 12),
                      color: theme.cardTheme.color,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: cardBorder)),
                      child: Theme(
                        data: theme.copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          initiallyExpanded: folder.name == _firstFolderName,
                          iconColor: theme.primaryColor,
                          collapsedIconColor: textLevel1,
                          textColor: theme.primaryColor,
                          collapsedTextColor: textLevel1,
                          // 注意此处不在 Text 内写死 color，交由 ExpansionTile 根据展开状态自动接管颜色变化
                          title: Text(folder.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16)),
                          children: folder.banks.map((bank) {
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 4),
                              title: Text(bank.name,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w500,
                                      color: textLevel1)),
                              subtitle: Text('共 ${bank.count} 题 · 长按移动',
                                  style: TextStyle(
                                      fontSize: 12, color: textLevel2)),
                              trailing: Icon(Icons.arrow_forward_ios_rounded,
                                  size: 14, color: iconLevel3),
                              onTap: () {
                                Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (context) =>
                                                BankDetailScreen(
                                                    bankName: bank.name)))
                                    .then((_) => _loadRealData()); // 退出时刷新题库概览
                              },
                              onLongPress: () =>
                                  _showMoveFolderDialog(bank.name),
                            );
                          }).toList(),
                        ),
                      ),
                    );
                  }).toList(),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ImportSettingsScreen()))
            .then((_) => _loadRealData()),
        backgroundColor: theme.primaryColor,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('导入题库',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }
}
