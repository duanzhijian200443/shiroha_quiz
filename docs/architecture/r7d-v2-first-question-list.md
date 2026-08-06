# R7D — V2-first QuestionList and RichContent Rendering

## Status

R7D 将第一个生产读取页面 `QuestionListScreen` 迁移为 V2-first 读取：

```text
getPersistedQuestionsByBank
→ PersistedQuestion union
→ PersistedQuestionViewAdapter（presentation projection）
→ PersistedQuestionCard
→ RichContentRenderer / StructuredContentRenderer
```

Typed 行的事实来源是 sidecar draft（stem/options/answer/explanation），
V1 compatibility row 只保留给旧消费者，不作为 typed 页面展示来源。

## 实现边界

- 页面唯一读取入口为 `QuestionRepository.getPersistedQuestionsByBank`；
  禁止 `getQuestionsByBank`、`searchQuestions`、`DatabaseHelper`、raw SQL
  或 UI 自行 join sidecar。
- corrupt / partial / unsafe sidecar 由 Repository 整列表硬失败，页面显示
  固定安全错误页（固定文案、重试按钮、`onLoadFinished(null)`），禁止
  legacy fallback，禁止展示异常正文、payload、storageId、sourceId、路径
  或 stack trace。
- typed 内容只走 `RichContentRenderer`（经 `RichContentFieldRenderer`
  桥接），legacy 内容继续走 `StructuredContentRenderer`；不复制 tokenizer、
  LaTeX renderer 或 RawFallback placeholder，typed TextNode 不再交给 legacy
  tokenizer 重解析。
- 搜索为纯内存过滤（`searchText` 小写包含匹配，400ms debounce），禁止
  `searchQuestions`。
- typed 行禁止进入旧编辑器（`onPressed == null`，不创建
  `QuestionEditScreen`，不调用 `updateQuestion`）；legacy 行继续走旧编辑器，
  返回成功后重新读取 union 并重应用当前 query。
- 删除统一走 `QuestionRepository.deleteQuestion(storageId)`，typed 依赖
  v15 FK `ON DELETE CASCADE` 删除 sidecar；失败只显示固定文案。

## R7C 遗留前置项（R7C.1，必须在 R7E 前关闭）

R7D 只做读取与展示，禁止修改 writer。以下两项由独立 R7C.1 任务关闭：

1. **attempt-aware typed commit ownership**：`commitTyped` 必须核验
   TaskManager 中任务仍存在、状态为 pendingReview、attemptToken 与
   attemptNumber 匹配、route 为 typedV2、reason 为
   `typed_candidate_ready`，防止已删除任务、过期页面、被替换 attempt
   继续调用 V2 writer。
2. **durable / awaitable task completion**：`TaskManager.completeTask`
   必须等待持久化完成或提供可等待的完成协议，避免事务成功后任务状态
   持久化失败导致重启后重复提交。

## P3 显示层兼容

R7C 允许题型在 staging 中改变（如 singleChoice → fillBlank/shortAnswer）
并保留原 typed options。R7D 只做显示层兼容：只要
`draft.options.isNotEmpty` 就展示，不以 kind 隐藏。结构性题型转换的收紧
延期至 R7C.1 或 typed editor。

## 隐私与搜索边界

`searchText` 只包含可见内容：TextNode 文本、InlineMath/BlockMath latex、
option label、ChoiceAnswer label、ContentAnswer 文本/数学、解析文本/数学。
RawFallbackNode 不进入搜索文本（不输出 rawJson、payload、source/path/url），
legacy 搜索文本只含 content/options/answer/explanation。

## 非目标

PracticePage / WrongBookPage V2-first、typed editor、选项结构编辑、历史
backfill、数据库版本升级（保持 15）、MCP、P5/P6/P7 不在 R7D 范围。
