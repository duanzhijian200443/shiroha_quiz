# 🚀 自动化 Git 提交与开发日志引擎 (Git & Changelog Engine)

## [2026-06-04 21:55] - refactor(questions): 将题库与题目管理的 UI 层直连迁移至 QuestionRepository
- **变更类型**: refactor
- **影响模块**: data, ui
- **详细改动明细**:
  - [x] 扩展 `QuestionRepository`，代理包括 `getSubjectTree`、`updateQuestion`、`insertPomodoroSession`、`getHeatmapData` 在内的近 15 个底层方法。
  - [x] 封装 `savePreviewQuestion` 事务，彻底消灭了 `practice_page` 里的 `db.insert` 等硬编码。
  - [x] 在 `deleteQuestionBank` 中实现联动，一旦删除的题库是当前被选中的题库，自动刷新 `SettingsRepository` 缓存为默认态。
  - [x] 净化了 `data_center_screen`, `import_screen`, `question_list_screen`, `question_edit_screen`, `practice_page` 的 `DatabaseHelper` 依赖。
  - [x] 顺带清除了 `home_page`, `plan_config_screen`, `profile_screen` 的零星遗留调用。
- **验证状态**: 经本地代码格式化、静态分析与全量 `flutter test` 验证，28 个测试完美回归。UI 层对于题库模块的数据隔离目标全面达成。
## [2026-06-04 21:35] - refactor(settings): 引入 SettingsRepository 与内存级缓存，隔离 UI 层配置读写
- **变更类型**: refactor
- **影响模块**: data, ui
- **详细改动明细**:
  - [x] 新增 `lib/data/repositories/settings_repository.dart`，作为配置项管理的强类型入口。
  - [x] 在 `SettingsRepository` 内部实现了针对高频读取设置的**高级内存缓存数据结构** (`Map<String, String> _cache`)，有效减少 SQLite 的异步 I/O 查询。
  - [x] 将弱类型的 `DatabaseHelper.instance.getSetting / saveSetting` 替换为强类型的专属方法，如 `getAppTheme()`、`getCurrentBank()`、`getDailyQuota(bankName)`。
  - [x] 重构了 `lib/main.dart` 中的应用启动主题初始化。
  - [x] 重构了 `lib/ui/pages/ai_settings_screen.dart` 与 `lib/ui/pages/profile_screen.dart` 的主题偏好设置。
  - [x] 重构了 `lib/ui/pages/plan_config_screen.dart` 的每日任务配额读写与题库切换落盘逻辑，并解耦了恶心的字符串拼接（如 `${bankName}_daily_quota`）。
  - [x] 重构了 `lib/ui/pages/home_page.dart` 和 `lib/ui/pages/mock_center_screen.dart` 页面顶部的当前题库缓存读取逻辑。
- **验证状态**: 经本地代码格式化、静态分析与全量 `flutter test` 回归验证，全部测试通过。遵循架构纪律，本次重构范围严控在 UI 层。
## [2026-06-04 21:18] - refactor(ai_ui): UI 层 AI 引擎配置入口迁移至 Repository
- **变更类型**: refactor
- **影响模块**: ui, data, ai
- **详细改动明细**:
  - [x] 扩展 `lib/data/repositories/ai_engine_repository.dart`，增加 `saveEngine`、`setActiveEngine`、`deleteEngine` 与 `renameEngine` 方法，完善完整 CRUD 链路。
  - [x] 重构 `lib/ui/pages/ai_engine_management_screen.dart`，移除 `DatabaseHelper` 直接调用，全面拥抱 `AiEngineRepository` 和强类型 `AiEngineProfile`，保持 UI 交互/渲染层纯净。
  - [x] 修改 `lib/ui/pages/ai_settings_screen.dart`，通过 `AiEngineRepository` 读取活跃文本与视觉引擎配置，阻断直接读取 DB。
  - [x] 修改 `lib/ui/pages/profile_screen.dart`，使用 `AiEngineRepository` 替代底层 `DatabaseHelper` 方法呈现当前活跃配置名称。
- **验证状态**: 经本地单元测试和 widget 测试验证通过 (All tests passed)，成功隔离 AI Engine 管理操作，避免 UI 层与底层 DB 耦合。
## [2026-06-04 20:28] - refactor(ai): 迁移遗留 LLMService 至统一 Provider 边界
- **变更类型**: refactor
- **影响模块**: ai, services, provider, test
- **详细改动明细**:
  - [x] 修改 `lib/services/llm_service.dart`，移除 `SharedPreferences` 旧文本/视觉引擎配置读取与手写 `http.post` 调用，统一改为 `AiEngineRepository` + `LlmApiClient`。
  - [x] 修改 `_fetchCompletion`，保留旧 `systemPrompt` / `userPrompt` 调用契约，但通过 active text engine 发起统一 provider 文本请求。
  - [x] 修改 `parsePdfToJSON`，通过 active vision engine 调用 `LlmApiClient.callVision`，并显式限制 Base64 PDF 路径当前仅支持 Gemini 视觉引擎，避免 OpenAI-compatible 分支误收不可靠 PDF data URL。
  - [x] 修改 `LlmTextRequest`，新增 `systemPrompt`、`chatMessages` 与 `combinedPrompt` 派生结构；OpenAI-compatible provider 使用 system/user messages，Gemini provider 使用合并 prompt。
  - [x] 修改 `test/ai_engine_profile_test.dart`，新增 system prompt 请求结构测试，防止 Provider 请求退化为单 user prompt。
- **验证状态**: 已完成 `dart format`、`dart analyze` 受影响文件集合、`dart analyze lib/services lib/data`、`flutter test test/ai_engine_profile_test.dart`、旧配置残留 `rg` 搜索与 `git diff --check`；完整 `flutter test` 仍按约定交由 Gemini/反重力执行。

## [2026-06-04 19:35] - refactor(ai): 引入强类型 AI 引擎配置模型
- **变更类型**: refactor
- **影响模块**: ai, services, data, test
- **详细改动明细**:
  - [x] 新增 `lib/data/models/ai_engine_profile.dart`，定义 `AiEngineType` 与 `AiEngineProfile`，集中处理 DB 行字段归一化、温度默认值、激活状态转换、baseUrl 尾斜杠清洗与缺字段诊断。
  - [x] 新增 `lib/data/repositories/ai_engine_repository.dart`，把业务层读取 active text/vision engine 的入口收束到 Repository，避免服务层直接消费 `Map<String, dynamic>`。
  - [x] 修改 `lib/services/llm_api_client.dart` 与 `lib/services/llm_providers/llm_provider_client.dart`，将 `callText` / `callVision` 的 profile 入参改为 `AiEngineProfile`，移除旧的 `LlmProviderProfile.fromMap` 适配器。
  - [x] 修改 `lib/services/ai_service.dart`，文本生成、答题、组卷、错题生成、文本解析、视觉解析和多文件合并统一通过 `AiEngineRepository` 获取强类型引擎配置。
  - [x] 修改 `lib/services/latex_migration_service.dart`，历史 LaTeX 迁移逻辑复用 `LlmApiClient.callText`，删除服务内手写 Gemini/OpenAI/Zhipu HTTP 分支。
  - [x] 新增 `test/ai_engine_profile_test.dart`，覆盖 DB 脏数据归一化、缺字段诊断与 `LlmTextRequest` 从强类型 profile 构造请求。
  - [x] 清理 `lib/data/models/question.dart` 的未用 import，并将 `lib/services/llm_service.dart` 中的 `print` 替换为 `debugPrint`，使 `lib/services lib/data` 宽范围静态检查保持干净。
- **验证状态**: 已完成 `dart format`、`dart analyze lib/services lib/data`、`dart analyze` 受影响文件集合、`flutter test test/ai_engine_profile_test.dart`；完整 `flutter test` 仍按约定交由 Gemini/反重力执行。

## [2026-06-04 19:02] - refactor(ai): 抽离文档解析路由 Router
- **变更类型**: refactor
- **影响模块**: ai, services, test
- **详细改动明细**:
  - [x] 新建 `lib/services/document_parse_router.dart`，集中承载文档结构探针后的 A/B/C/D 路径判定。
  - [x] 新增 `DocumentParseRoute`、`DocumentParseSegment` 与 `DocumentParsePlan`，将每条文档路径转换为带 `parseMode` 的批次解析计划。
  - [x] 将 `AiService.parseTextToQuestions` 中的尾部答案裁剪、首尾分离、全文无答案和标准行内解析分支迁移到 `DocumentParseRouter.buildPlan`。
  - [x] 修改 `AiService.parseTextToQuestions`，按 plan 统一追加 pending chunks 并逐段调用 `parseMicroBatches`，使服务层只保留执行编排。
  - [x] 新增 `test/document_parse_router_test.dart`，覆盖路径 A 尾部答案裁剪和路径 B 题干/答案分离两条高风险路由。
- **验证状态**: 已完成 `dart format`、`dart analyze lib/services/ai_service.dart lib/services/document_parse_router.dart test/document_parse_router_test.dart`、`flutter test test/document_parse_router_test.dart`、`flutter test test/document_chunker_test.dart`、`flutter test test/document_parse_router_test.dart test/document_chunker_test.dart test/parse_batch_runner_test.dart test/question_parse_pipeline_test.dart`、关键路径 `rg` 搜索与 `git diff --check`；并行运行 Flutter 测试时曾触发 Windows native assets 工具层拷贝冲突，已改为顺序重跑且全部通过。

## [2026-06-04 14:36] - refactor(ai): 抽离文档分块器 DocumentChunker
- **变更类型**: refactor
- **影响模块**: ai, services, test
- **详细改动明细**:
  - [x] 新建 `lib/services/document_chunker.dart`，集中承载普通文本与 Markdown 的微批次分块算法。
  - [x] 保留原普通文本 1500 字符阈值、Markdown 2000 字符阈值，以及 Markdown 标题/序号分割规则，避免改变解析外部行为。
  - [x] 修改 `lib/services/ai_service.dart`，移除 `splitTextIntoMicroBatches` 与 `splitMarkdownIntoMicroBatches` 内联实现，统一通过 `_chunker.split(...)` 获取分块。
  - [x] 新增 `test/document_chunker_test.dart`，覆盖普通文本段落分块和 Markdown 标题/序号分块两条路径。
- **验证状态**: 已完成 `dart format`、`dart analyze lib/services/ai_service.dart lib/services/document_chunker.dart test/document_chunker_test.dart`、`flutter test test/document_chunker_test.dart`、`flutter test test/parse_batch_runner_test.dart test/question_parse_pipeline_test.dart`、关键路径 `rg` 搜索与 `git diff --check`；完整回归测试交由 Gemini/反重力验证。

## [2026-06-04 14:27] - refactor(ai): 抽离微批次解析调度 Runner
- **变更类型**: refactor
- **影响模块**: ai, services, test
- **详细改动明细**:
  - [x] 新建 `lib/services/parse_batch_runner.dart`，集中承载微批次解析的并发 worker、重试次数、冷却策略、成功暂停和失败计数逻辑。
  - [x] 将 `AiService.parseMicroBatches` 中的调度循环迁移到 `ParseBatchRunner.run`，使 `AiService` 只负责提供单块解析函数和 TaskManager 成功/失败回调。
  - [x] 通过 `ParseBatchRunResult` 返回按原 chunk 顺序展开的题目列表和失败数量，避免 UI/任务层直接接触调度内部状态。
  - [x] 保留原有 3 并发、3 次重试、成功后 500ms 暂停、频率限制/网络错误退避冷却策略，降低行为回归风险。
  - [x] 新增 `test/parse_batch_runner_test.dart`，覆盖并发完成顺序不影响输出顺序，以及永久失败时会完成重试并报告失败 chunk。
- **验证状态**: 已完成 `dart format`、`dart analyze lib/services/ai_service.dart lib/services/parse_batch_runner.dart test/parse_batch_runner_test.dart`、`flutter test test/parse_batch_runner_test.dart`、`flutter test test/question_parse_pipeline_test.dart`、关键路径 `rg` 搜索与 `git diff --check`；完整回归测试交由 Gemini/反重力验证。

## [2026-06-04 14:19] - refactor(ai): 抽离题目解析后处理 Pipeline
- **变更类型**: refactor
- **影响模块**: ai, services, test
- **详细改动明细**:
  - [x] 新建 `lib/services/question_parse_pipeline.dart`，集中承载 AI 解析后的题目结构后处理逻辑。
  - [x] 将 `parseMicroBatches` 中的题号标准化、纯答案页识别与答案池拼图归并算法迁移到 `QuestionParsePipeline.mergeAnswerOnlyQuestions`。
  - [x] 将视觉解析返回文本的 JSON 清洗与题干质量闸门迁移到 `QuestionParsePipeline.parseVisionQuestions`。
  - [x] 修改 `lib/services/ai_service.dart`，通过 `_parsePipeline` 调用后处理能力，使 `AiService` 更专注于 LLM 调用、分块调度和任务状态编排。
  - [x] 新增 `test/question_parse_pipeline_test.dart`，覆盖答案页按题号回填和未匹配答案保留两条防御路径。
- **验证状态**: 已完成 `dart format`、`dart analyze lib/services/ai_service.dart lib/services/question_parse_pipeline.dart test/question_parse_pipeline_test.dart`、`flutter test test/question_parse_pipeline_test.dart`、关键路径 `rg` 搜索与 `git diff --check`；完整回归测试交由 Gemini/反重力验证。

## [2026-06-04 13:57] - refactor(ai): 将视觉 LLM 请求迁移至 Provider Strategy
- **变更类型**: refactor
- **影响模块**: ai, services
- **详细改动明细**:
  - [x] 在 `lib/services/llm_providers/llm_provider_client.dart` 中新增 `LlmVisionAsset` 与 `LlmVisionRequest`，支持内联 base64 资产与上传文件资产两种视觉输入形态。
  - [x] 为 `GeminiProviderClient`、`OpenAiCompatibleProviderClient` 与 `ZhipuProviderClient` 增加 `callVision` 实现，分别封装 Gemini `inline_data`、OpenAI-compatible `image_url` 与智谱 PDF 上传解析路径。
  - [x] 在 `LlmApiClient` 中新增 `callVision` 门面方法，使文本与视觉请求都经过统一 provider strategy 分发和配置完整性检查。
  - [x] 重构 `AiService.parseImagesWithVision` 与 `parseFileWithVision`，移除页面服务层中的底层 HTTP 请求拼装，仅保留文件读取、图片压缩、provider 选择约束与题目质量闸门。
  - [x] 新增 `_parseVisionQuestions` 与 `_readFileAsVisionBase64` 边界 helper，将视觉返回文本解析和文件预处理集中管理。
- **验证状态**: 已完成 `dart format`、`dart analyze lib/services/ai_service.dart`、`dart analyze lib/services/llm_api_client.dart lib/services/llm_providers`、关键路径 `rg` 搜索与 `git diff --check`；完整回归测试交由 Gemini/反重力验证。

## [2026-06-04 13:33] - refactor(ai): 防御式收束文本 LLM 请求边界
- **变更类型**: refactor
- **影响模块**: ai, services
- **详细改动明细**:
  - [x] 在 `lib/services/llm_providers/llm_provider_client.dart` 中新增 `LlmProviderProfile` 值对象，统一清洗 `api_key`、`base_url`、`model_name`、`temperature` 与 `reasoning_effort`。
  - [x] 将 `LlmTextRequest` 的配置读取改为通过 `LlmProviderProfile.fromMap` 构造，并在 `LlmApiClient` 中输出缺失字段列表，提升配置错误可诊断性。
  - [x] 将 `AiService.judgeAnswer` 与 `mergeStructuredQuestions` 从手写 Gemini/OpenAI HTTP 分支迁移到 `_apiClient.callText`，让文本请求统一经过 provider strategy。
  - [x] 清理文本生成、单题作答、组卷、错题生成与分块解析中的重复引擎三件套校验，由请求边界统一防御。
  - [x] 使用 Dart fixer 补齐 `ai_service.dart` 中 12 处单行 `if` 大括号，降低后续编辑误挂分支的风险。
- **验证状态**: 已完成 `dart format`、`dart analyze lib/services/ai_service.dart`、`dart analyze lib/services/llm_api_client.dart lib/services/llm_providers`、关键路径 `rg` 搜索与 `git diff --check`；完整回归测试交由 Gemini/反重力验证。

## [2026-06-04 13:18] - refactor(ai): 拆分文本 LLM Provider Strategy
- **变更类型**: refactor
- **影响模块**: ai, services
- **详细改动明细**:
  - [x] 新建了 `lib/services/llm_providers/` 策略目录，定义 `LlmProviderClient` 与 `LlmTextRequest`，将文本模型请求参数从门面客户端中抽离为明确的数据结构。
  - [x] 新增了 `GeminiProviderClient`、`OpenAiCompatibleProviderClient` 与 `ZhipuProviderClient`，分别封装 Gemini、OpenAI-compatible 和智谱文本补全请求路径。
  - [x] 新增了 `LlmProviderRegistry`，按 `baseUrl` 自动选择对应 provider，使 `LlmApiClient` 从底层请求实现收缩为轻量门面。
  - [x] 保留了 `LlmApiClient.buildChatUrl` 与 `extractContent` 兼容入口，避免影响当前视觉解析分支。
- **验证状态**: 已完成 `dart format`、定向 `dart analyze` 与 provider 关键路径搜索；完整回归测试交由 Gemini/反重力验证。

## [2026-06-04 13:08] - refactor(ai): 将 AI 生成题目接口改为返回 QuestionDraft
- **变更类型**: refactor
- **影响模块**: ai, ui, models
- **详细改动明细**:
  - [x] 修改了 `lib/services/ai_service.dart`，将 `generateQuestions`、`generateExamPaper` 与 `generateAndSaveQuestionsFromMistakes` 的公开返回类型从 `List<Map<String, dynamic>>` 收束为 `List<QuestionDraft>`。
  - [x] 在 AI 服务内部完成 JSON Map 到 `QuestionDraft` 的边界转换，让弱类型数据停留在 AI JSON 解析边界内。
  - [x] 修改了 `lib/ui/pages/ai_generator_screen.dart`，移除生成题目和 AI 组卷后的重复 `QuestionDraft.listFromMaps` 转换，直接消费强类型返回值。
- **验证状态**: 已完成 `dart format`、定向 `dart analyze` 与残留调用搜索；完整回归测试交由 Gemini/反重力验证。

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
