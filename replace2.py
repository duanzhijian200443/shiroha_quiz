import json
with open('lib/services/ai_service.dart', 'r', encoding='utf-8') as f:
    lines = f.readlines()

start_idx = -1
end_idx = -1
for i, line in enumerate(lines):
    if line.startswith('  // 核心重构：智能切片与调度引擎'):
        start_idx = i
    if start_idx != -1 and line.startswith('    return allQuestions;'):
        end_idx = i + 2
        break

if start_idx != -1 and end_idx != -1:
    new_code = '''  Future<List<Map<String, dynamic>>> _findQuestionAnchors(String rawText, Map<String, dynamic> profile) async {
    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';

    final prompt = \\"\\"\\"
    你是一个文档结构分析专家。请通读以下试卷全文，找到每一道独立试题（包含其题干、选项、答案和所有解析内容）的起始和结束物理边界。
    
    【输出要求】
    你必须且只能输出合法的 JSON 数组，绝不允许输出多余的解释。格式如下：
    [
      {\\"q_num\\": 1, \\"start\\": \\"第一题开头的15个字符...\\", \\"end\\": \\"第一题解析结尾的15个字符...\\"},
      {\\"q_num\\": 2, \\"start\\": \\"第二题开头的15个字符...\\", \\"end\\": \\"第二题解析结尾的15个字符...\\"}
    ]

    【极端重要警告】
    1. 绝对不要尝试输出全文！你只需要返回坐标字符串（start 和 end）。
    2. start 和 end 必须是你从原文中一字不差复制出来的连续 15-20 个字符（包含空格、标点、甚至是图片标签的一部分）。
    3. 如果一道题包含多个小问（如(1)(2)），必须将它们视为一道完整的大题，只返回大题开头和最后一个小问解答结尾的坐标。
    4. "start" 是题干的第一句话，"end" 是这道题最终解答的最后一句话。

    【待解析文本】
    <document>
    \
    </document>
    \\"\\"\\";

    try {
      if (baseUrl.endsWith('/')) baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
      final isZhipu = baseUrl.contains('bigmodel.cn');
      String responseText = "";

      if (isGemini) {
        final url = "\/models/\=\";
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"temperature": 0.1, "maxOutputTokens": 4096, "responseMimeType": "application/json"}})).timeout(const Duration(minutes: 3));
        if (res.statusCode == 200) {
          responseText = jsonDecode(res.body)['candidates'][0]['content']['parts'][0]['text'] ?? "";
        } else {
          throw Exception("API Error: \");
        }
      } else {
        final url = _buildChatUrl(baseUrl, isZhipu);
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer \'}, body: jsonEncode({"model": model, "messages": [{"role": "user", "content": prompt}], "temperature": 0.1, "max_tokens": 4096, "response_format": {"type": "json_object"}})).timeout(const Duration(minutes: 3));
        if (res.statusCode == 200) {
          responseText = _extractContent(res.body);
        } else {
          throw Exception("API Error: \");
        }
      }
      
      final decoded = AiDataSanitizer.cleanAndParseJson(responseText);
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint("雷达定位阶段失败: \");
      return [];
    }
  }

  // 宏观重构：两阶段 LLM 流水线架构
  Future<List<Map<String, dynamic>>> parseTextToQuestions(String rawText) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) throw Exception("引擎配置不完整");

    // 第一阶段：雷达定位
    debugPrint("🚀 [第一阶段] 启动全文雷达扫描...");
    List<Map<String, dynamic>> anchors = await _findQuestionAnchors(rawText, profile);
    
    List<String> questionBlocks = [];
    if (anchors.isNotEmpty) {
      debugPrint("✅ 成功定位 \ 道题目坐标，开始本地切割...");
      int lastEndIndex = 0;
      for (var anchor in anchors) {
        String startStr = anchor['start']?.toString().trim() ?? '';
        String endStr = anchor['end']?.toString().trim() ?? '';
        
        if (startStr.isEmpty || endStr.isEmpty) continue;

        int startIndex = rawText.indexOf(startStr, lastEndIndex);
        if (startIndex == -1) startIndex = rawText.indexOf(startStr); // 容错：全量查找
        
        int endIndex = rawText.indexOf(endStr, startIndex);
        
        if (startIndex != -1 && endIndex != -1 && endIndex >= startIndex) {
           int endCut = endIndex + endStr.length;
           if (endCut > rawText.length) endCut = rawText.length;
           questionBlocks.add(rawText.substring(startIndex, endCut));
           lastEndIndex = endCut;
        } else {
           debugPrint("⚠️ 警告：无法在原文中精准定位坐标: start=\");
        }
      }
    }
    
    // 降级容错：如果定位完全失败或者提取数量极低，回退到按空行块切分的保守方案
    if (questionBlocks.length < 2) {
      debugPrint("⚠️ 第一阶段雷达定位失败或命中率过低，回退到智能分块算法...");
      questionBlocks.clear();
      StringBuffer currentChunk = StringBuffer();
      final paragraphs = rawText.split(RegExp(r'\\n\\s*\\n'));
      for (var p in paragraphs) {
        final text = p.trim();
        if (text.isEmpty) continue;
        if (currentChunk.length + text.length > 4000) { // 安全微批次大小
          if (currentChunk.isNotEmpty) {
            questionBlocks.add(currentChunk.toString());
            currentChunk.clear();
          }
        }
        currentChunk.writeln(text);
        currentChunk.writeln();
      }
      if (currentChunk.isNotEmpty) {
        questionBlocks.add(currentChunk.toString());
      }
    }

    // 第二阶段：微批次精洗组装 (限制每个批次约 4000 字)
    List<String> microBatches = [];
    StringBuffer currentBatch = StringBuffer();
    for (String block in questionBlocks) {
       if (currentBatch.length + block.length > 4000 && currentBatch.isNotEmpty) {
           microBatches.add(currentBatch.toString());
           currentBatch.clear();
       }
       currentBatch.writeln(block);
       currentBatch.writeln();
    }
    if (currentBatch.isNotEmpty) {
       microBatches.add(currentBatch.toString());
    }

    // 调度引擎
    List<Map<String, dynamic>> allQuestions = [];
    int failCount = 0;
    debugPrint("🚀 [第二阶段] 将启动 \ 次微批次精洗格式化...");
    
    for (int i = 0; i < microBatches.length; i++) {
      debugPrint("🚀 正在解析第 \/\ 块...");
      
      bool success = false;
      int retry = 0;
      
      while (retry < 3 && !success) {
        try {
          final chunkQuestions = await _parseSingleChunkToQuestions(microBatches[i], profile);
          allQuestions.addAll(chunkQuestions);
          success = true;
          // 防御性休眠：每批次请求之间强制休眠 3 秒，防止免费 API 触发 429 熔断
          if (i < microBatches.length - 1) {
              await Future.delayed(const Duration(seconds: 3));
          }
        } catch (e) {
          retry++;
          debugPrint("第 \ 块解析失败 (重试 \/3): \");
          if (retry >= 3) {
             failCount++;
          } else {
             int delaySeconds = e.toString().contains('429') ? (5 * retry) : 2;
             debugPrint("触发频率限制/错误，冷却 \ 秒后重试...");
             await Future.delayed(Duration(seconds: delaySeconds));
          }
        }
      }
      
      if (failCount >= microBatches.length && microBatches.length > 1 && i == microBatches.length - 1) {
         throw Exception("所有请求全军覆没！请检查是否触发了大模型的并发限制（429 Too Many Requests），或网络完全断开。");
      }
    }
    
    if (allQuestions.isEmpty) {
       throw Exception("解析完成，但未提取到任何有效题目。可能是文档全为废话或已被 AI 拦截。");
    }
    
    debugPrint("【两阶段引擎】流水线完成，共提取 \ 题！");
    return allQuestions;
  }
'''
    new_lines = lines[:start_idx] + [new_code] + lines[end_idx:]
    with open('lib/services/ai_service.dart', 'w', encoding='utf-8') as f:
        f.writelines(new_lines)
    print("Replace success! Lines replaced:", end_idx - start_idx)
else:
    print("Could not find start or end index.")
