import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiroha_quiz/data/models/question.dart';

class LLMService {
  static final LLMService _instance = LLMService._internal();
  factory LLMService() => _instance;
  LLMService._internal();

  Future<String> _fetchCompletion(String systemPrompt, String userPrompt) async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('text_llm_api_key');
    final baseUrl = prefs.getString('text_llm_base_url') ?? 'https://api.deepseek.com/v1';
    final modelName = prefs.getString('text_llm_model_name') ?? 'deepseek-chat';

    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('请先前往“我的”页面配置文本逻辑引擎');
    }

    final url = Uri.parse('$baseUrl/chat/completions');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };
    final body = jsonEncode({
      'model': modelName,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      'response_format': {'type': 'json_object'},
      'temperature': 0.5,
    });

    try {
      final response = await http.post(url, headers: headers, body: body);
      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data['choices'] != null && data['choices'].isNotEmpty) {
          return data['choices'][0]['message']['content'];
        }
      } else {
        final errMsg = 'Text LLM API Error: ${response.statusCode} - ${response.body}';
        print(errMsg);
        throw Exception('AI 接口返回错误 (${response.statusCode}): ${response.body}');
      }
    } catch (e) {
      print('Error calling Text LLM API: $e');
      throw Exception('调用 AI 服务失败: $e');
    }
    throw Exception('AI 服务未返回有效响应');
  }

  Future<Question?> generateVariantQuestion(Question originalQuestion) async {
    const systemPrompt =
        '你是一个 408 统考出题专家。请分析用户提供的原题，保持相同的考点和难度，修改题干的数值或应用场景，生成一道全新的单选题，并以 JSON 格式输出。\n'
        '【严格约束】：\n'
        '1. 必须且只能生成 A, B, C, D 四个选项！绝对不允许只有 2 个选项！\n'
        '2. 绝对不允许在 JSON 中生成 explanation、subject 等任何多余字段！只能包含 type, content, options, standard_answer, tags！\n'
        '3. 必须且只能输出一个合法的 JSON 对象，不要任何 Markdown 标记。格式必须严格如下：\n'
        '{"type": 0, "content": "新题干", "options": ["A. ...", "B. ..."], "standard_answer": "正确选项", "tags": ["变种题"]}\n'
        '【重要】：如果题目中包含 LaTeX 数学公式，请务必将公式中的反斜杠双写转义（例如使用 \\\\frac 代替 \\frac），以确保 JSON 解析器不会报错。';

    List<dynamic> originalOptions = [];
    if (originalQuestion.options != null && originalQuestion.options!.isNotEmpty) {
      try {
        originalOptions = jsonDecode(originalQuestion.options!);
      } catch (e) {
        originalOptions = [originalQuestion.options];
      }
    }
    final userPromptPayload = {
      'content': originalQuestion.content,
      'options': originalOptions,
      'answer': originalQuestion.answer,
    };
    final userPrompt = jsonEncode(userPromptPayload);

    final String completion = await _fetchCompletion(systemPrompt, userPrompt);

    try {
      final String sanitized = _sanitizeLatexJson(completion);
      final Map<String, dynamic> variantJson = jsonDecode(sanitized);
      final int now = DateTime.now().millisecondsSinceEpoch;
      final String previewId = 'preview_${now}_${(1000 + (DateTime.now().microsecond % 9000))}';

            return Question(
        id: previewId,
        type: 0, // Variant questions are always single-choice for now.
        content: variantJson['content'],
        options: jsonEncode(variantJson['options']),
        answer: variantJson['standard_answer'], // 'answer' in model, 'standard_answer' in JSON
        createdAt: now,
        bankName: originalQuestion.bankName,
        // This explanation is a temporary UI message, not from the LLM.
        // It's safe because the 'explanation' field exists on the Question model.
        explanation: '这是由 AI 生成的变种题，基于原题。\n请注意：本题尚未最终存入题库，您可选择【丢弃】或【收入题库】。',
      );
    } catch (e) {
      print("Error parsing LLM response: $e");
      throw Exception('AI 生成变种题解析失败: $e');
    }
  }

  Future<String> evaluateSubjectiveAnswer(String questionContent, String standardAnswer, String userAnswer) async {
    const systemPrompt =
        '你是一个严格的 408 计算机考研阅卷专家。请对比标准答案与用户的回答。\n'
        '你必须提取标准答案中的 3-5 个核心采分点，并逐一指出用户的回答中是否包含了这些点。\n'
        '你必须且只能输出一个合法的 JSON 对象，不要包含任何多余的解释或 Markdown 标记。格式必须严格如下：\n'
        '''
        {
          "score": 80,
          "rubrics": [
            {"point": "采分点名称", "matched": true, "reason": "匹配原因..."},
            {"point": "采分点名称", "matched": false, "reason": "未匹配原因..."}
          ],
          "analysis": "整体回答分析..."
        }
        ''';

    final userPrompt = '''
# Question
$questionContent

# Standard Answer
$standardAnswer

# User Answer
$userAnswer
''';

    final String completion = await _fetchCompletion(systemPrompt, userPrompt);
    return _sanitizeLatexJson(completion);
  }


  Future<String> parseTextToJSON(String rawText) async {
    const systemPrompt =
        '你是一个 408 统考数据清洗引擎。请从用户输入的杂乱文本中，提取出所有的题目，并将其转化为合法的 JSON 格式。\n'
        '【题型分类核心规则】：\n'
        '1. 如果题目本身含有显式的 A, B, C, D 选项，则 type 必须为 0（单选题），且 options 数组必须包含这四个选项。\n'
        '2. 如果题目是计算题、证明题、简答题、填空题等主观大题，则 type 必须为 3（简答题），且 options 数组必须为空 []，标准答案和推导步骤全部放入 standard_answer 字段中！\n'
        '【严格约束】：\n'
        '1. 绝对不允许在 JSON 中生成 explanation、subject 等任何多余字段！只能包含 type, content, options, standard_answer, tags！\n'
        '2. 必须且只能输出一个合法的 JSON 数组，不要包含任何多余的解释、问候语或 Markdown 标记。格式必须严格如下：\n'
        '''
        {
          "questions": [
            {
              "type": 0,
              "content": "单选题干...",
              "options": ["A. ...", "B. ...", "C. ...", "D. ..."],
              "standard_answer": "A",
              "tags": ["知识点"]
            },
            {
              "type": 3,
              "content": "计算/证明/简答题干...",
              "options": [],
              "standard_answer": "这里填详细的步骤、矩阵、公式和最终答案...",
              "tags": ["知识点"]
            }
          ]
        }
        '''
        '\n【重要】：如果题目中包含 LaTeX 数学公式，请务必将公式中的反斜杠双写转义（例如使用 \\\\frac 代替 \\frac），以确保 JSON 解析器不会报错。';

    final String completion = await _fetchCompletion(systemPrompt, rawText);
    return _sanitizeLatexJson(completion);
  }

  Future<String> parsePdfToJSON(String base64Pdf) async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('vision_llm_api_key');
    final baseUrl = prefs.getString('vision_llm_base_url') ?? 'https://generativelanguage.googleapis.com/v1beta';
    final modelName = prefs.getString('vision_llm_model_name') ?? 'gemini-1.5-flash';

    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('请先前往“我的”页面配置多模态视觉引擎');
    }

    final url = Uri.parse('$baseUrl/models/$modelName:generateContent?key=$apiKey');
    final headers = {'Content-Type': 'application/json'};
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
                         {'text': '你是一个 408 统考出题专家。请阅读这份 PDF 文件，提取出里面的所有题目，并以 JSON 格式输出。\n'
                                  '【题型分类核心规则】：\n'
                                  '1. 如果题目本身含有显式的 A, B, C, D 选项，则 type 必须为 0（单选题），且 options 数组必须包含这四个选项。\n'
                                  '2. 如果题目是计算题、证明题、简答题、填空题等主观大题，则 type 必须为 3（简答题），且 options 数组必须为空 []，标准答案和推导步骤全部放入 standard_answer 字段中！\n'
                                  '【严格约束】：\n'
                                  '1. 绝对不允许在 JSON 中生成 explanation、subject 等任何多余字段！只能包含 type, content, options, standard_answer, tags！\n'
                                  '2. 必须且只能输出一个合法的 JSON 数组，不要包含任何多余的解释、问候语或 Markdown 标记。格式必须严格如下：\n'
                                  '''
                                  {
                                    "questions": [
                                      {
                                        "type": 0,
                                        "content": "单选题干...",
                                        "options": ["A. ...", "B. ...", "C. ...", "D. ..."],
                                        "standard_answer": "A",
                                        "tags": ["知识点"]
                                      },
                                      {
                                        "type": 3,
                                        "content": "计算/证明/简答题干...",
                                        "options": [],
                                        "standard_answer": "这里填详细的步骤、矩阵、公式和最终答案...",
                                        "tags": ["知识点"]
                                      }
                                    ]
                                  }
                                  '''
                                  '\n【重要】：如果题目中包含 LaTeX 数学公式，请务必将公式中的反斜杠双写转义（例如使用 \\\\frac 代替 \\frac），以确保 JSON 解析器不会报错。'},
            {
              'inline_data': {
                'mime_type': 'application/pdf',
                'data': base64Pdf
              }
            }
          ]
        }
      ]
    });

    try {
      final response = await http.post(url, headers: headers, body: body);
      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        // Gemini API response structure is different
        final content = data['candidates'][0]['content']['parts'][0]['text'];
        return _sanitizeLatexJson(content);
      } else {
        print('Vision LLM API Error: ${response.statusCode} - ${response.body}');
        throw Exception('AI 服务未能正确解析 PDF: ${response.body}');
      }
    } catch (e) {
      print('Error calling Vision LLM API: $e');
      throw Exception('调用 AI 服务时发生网络错误');
    }
  }

  String _sanitizeLatexJson(String rawJson) {
    // 1. 清理 Markdown 代码块包裹
    String clean = rawJson.replaceAll(RegExp(r'```(?:json)?|```'), '').trim();
    
    // 2. 【核心修复】：使用断言正则，只匹配“单反斜杠”
    // - (?<!\\) 确保前面没有反斜杠，防止匹配双反斜杠的第二位
    // - \\ 匹配反斜杠本身
    // - (?![\\\"nrtbf/]) 确保后面不是 JSON 的合法转义字符（如 \n, \t, \", \\）
    // 这样可以完美避开大模型已经转义好的双反斜杠，仅对未转义的单反斜杠进行修复！
    return clean.replaceAllMapped(RegExp(r'(?<!\\)\\(?![\\\"nrtbf/])'), (match) {
      return '\\\\';
    });
  }
}
