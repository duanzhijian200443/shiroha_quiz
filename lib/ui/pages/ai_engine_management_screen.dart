import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../data/repositories/ai_engine_repository.dart';
import '../../data/models/ai_engine_profile.dart';

class AiEngineManagementScreen extends StatefulWidget {
  final String engineType; // 'text'、'vision' 或 'ocr'
  final AiEngineRepository engineRepository;

  const AiEngineManagementScreen({
    super.key,
    required this.engineType,
    required this.engineRepository,
  });
  @override
  State<AiEngineManagementScreen> createState() =>
      _AiEngineManagementScreenState();
}

class _AiEngineManagementScreenState extends State<AiEngineManagementScreen> {
  List<AiEngineProfile> _engines = [];
  String? _currentId;

  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _baseUrlCtrl = TextEditingController();
  final TextEditingController _modelCtrl = TextEditingController();

  double _temperature = 0.7;
  String _reasoningEffort = '';
  bool _isLoading = true;
  String _selectedProvider = '自定义 (Custom)';

  final Map<String, String> _providers = {
    '自定义 (Custom)': '',
    'Google AI Studio (Gemini)':
        'https://generativelanguage.googleapis.com/v1beta',
    '智谱清言 (GLM)': 'https://open.bigmodel.cn/api/paas',
    'DeepSeek 官方': 'https://api.deepseek.com',
    '硅基流动 (SiliconFlow)': 'https://api.siliconflow.cn',
    '小米大模型 (MiMO)': 'https://api.xiaomimimo.com/v1',
    'OpenAI / 第三方中转': 'https://api.openai.com/v1',
    'Ollama (本地/模拟器)': 'http://10.0.2.2:11434/v1',
  };

  bool get _isOcrEngine => widget.engineType == 'ocr';

  String _screenTitle() => switch (widget.engineType) {
        'text' => '文本逻辑引擎',
        'vision' => '多模态视觉引擎',
        'ocr' => '文档 OCR 解析引擎',
        _ => 'AI 引擎',
      };

  String _defaultModelForProvider(String provider) {
    if (_isOcrEngine) {
      return 'glm-ocr';
    }
    if (provider.contains('Gemini')) return 'gemini-1.5-flash';
    if (provider.contains('智谱')) return 'glm-4-flash';
    if (provider.contains('DeepSeek')) return 'deepseek-chat';
    if (provider.contains('SiliconFlow')) return 'deepseek-ai/DeepSeek-V3';
    return '';
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final engineTypeEnum = AiEngineType.fromDbValue(widget.engineType);
      final data = await widget.engineRepository.getEngines(engineTypeEnum);
      final active = _isOcrEngine
          ? await widget.engineRepository.getActiveOcrEngine()
          : await widget.engineRepository.getActiveEngine(engineTypeEnum);

      if (mounted) {
        setState(() {
          _engines = data;
          if (active == null && data.isNotEmpty) {
            _currentId = data.first.id;
            widget.engineRepository
                .setActiveEngine(_currentId!, engineTypeEnum);
          } else {
            _currentId = active?.id;
          }
          if (_currentId != null) _populateForm(_currentId!);
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('引擎数据加载失败: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _populateForm(String id) {
    final engine = _engines.where((e) => e.id == id).firstOrNull;
    if (engine == null) return;
    setState(() {
      _apiKeyCtrl.text = engine.apiKey;
      _baseUrlCtrl.text = engine.baseUrl;
      _modelCtrl.text = engine.modelName;
      _temperature = engine.temperature;
      _reasoningEffort = engine.reasoningEffort;
    });
  }

  void _clearInputs() {
    setState(() {
      _currentId = null;
      _apiKeyCtrl.clear();
      _baseUrlCtrl.clear();
      _modelCtrl.clear();
      if (_isOcrEngine) {
        _selectedProvider = '智谱清言 (GLM)';
        _baseUrlCtrl.text = _providers[_selectedProvider] ?? '';
      }
      _temperature = _isOcrEngine ? 0.0 : 0.7;
      _reasoningEffort = '';
      _modelCtrl.text = _defaultModelForProvider(_selectedProvider);
    });
  }

  Future<void> _handleSave() async {
    try {
      if (_currentId == null) {
        final nameCtrl = TextEditingController();
        final savedName = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('命名新配置',
                style: TextStyle(fontWeight: FontWeight.bold)),
            content: TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '如：我的顶配模型')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(context, nameCtrl.text.trim()),
                  child: const Text('保存')),
            ],
          ),
        );
        if (savedName == null || savedName.isEmpty) return;

        final newId = DateTime.now().millisecondsSinceEpoch.toString();
        final engineTypeEnum = AiEngineType.fromDbValue(widget.engineType);
        final profile = AiEngineProfile(
          id: newId,
          engineType: engineTypeEnum,
          name: savedName,
          apiKey: _apiKeyCtrl.text.trim(),
          baseUrl: _baseUrlCtrl.text.trim(),
          modelName: _modelCtrl.text.trim().isNotEmpty
              ? _modelCtrl.text.trim()
              : _defaultModelForProvider(_selectedProvider),
          temperature: _temperature,
          reasoningEffort: _reasoningEffort,
          isActive: true,
        );
        await widget.engineRepository.saveEngine(profile);
        await widget.engineRepository.setActiveEngine(newId, engineTypeEnum);
        await _loadData();
        setState(() => _currentId = newId);
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已新建配置！')));
      } else {
        final currentEngine = _engines.firstWhere((e) => e.id == _currentId);
        final engineTypeEnum = AiEngineType.fromDbValue(widget.engineType);
        final profile = AiEngineProfile(
          id: _currentId!,
          engineType: engineTypeEnum,
          name: currentEngine.name,
          apiKey: _apiKeyCtrl.text.trim(),
          baseUrl: _baseUrlCtrl.text.trim(),
          modelName: _modelCtrl.text.trim().isNotEmpty
              ? _modelCtrl.text.trim()
              : _defaultModelForProvider(_selectedProvider),
          temperature: _temperature,
          reasoningEffort: _reasoningEffort,
          isActive: true,
        );
        await widget.engineRepository.saveEngine(profile);
        await widget.engineRepository
            .setActiveEngine(_currentId!, engineTypeEnum);
        await _loadData();
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('配置已无缝覆盖！')));
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败: $e')));
    }
  }

  Future<void> _deleteCurrent() async {
    if (_currentId == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('安全警告', style: TextStyle(color: Colors.red)),
        content: const Text('确定抹除这份配置吗？此操作无法撤销'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留')),
          ElevatedButton(
              style:
                  ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirm == true) {
      await widget.engineRepository.deleteEngine(_currentId!);
      _clearInputs();
      await _loadData();
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('配置已被净空')));
    }
  }

  Future<void> _renameCurrent() async {
    if (_currentId == null) return;
    final currentEngine = _engines.firstWhere((e) => e.id == _currentId);
    final currentName = currentEngine.name;
    final ctrl = TextEditingController(text: currentName);
    ctrl.selection =
        TextSelection(baseOffset: 0, extentOffset: currentName.length);

    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改配置'),
        content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: '新名称')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != currentName) {
      final engineTypeEnum = AiEngineType.fromDbValue(widget.engineType);
      await widget.engineRepository
          .renameEngine(_currentId!, newName, engineTypeEnum);
      await _loadData();
    }
  }

  // 高级多端 API 探测
  Future<void> _fetchModels() async {
    if (_baseUrlCtrl.text.trim().isEmpty || _apiKeyCtrl.text.trim().isEmpty)
      return;
    try {
      String url = _baseUrlCtrl.text.trim();
      if (url.endsWith('/')) url = url.substring(0, url.length - 1);
      bool isGemini = url.contains('generativelanguage.googleapis.com');
      http.Response res;

      if (isGemini) {
        if (!url.endsWith('/models'))
          url = url.endsWith('/v1beta') || url.endsWith('/v1')
              ? '$url/models'
              : '$url/v1beta/models';
        res = await http.get(Uri.parse('$url?key=${_apiKeyCtrl.text.trim()}'),
            headers: {
              'Content-Type': 'application/json'
            }).timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          if (data['models'] != null && mounted) {
            final models = (data['models'] as List)
                .map((e) => e['name'].toString().replaceFirst('models/', ''))
                .toList();
            _showModelSelector(models);
            return;
          }
        }
      } else {
        // 多端点自动探测策略：逐一尝试各大供应商的 models 路径
        final String base =
            url.endsWith('/models') ? url.substring(0, url.length - 7) : url;
        final candidates = <String>[];
        if (url.endsWith('/models')) {
          candidates.add(url);
        } else if (url.endsWith('/v1')) {
          candidates.addAll(['$base/models', '$base/v4/models']);
        } else if (url.endsWith('/v4')) {
          candidates.addAll(['$base/models', '$base/v1/models']);
        } else {
          // 未知后缀：依次尝试 /models、/v4/models（GLM）、/v1/models（OpenAI）
          candidates.addAll([
            '$base/models',
            '$base/v4/models',
            '$base/v1/models',
          ]);
        }

        http.Response? successRes;
        for (final candidate in candidates) {
          try {
            final r = await http.get(Uri.parse(candidate), headers: {
              'Authorization': 'Bearer ${_apiKeyCtrl.text.trim()}',
              'Content-Type': 'application/json',
            }).timeout(const Duration(seconds: 10));
            if (r.statusCode == 200) {
              successRes = r;
              break;
            }
          } catch (_) {}
        }

        if (successRes != null) {
          res = successRes;
          final data = json.decode(res.body);
          List<String> models = [];
          if (data['data'] != null) {
            models =
                (data['data'] as List).map((e) => e['id'].toString()).toList();
          } else if (data['models'] != null) {
            models = (data['models'] as List)
                .map((e) => (e['id'] ?? e['name'] ?? e.toString()).toString())
                .toList();
          }
          if (models.isNotEmpty && mounted) {
            _showModelSelector(models);
            return;
          }
        } else {
          // 所有路径均失败，用最后一次候选作为 res 触发 snackbar
          res = await http.get(Uri.parse(candidates.last), headers: {
            'Authorization': 'Bearer ${_apiKeyCtrl.text.trim()}',
            'Content-Type': 'application/json',
          }).timeout(const Duration(seconds: 10));
        }
      }
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('状态码异常或找不到列表: ${res.statusCode}')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('获取失败: $e')));
    }
  }

  void _showModelSelector(List<String> models) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => ListView.builder(
        shrinkWrap: true,
        itemCount: models.length,
        itemBuilder: (context, index) => ListTile(
          title: Text(models[index],
              style: TextStyle(
                  color: Theme.of(context).primaryColor,
                  fontWeight: FontWeight.bold)),
          onTap: () {
            _modelCtrl.text = models[index];
            Navigator.pop(context);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _screenTitle();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
          title:
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                // 状态控制卡片
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.cardTheme.color,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: Colors.blueAccent.withValues(alpha: 0.3),
                        width: 1.5),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 10)
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.swap_calls_rounded,
                          color: Colors.blueAccent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            hint: const Text('尚未选择配置',
                                style: TextStyle(fontSize: 14)),
                            value: _engines.any((e) => e.id == _currentId)
                                ? _currentId
                                : null,
                            selectedItemBuilder: (ctx) => _engines
                                .map((p) => GestureDetector(
                                      onDoubleTap: _renameCurrent,
                                      child: Container(
                                          alignment: Alignment.centerLeft,
                                          child: Text(p.name,
                                              style: const TextStyle(
                                                  fontWeight:
                                                      FontWeight.bold))),
                                    ))
                                .toList(),
                            items: _engines
                                .map((p) => DropdownMenuItem(
                                    value: p.id, child: Text(p.name)))
                                .toList(),
                            onChanged: (val) async {
                              if (val != null) {
                                final engineTypeEnum =
                                    AiEngineType.fromDbValue(widget.engineType);
                                await widget.engineRepository
                                    .setActiveEngine(val, engineTypeEnum);
                                await _loadData();
                              }
                            },
                          ),
                        ),
                      ),
                      if (_currentId != null)
                        IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.redAccent, size: 20),
                            onPressed: _deleteCurrent),
                      TextButton(
                          onPressed: _clearInputs,
                          child: const Text('新建',
                              style: TextStyle(fontWeight: FontWeight.bold))),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                // 参数输入卡片
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                      color: theme.cardTheme.color,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: Colors.grey.withValues(alpha: 0.1))),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                          controller: _apiKeyCtrl,
                          obscureText: true,
                          decoration: InputDecoration(
                              labelText: 'API Key',
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8)))),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        value: _selectedProvider,
                        decoration: InputDecoration(
                          labelText: 'API 提供商 (快捷填充)',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                          prefixIcon: const Icon(Icons.cloud_queue),
                        ),
                        items: _providers.keys
                            .map((p) =>
                                DropdownMenuItem(value: p, child: Text(p)))
                            .toList(),
                        onChanged: (val) {
                          if (val != null && val != '自定义 (Custom)') {
                            setState(() {
                              _selectedProvider = val;
                              _baseUrlCtrl.text = _providers[val]!;
                              // 智能联动推荐模型名称
                              final suggestedModel =
                                  _defaultModelForProvider(val);
                              if (_modelCtrl.text.isEmpty &&
                                  suggestedModel.isNotEmpty) {
                                _modelCtrl.text = suggestedModel;
                              }
                            });
                          } else if (val == '自定义 (Custom)') {
                            setState(() => _selectedProvider = val!);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      TextField(
                          controller: _baseUrlCtrl,
                          decoration: InputDecoration(
                              labelText: 'Base URL',
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8)))),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _modelCtrl,
                        decoration: InputDecoration(
                          labelText: 'Model Name',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                          suffixIcon: IconButton(
                              icon: const Icon(Icons.sync,
                                  color: Colors.blueAccent),
                              onPressed: _fetchModels),
                        ),
                      ),
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Divider(height: 1)),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('模型随机性 (Temperature)',
                              style:
                                  TextStyle(fontSize: 13, color: Colors.grey)),
                          Text(_temperature.toStringAsFixed(2),
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blueAccent)),
                        ],
                      ),
                      Slider(
                        value: _temperature,
                        min: 0.0,
                        max: 2.0,
                        divisions: 20,
                        activeColor: Colors.blueAccent,
                        onChanged: (v) => setState(() => _temperature = v),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: _reasoningEffort,
                        decoration: InputDecoration(
                            labelText: '推理思维强度 (专供 o1/R1/高阶思考模型)',
                            labelStyle: const TextStyle(
                                fontSize: 13, color: Colors.grey),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8))),
                        items: const [
                          DropdownMenuItem(
                              value: '', child: Text('默认 (由模型自行判断)')),
                          DropdownMenuItem(
                              value: 'low', child: Text('Low (快速验证)')),
                          DropdownMenuItem(
                              value: 'medium', child: Text('Medium (平衡策略)')),
                          DropdownMenuItem(
                              value: 'high', child: Text('High (深度推演)')),
                          DropdownMenuItem(
                              value: 'max', child: Text('Max (满血极限算力) 🔥')),
                        ],
                        onChanged: (v) =>
                            setState(() => _reasoningEffort = v ?? ''),
                      ),
                      const SizedBox(height: 32),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: Colors.blueAccent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        icon: const Icon(Icons.save),
                        label: const Text('确认保存配置',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                        onPressed: _handleSave,
                      )
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
