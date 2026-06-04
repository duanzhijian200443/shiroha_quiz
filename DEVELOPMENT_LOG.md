# 🚀 自动化 Git 提交与开发日志引擎 (Git & Changelog Engine)

## [2026-06-04 12:56] - refactor(arch): 引入强类型 QuestionDraft 统一 UI 与持久化层数据模型
- **变更类型**: refactor
- **影响模块**: models, repositories, ui, test
- **详细改动明细**:
  - [x] 新建了 `lib/data/models/question_draft.dart`，定义了强类型的 `QuestionDraft` 和 `QuestionType` 枚举，取代了原本传递 `Map<String, dynamic>` 的弱类型方式。
  - [x] 改造了 `lib/ui/pages/ai_generator_screen.dart` 与 `lib/ui/pages/import_staging_screen.dart`，将其内部的 `_questions` 和 `_displayQuestions` 状态更改为 `List<QuestionDraft>`，所有题目属性通过点运算符（如 `q.content`、`q.options`）进行强类型访问。
  - [x] 优化了 `lib/data/repositories/question_repository.dart`，重载并暴露 `saveQuestionDraftsToBank` 接口，使保存链路直接接收 `List<QuestionDraft>`，不再在存盘时临时执行 Map 到 Model 的脆弱转型。
  - [x] 新增了 `test/question_draft_test.dart` 测试套件，完整覆盖了 AI JSON Map 到强类型 `QuestionDraft` 的容错清洗和防御转换测试。
- **验证状态**: 经本地单元测试和 widget 测试验证通过 (All 16 tests passed!)。

## [2026-06-04 07:45] - refactor(arch): 将胖服务解耦并重构数据存储为 Repository 模式
- **变更类型**: refactor
- **影响模块**: services, data, ui, utils
- **详细改动明细**:
  - [x] 新建了 `lib/data/repositories/question_repository.dart`，负责统一管理题库持久化、树状结构读取、考试试卷创建和题目删除，彻底消除 UI 对底层 SQL 的直接依赖。
  - [x] 新建了 `lib/services/ai_prompts.dart`，将原先混杂在 AI 服务中的 LaTeX 定界符规则和视觉解析长篇 Prompt 提示词抽离至专用类管理。
  - [x] 新建了 `lib/services/llm_api_client.dart`，集中封装底层 HTTP 请求的参数组合、认证和流式回复接口。
  - [x] 新建了 `lib/utils/image_utils.dart`，将 CPU 消耗高的 Isolates 图片异步压缩逻辑独立为纯净工具函数。
  - [x] 重构了 `lib/services/ai_service.dart`，移除千行以上的 Prompt 定义和底层请求细节，精简为纯粹的高层接口业务编排者。
  - [x] 改造了 `lib/ui/pages/import_staging_screen.dart` 与 `lib/ui/pages/ai_generator_screen.dart`，用 `QuestionRepository` 取代了直接的 SQL `db.transaction` 存盘和读取，实现了视图与持久化数据的高度解耦。
- **验证状态**: 经本地单元测试和 widget 测试验证通过 (All 14 tests passed!)。

## [2026-06-04 00:36] - fix(latex): 修复 LaTeX 嵌套定界符解析与公式双重包裹问题
- **变更类型**: fix
- **影响模块**: utils, test
- **详细改动明细**:
  - [x] 修改了 `lib/utils/content_tokenizer.dart` 中的 `_findClosingDelimiter` 方法，引入深度感知（depth-aware）扫描机制，完美处理了 LaTeX 内嵌套定界符（如在 `\right)` 内嵌套 parentheses）导致的早期截断 Bug。
  - [x] 修改了 `lib/utils/content_normalizer.dart`，同步更新其 `_findClosingDelimiter` 方法至深度感知版本，统一了解析行为。
  - [x] 修改了 `lib/utils/content_normalizer.dart`，在 `_normalize` 管道中新增 `_stripDoubleDelimiters` 步骤，能够自动对数据中已有的双重公式包裹定界符（如 `\(\(...\)\)`、`\[\[...\]\]`）进行解包折叠。
  - [x] 优化了 `lib/utils/content_normalizer.dart` 中的 `_convertDollarDelimiters` 方法，引入 `_isFullyWrapped` 检测机制，避免在进行美式刀币符（`$` / `$$`）转换时，对本就已包裹了 `\(` 或 `\[` 定界符的 LaTeX 公式重复追加外层包装，从源头上杜绝了双重包裹的产生。
  - [x] 扩展了 `test/render_matrix_test.dart` 测试套件，补充了针对双重定界符折叠、刀币符防双重包裹处理等多项深度用例，且整体单元/Widget测试全部无错通过。
- **验证状态**: 经本地单元测试和 widget 测试验证通过 (All 14 tests passed!)。

## [2026-06-04 00:13] - refactor(render): 基于Tokenizer重构分词与数学公式渲染管线
- **变更类型**: refactor
- **影响模块**: render, ui, utils
- **详细改动明细**:
  - [x] 新建了 `lib/utils/content_tokenizer.dart`，实现基于状态机顺序扫描的文本、数学公式、图片及空白占位分词器，取代混乱的正则表达式扫描。
  - [x] 新建了 `lib/utils/content_normalizer.dart`，用于标准化公式定界符（如把 `$$` 和 `$` 统一为 `\[` 和 `\(`），自动剥离 LaTeX 内部的连续下划线 `___` 并过滤 `<think>` 标签。
  - [x] 新建了 `lib/ui/widgets/structured_content_renderer.dart`，基于 Token 序列利用 `RichText` 与 `WidgetSpan` 结构化组合行内元素，并增加了针对行内公式的自适应缩放、块级公式的横向滚动、特殊指令替换与 Unicode 字符自动纠错等防御性机制。
  - [x] 修改了 `lib/ui/widgets/markdown_extensions.dart`，将 `buildLatexWidget` 统一指向新的 `StructuredContentRenderer`，实现全局无缝升级。
  - [x] 修改了 `lib/utils/ai_data_sanitizer.dart`，配合新归一化引擎简化数据入库与清洗管道。
  - [x] 重构了 `test/render_matrix_test.dart` 测试套件，补充覆盖了 Tokenizer、Normalizer 及 Widget 渲染的各项边界条件，验证全部通过。
- **验证状态**: 经本地单元测试和 widget 测试验证通过 (All 12 tests passed!)。

## [2026-06-01 07:34] - fix(ai): 移除裸命令包裹逻辑，统一将 \(\) 和 \[\] 转换为 \$，强化 AI 占位符包裹红线
- **变更类型**: fix
- **影响模块**: ai_engine, ai_sanitizer
- **详细改动明细**:
  - [x] 修改了 `lib/utils/ai_data_sanitizer.dart`，移除 `formatLatex` 中不稳定的裸 LaTeX 命令扫描包裹机制，避免误伤集合描述等复杂文本。
  - [x] 新增 `normalizeDelimiters` 转换清洗层，自动且安全地将大模型倾向输出的 `\(` `\)` 和 `\[` `\]` 替换为标准 `$` 和 `$$` 包裹，同时将其在入库前和渲染前置拦截路径中执行，完美兼容历史错误数据与新任务数据。
  - [x] 修改了 `lib/services/ai_service.dart`，在三个核心大模型 Prompt 中增加严格的“绝对禁止使用 `\(` `\)` 或 `\[` `\]` 公式占位符”红线约束。
- **验证状态**: 经本地静态检查及沙盒匹配验证全部通过。

## [2026-05-31 23:55] - fix(ai): 优化选择题选项剥离与解答题解析提取，强化 LaTeX 公式包裹防呆规范
- **变更类型**: fix
- **影响模块**: ai_engine, ai_sanitizer
- **详细改动明细**:
  - [x] 修改了 `lib/services/ai_service.dart`，对齐并升级全部解析提示词（Prompt），添加选择题选项强制剥离规则，以及更健全的 LaTeX 行内与环境公式防呆包裹约束。
  - [x] 在解答题的 JSON Schema 中显式补全了 `explanation` 字段，并修正了文本分块解析提示词中禁止/提取解析的逻辑冲突，从而完美支持简答题/证明题提取解析。
  - [x] 修改了 `lib/utils/ai_data_sanitizer.dart`，新增了针对题干残留 A/B/C/D 选项的正则剥离与题型纠错兜底提取机制。
- **验证状态**: 经单元测试与本地静态检查全部通过。

## [2026-05-31 23:07] - fix(ai_sanitizer): 引入占位符隔离法并修复 JSON 反斜杠转义
- **变更类型**: fix
- **影响模块**: ai_sanitizer, ui
- **详细改动明细**:
  - [x] 修改了 `lib/utils/ai_data_sanitizer.dart`，重构 `formatLatex` 方法，引入基于占位符的 `___LATEX_BLOCK_x___` 隔离机制，试图解决多重定界符冲突问题。
  - [x] 在 `cleanAndParseJson` 中修复了由于物理换行替换引发的大模型未转义 LaTeX 反斜杠（如 `\mu`, `\frac`）造成的 JSON 解析崩溃。
  - [x] 优化 `cleanLatexBeforeDB` 以处理矩阵前的系数并加强 Markdown 块级识别。
  - [x] 修改了 `lib/ui/widgets/markdown_extensions.dart`，在内联公式 `Math.tex` 的报错 Fallback 中去除了显式的橙色字体，并增加了字数超 200 降级纯文本的安全防御。
- **验证状态**: 经本地检查记录本次变动。
