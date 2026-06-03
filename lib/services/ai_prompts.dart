class AiPrompts {
  const AiPrompts._();

  static const String latexFormatRules = r'''
    [STRICT LATEX CONTRACT - MUST FOLLOW]
    1. Inline math MUST use \( ... \). Block math MUST use \[ ... \].
    2. Never use $...$ or $$...$$ as math delimiters.
    3. Never output bare LaTeX commands outside explicit math delimiters.
       Wrong: \frac{1}{2}, x_i, \alpha
       Right: \(\frac{1}{2}\), \(x_i\), \(\alpha\)
    4. Fill-in blanks MUST be plain ___ outside math delimiters.
       Wrong: \(a=___\)
       Right: \(a=\)___
    5. In JSON strings, every LaTeX backslash MUST be escaped.
       Write \\(x\\), \\frac{1}{2}, \\[...\\], and matrix row breaks as \\\\.

    【LaTeX 公式格式铁律（最高优先级）】
    1. 行内公式：所有行内公式、变量、数学符号必须用 \( 和 \) 包裹。
       ✅ \(\frac{1}{2}\)    ✅ \(x\)    ✅ \(\alpha + \beta\)
       ❌ \frac{1}{2}（裸命令，致命错误）
    2. 块级公式：独立成行的公式与矩阵必须用 \[ 和 \] 包裹。
       ✅ \[\sum_{i=1}^{n} x_i = 0\]
       ✅ \[\begin{pmatrix}1 & 2\\3 & 4\end{pmatrix}\]
    3. JSON 双重转义（最易出错，务必遵守）：
       输出 JSON 时，每一个 LaTeX 反斜杠 \ 必须写成 \\，否则 JSON 解析将直接崩溃。
       对应关系：
         \(  →  \\(          \)  →  \\)
         \[  →  \\[          \]  →  \\]
         \frac  →  \\frac    \\  →  \\\\（矩阵换行）
    4. 禁止事项：
       - 禁止使用 $...$ 或 $$...$$ 作为公式定界符
       - 禁止输出任何未被 \( \) 或 \[ \] 包裹的裸 LaTeX 命令
       - 题目中的填空下划线 ___ 禁止被定界符包裹，原样保留
       - 绝对不要在矩阵、公式内部对纯数字、普通的列分隔符 & 进行画蛇添足的转义！
    5. 【最重要】content、standard_answer、explanation 三个字段的 LaTeX 规则完全一致！
       explanation（解析推导）里的每一个公式同样必须用 \\( \\) 包裹，绝对不允许裸写！

    【JSON 各字段完整示例（explanation 和 standard_answer 里同样必须有 \\( \\) 包裹）】
    {
      "type": 3,
      "content": "已知微分方程 \\(y' + \\frac{1}{2\\sqrt{x}}y = \\frac{2+\\sqrt{x}}{2\\sqrt{x}}\\)，且 \\(y(1)=3\\)，求 \\(y(x)\\) 并求渐近线。",
      "standard_answer": "\\(y(x) = 2x + e^{1-\\sqrt{x}}\\)，斜渐近线为 \\(y = 2x\\)。",
      "explanation": "由通解公式 \\(y = e^{-\\int P(x)dx}\\left[\\int Q(x)e^{\\int P(x)dx}dx + C\\right]\\)，令 \\(u=\\sqrt{x}\\)，则 \\(x=u^2,\\, dx=2u\\,du\\)。计算得 \\(y(x)=2x+Ce^{-\\sqrt{x}}\\)。代入 \\(y(1)=3\\) 得 \\(C=e\\)，故 \\(y(x)=2x+e^{1-\\sqrt{x}}\\)。又 \\(\\lim_{x\\to+\\infty}\\frac{y(x)}{x}=2\\)，\\(\\lim_{x\\to+\\infty}[y(x)-2x]=0\\)，故斜渐近线为 \\(y=2x\\)。"
    }
''';

  static String get visionParsePrompt => '''
    你是一个教育数据清洗专家。这是试卷的原始扫描件/截图。请严格按照以下格式解析出其中的每一道题，绝对不允许遗漏！

    $latexFormatRules

    【题型与格式】
    1. 选择题 (type: 0): {"q_num": "题号", "type": 0, "content": "题干完整原文(必须把选项剥离出去，题干绝对不包含选项部分)", "options": ["A. xx", "B. xx", "C. xx", "D. xx"], "standard_answer": "正确选项"}
    2. 填空题 (type: 2): {"q_num": "题号", "type": 2, "content": "题干完整原文", "options": [], "standard_answer": "答案内容"}
    3. 解答题 (type: 3): {"q_num": "题号", "type": 3, "content": "题干完整原文", "options": [], "standard_answer": "最终结果", "explanation": "详细解题推导与证明过程（若无则设为 null 或留空）"}

    【综合大题提取法则（绝对红线）】
    遇到包含 (I)、(II) 或 (1)、(2) 等多个小问的综合性大题，绝对禁止将其拆分为多道独立的题！
    带有小括号的数字 (1)、小写字母 (a)、罗马数字 (I) 等绝对不允许独立！
    必须按以下标准合并为一道 type:3（解答题）：
    1. content（题干）：必须包含大题的前置背景描述，并依次追加 (I)(II) 等所有小问的题目原文。
    2. standard_answer（答案）：必须依次合并包含 (I)(II) 对应的所有解答内容。
    3. explanation（解析）：必须依次合并所有小问的推导证明过程。
    绝对不允许把小问的题干丢进答案里，各归其位！

    【输出模式】
    模式A（完整题目）：输出 content 和 standard_answer。
    模式B（只有题干，没有答案）：standard_answer 设为 null。
    模式C（纯答案区）：type 设为 null, content 设为 null, 仅输出 q_num 和 standard_answer。

    【扫描件题解混排处理法则】
    如果扫描件中包含【分析】、【解】、【证明】等解题过程标记：
    - content（题干）必须在第一个此类标记出现前截止，绝不包含解题过程！
    - standard_answer 提取解题过程最终得出的答案值或结论（如 \\(x=5\\) 或 "原命题得证"）。绝对不要把长篇大论的推导证明过程混入其中！
    - explanation (解析)：【特例指令】仅允许为解答题/证明题（type: 3）提取解题推导与证明过程放入此字段！如果是选择题（type: 0）或填空题（type: 2），即使原文有解析也必须丢弃，强制设为 null。

    【选择题选项剥离红线规则】
    对于选择题（type: 0），必须且只能将选项放置在 options 数组中（格式为 ["A. xxx", "B. xxx", ...]）。绝对禁止在 content (题干) 字段中包含选项标签和具体内容！

    必须且只能输出纯 JSON 对象，包含 "questions" 数组。不要用 markdown 包裹。
''';

  static String judgeAnswer({
    required String question,
    required String standardAnswer,
    required String userAnswer,
  }) {
    return '''
    你是一个严谨的考研助教。
    【题目】$question
    【标准答案/得分点】$standardAnswer
    【学生的回答】$userAnswer
    请对比标准答案，对学生回答打出 0-100 分，简明指出答对和遗漏的点。直接输出评价。
    ''';
  }

  static String generateQuestions({
    required String topic,
    required int count,
    required int type,
  }) {
    final typeReq = type == 0
        ? '全部为【单选题】，必须提供 4 个选项。'
        : (type == 2
            ? "全部为【填空题】，用 '___' 表示填空处。"
            : (type == 3 ? '全部为【简答题】。' : '混合生成【单选、填空、简答】。'));

    final exampleJson = type == 0
        ? '[{"type": 0, "content": "题干", "options": ["A.", "B."], "standard_answer": "A"}]'
        : (type == 2
            ? '[{"type": 2, "content": "题干(用___表示填空)", "options": [], "standard_answer": "答案"}]'
            : (type == 3
                ? '[{"type": 3, "content": "简答题干", "options": [], "standard_answer": "标准答案"}]'
                : '[{"type": 0, "content": "单选题干", "options": ["A.", "B."], "standard_answer": "A"}]'));

    return '''
    你是一个命题专家。请根据知识点：“$topic”，生成 $count 道题。
    题型要求：$typeReq
    【格式约束】直接输出纯 JSON 数组，绝不要 markdown 包裹。
    $exampleJson
    $latexFormatRules
    ''';
  }

  static String answerSingleQuestion(Map<String, dynamic> question) {
    final qType = question['type'] as int? ?? 3;
    final qContent = question['content']?.toString() ?? '';
    final qOptions = question['options']?.toString() ?? '';

    final buffer = StringBuffer('''
你是一个无所不知的超级学霸和全能做题家。请解答下面这道题。
【题目内容】
$qContent
''');

    if (qType == 0 || qType == 1) {
      buffer.write('''
【选项】
$qOptions
''');
    }

    buffer.write('''
【LaTeX 格式要求】所有公式必须用 \\( \\) 行内或 \\[ \\] 块级包裹。
JSON 中反斜杠须双写。禁止裸 LaTeX，禁止 \$...\$。

【要求】
1. 你必须且只能输出合法的 JSON 对象，格式必须完全遵守下方示例：
{"standard_answer": "你的最终答案（尽量简短，如A、B、或者一个词语、公式）"}
2. standard_answer 字段中绝对禁止出现多余的解释文字，只保留最终核心答案。
3. 输出的 JSON 必须严格合法：公式或内容中的换行必须写为 \\n，LaTeX 公式必须转义。
''');
    return buffer.toString();
  }

  static String generateExamPaper({
    required String topic,
    required int singleCount,
    required int fillCount,
    required int shortCount,
    String? customPrompt,
  }) {
    final buffer = StringBuffer('''
    你是一个命题专家。请根据知识点：“$topic”，生成 ${singleCount + fillCount + shortCount} 道题的测试卷。
    1. 【单选题】$singleCount 道。(type: 0)
    2. 【填空题】$fillCount 道。题干用 '___' 表示。(type: 2)
    3. 【简答题】$shortCount 道。(type: 3)
    【格式约束】直接输出纯 JSON 数组，绝不要 markdown 包裹。
    [
      {"type": 0, "content": "单选题干", "options": ["A.", "B."], "standard_answer": "A"},
      {"type": 2, "content": "填空题干(用___)", "options": [], "standard_answer": "填空答案"},
      {"type": 3, "content": "简答题干", "options": [], "standard_answer": "简答答案"}
    ]
    $latexFormatRules
    ''');
    if (customPrompt != null && customPrompt.isNotEmpty) {
      buffer.write('\n\n【特殊要求】\n$customPrompt');
    }
    return buffer.toString();
  }

  static String questionsFromMistakes({
    required String mistakeContext,
    required int count,
  }) {
    return '''
你是一个无所不知的教育专家。以下是学生最近做错的题目及其错误答案：
<mistakes>
$mistakeContext
</mistakes>

请深入分析这些错题暴露出的薄弱知识点，并针对这些薄弱点，为学生*生成 $count 道*全新的类似题目（混合单选、填空、解答），帮助他巩固。

【严格格式约束】直接输出纯 JSON 数组，绝不要 markdown 包裹。
[
  {"type": 0, "content": "单选题干", "options": ["A. xx", "B. xx", "C. xx", "D. xx"], "standard_answer": "A"},
  {"type": 2, "content": "填空题干(用___)", "options": [], "standard_answer": "填空答案"},
  {"type": 3, "content": "解答题干", "options": [], "standard_answer": "最终结果", "explanation": "解答过程或解析"}
]

【核心规则】
1. 除了 type:3 允许生成 explanation(解析) 之外，其他题型不要生成 explanation 字段。
2. 遇到包含小问的大题，必须合并为一道 type:3 题目。
$latexFormatRules
    ''';
  }

  static String parseChunk({
    required String rawText,
    required String parseMode,
  }) {
    final modeInstruction = _parseModeInstruction(parseMode);
    return '''
你是一个严谨的教育数据提取专家。请将以下文本提取为结构化的题库 JSON 数组。如果没有检测到题目，直接返回空数组 []。

【题型与格式】
1. 选择题 (type: 0): {"q_num": "题号", "type": 0, "content": "题干完整原文(必须把选项剥离出去，题干绝对不包含选项部分)", "options": ["A. xx", "B. xx", "C. xx", "D. xx"], "standard_answer": "正确选项"}
2. 填空题 (type: 2): {"q_num": "题号", "type": 2, "content": "题干完整原文", "options": [], "standard_answer": "答案内容"}
3. 解答题 (type: 3): {"q_num": "题号", "type": 3, "content": "题干完整原文", "options": [], "standard_answer": "最终结果", "explanation": "详细解题推导与证明过程（若无则设为 null 或留空）"}

【综合大题提取法则】
遇到包含 (1)(2) 或 (I)(II) 等多个小问的综合大题，绝对禁止将其拆分为多道独立的题！
必须合并为一道 type:3（解答题），题干包含背景和所有小问，答案合并所有对应解答。

$modeInstruction

【选择题选项剥离红线规则】
对于选择题（type: 0），必须且只能将选项放置在 options 数组中。绝对禁止在 content 字段中包含选项标签和具体内容！

$latexFormatRules
必须且只能输出纯 JSON 对象，包含 "questions" 数组。不要用 markdown 包裹。

【待解析文本】
<document>
$rawText
</document>
''';
  }

  static String visionParseWithConstraints() {
    return '''
$visionParsePrompt
    【解析约束】
除了上述特例允许 type:3 提取 explanation 之外，其他题型不要生成解析(explanation)字段。
请原样保留题干文字，不要使用“原题干”、“同上”、“略”等占位符。
''';
  }

  static String mergeStructuredQuestions(String combinedJson) {
    return '''
    你是一个逻辑严密的教育数据归并专家。

    $latexFormatRules

    我将向你提供一个包含多个数组的列表，这些数组是通过分别解析多个独立文档（如一份是【题目卷】，一份是【答案卷】）得到的结构化碎片。

    【核心任务】
    请你根据题目逻辑、题号（可能包含数字或中文序号）或者上下文，将属于同一道题的【题干碎片】和【答案碎片】完美合并为一个完整的题目对象。
    如果是孤立无法匹配的碎片，也请尽量保留。

    【反幻觉与防撕裂指令】
    1. 绝对禁止拆分题目：合并后，主大题的数量必须与原文题目数量一致。
    2. 禁止遗漏：所有提供的碎片必须完全被归并，不允许丢弃任何细节。

    【格式约束与死命令】
    1. 你必须且只能输出一个合法的 JSON 对象，格式如下：
```json
{"questions": [ {"type": 0, "content": "真实的题干内容", "options": ["A", "B"], "standard_answer": "完整的答案", "explanation": "完整的解析"} ]}
```
    绝对禁止输出缩写或骨架模板，必须输出真实的完整数据数组。
    2. 绝对不允许在 JSON 外部输出任何多余废话、问候语或解释。
    3. 合并后的题目必须包含：type, content, options(若是选择题), standard_answer。对于解答题(type: 3)，务必将跨页的解题步骤、推导过程完整拼接后放入 explanation 字段。
    4. 必须完整输出题目对象的所有内容，禁止使用省略号或缩写。

    【待合并的碎片数据】
    $combinedJson
    ''';
  }

  static String _parseModeInstruction(String parseMode) {
    if (parseMode == 'stem_only') {
      return '【当前为题干区模式】请只提取题干(content)和选项(options)，将 standard_answer 和 explanation 设为 null 或留空；绝对禁止在 content 中使用占位符敷衍。';
    }
    if (parseMode == 'answer_only') {
      return '【当前为纯答案区模式】请坚决让 content 为 null！仅输出 q_num(题号) 和 standard_answer(答案)。如果是解答题/证明题（type: 3），必须同时提取 explanation（解析/证明过程）。';
    }
    return '''
【输出模式】
模式A（完整题目）：输出 content 和 standard_answer。特例：若是解答题/证明题（type: 3），必须同时输出 explanation。
模式B（只有题干）：standard_answer 设为 null。
模式C（纯答案区）：type 设为 null, content 设为 null, 仅输出 q_num 和 standard_answer。特例：若是解答题/证明题（type: 3），必须同时输出 explanation。

除了上述特例允许解答题/证明题（type: 3）提取 explanation 之外，其他题型与模式绝对不要生成任何解析(explanation)字段。
对于模式A和模式B：绝对禁止在 content 中使用“原题干”、“同上”、“略”等任何占位符敷衍！必须一字不落地将完整题干抄录下来。
对于模式C：请坚决让 content 为 null，绝对不要把答案填进 content 凑数。
''';
  }
}
