# R7E Full Production V2 Activation Acceptance

## Status

ACCEPTED（R7E 自检全绿；最终签注由 Verifier/Reviewer 链给出）

Database version: 15（不变）

R7E 是 acceptance-first 集成门禁，不是功能开发。它把 R7B/R7C/R7C.1/R7D
已冻结的生产契约连成一条真实链路证明：新的单文件 OCR 任务从解析到
人工校对再到原子入库，最终以 typed 行经 V2-first 读取渲染，且任何
corrupt/partial sidecar 都不会静默降级到 V1。

## 1. Production V2 activation boundary

生产 typed 激活只发生在 OCR 解析链末端，且必须同时满足：

- 单文件（多文件一律 `typed_candidate_not_single_file`）；
- 全批 typed candidate 生成成功；
- 数量、identity、baseline、raw_explanation、parity 全部门禁通过；
- 最终 `storageRoute == typedV2` 且 `storageReason == typed_candidate_ready`。

eligible 门禁位于 `ocr_typed_candidate.dart`，是唯一允许出现
`ImportStorageRoute.typedV2` 的生产位置；`OcrImportService`、
`ImportPipelineService`、`ImportTaskCoordinator` 本身不得直接引用
typedV2 常量。历史 legacyV1 + shadow-ready 任务不迁移、不改写、不自动
升级，继续走 legacy writer。

## 2. End-to-end data flow

```text
synthetic OcrDocument（provider boundary 注入，Provider calls = 0）
  -> OcrImportService -> ImportPipelineService
  -> applyOcrTypedCandidateGate -> typedV2 + typed_candidate_ready
  -> ImportTaskCoordinator -> TaskManager pendingReview
  -> 真实 SQLite v15 文件 DB 持久化 -> reload（模拟 restart）
  -> ImportStagingScreen typed 流程（用户可见 mutation -> 最终 flush）
  -> ImportCommitService.commitTyped
  -> QuestionRepository 原子事务（questions + sidecar + review_states
     + bank_folders + import_tasks 完成态，单事务）
  -> close/reopen -> QuestionListScreen -> getPersistedQuestionsByBank
  -> typed 行经 RichContent 渲染
```

任务元数据（route/reason/attempt token/attempt number/attempt
state/review revision）与 `_typed_review_v1` envelope 随任务在 restart、
require review、review draft 保存等转换中无损失保留；`parsed_data` 在
完成时清空。

## 3. Typed eligibility contract

- 新单文件 OCR 且全部门禁通过 -> `typedV2` + `typed_candidate_ready`，
  每道题携带 `_typed_review_v1` envelope；
- envelope 为 strict exact-key schema（schemaVersion 1、route
  typedV2、canonical UUIDv4 reviewItemId/questionId、QuestionDraftV2
  codec 直编 draft、六字段 baseline）；任何多余/缺失键、错类型、错版本、
  未知 route 一律失败，绝不回退 V1；
- baseline 只从最终 finalization 后的用户可见 legacy map 生成；
- stem-only 题目允许（typed 投影与最终 stem-only baseline 必须完全
  一致），缺答案属于可校对项而非结构阻断项；
- 全批 all-or-nothing：任一失败移除全部 envelope 并记固定 reason，
  legacy 导入不受影响。

## 4. Review snapshot contract

- typed 校对通过 `TypedReviewResultBuilder` -> `ReviewSession` ->
  `ReviewResult` 构建，禁止手工构造 ReviewResult；
- 与 snapshot baseline 严格比较：未变字段保持
  `ReviewFieldEdit.unchanged()`（保留 RichContent 节点、sourceRefs、
  assetRefs、issues、optionId/sourceRef）；编辑替换为精确 TextNode，
  空 answer/explanation 映射 clear；
- 用户可见 mutation（如答案提炼）必须经 review-draft 保存链落地：
  base snapshot -> merge（expectedRevision 校验）-> 最终 flush 返回
  的 revision 与 post-flush payload 绑定，禁止 flush 前捕获 payload；
- 题号保持 `snapshot.draft.questionNumber`，禁止从列表 index 重建；
- 删除题不进入 session/result/DB；commit set 只覆盖 staging 现存题目。

## 5. Atomic commit contract

`commitTyped` 前置校验：

- `validateImportStorageMetadata`（typedV2 只接受
  `typed_candidate_ready`）；
- origin 非空、expectedReviewDraftRevision > 0；
- `TaskManager.beginTypedCommitAttempt` 租约：task 存在、pendingReview、
  attemptToken/attemptNumber 精确匹配、readyForReview、route/reason
  精确匹配、非空 parsedData、revision 等于期望值。

`QuestionRepository.commitQuestionDraftsV2ForImport` 在单个 SQLite
事务内：

1. 持久化 ownership 严格门禁（import_tasks 单行、pendingReview 冻结
   码、parsed_data 非空、diagnostics 严格解码并精确匹配 attempt/
   route/reason/revision）；
2. 写入 questions 父行 + question_v2_payloads sidecar
   （payload_schema_version 2）+ review_states + bank_folders upsert；
3. compare-and-set 完成 import_tasks（affected rows == 1，否则整体
   rollback）。

任一失败：零父行、零 sidecar、零 review_state、任务保持 pendingReview、
无 legacy fallback、抛出只携带 enum 的固定安全异常。一次 commit 只写
一批，重复并发 commit 由租约拒绝（`commitInProgress`），完成后
`parsed_data` 清空、task 置 completed。

## 6. Restart durability

- candidate -> task 持久化（真实 v15 文件 DB）-> 重新加载 -> staging
  -> typed commit -> 关闭重开 -> QuestionList typed 行；
- restart 后 route/reason/envelope 不变，typed 流程不静默降级为
  legacy；reload 出的 pendingReview 任务仍走 `commitTyped`；
- 完成态在 DB 中是权威：重启后任务保持 completed、parsed_data 为
  null，旧 pendingReview 快照不能复活。

## 7. V2-first read authority

- 页面唯一读取入口是
  `QuestionRepository.getPersistedQuestionsByBank`，返回
  `PersistedQuestion` union；禁止 `getQuestionsByBank`、
  `searchQuestions`、DatabaseHelper 直连或 UI 自 join sidecar；
- typed 行事实来源是 sidecar draft；V1 compatibility row 仅为旧消费者
  保留，绝不作为 typed 页面显示来源；
- typed 内容只走 `RichContentRenderer`（经 `RichContentFieldRenderer`
  桥接），legacy 内容继续走 `StructuredContentRenderer`；
- typed 显式空字段保持显式空，不回退 legacy placeholder（如“无解析”）
  或 compat 行内容；
- 搜索为纯内存过滤，RawFallbackNode 不进搜索文本；typed 行禁止进入
  旧编辑器（onPressed == null），删除统一走
  `deleteQuestion(storageId)` 并依赖 v15 FK 级联。

## 8. Mixed legacy compatibility

同一 bank 可同时存在 typed 行与历史 legacy 行：

- 两行分别渲染，互不污染：typed 显示 sidecar 内容，legacy 显示其 V1
  内容；
- 即使 V1 compatibility 字段被人为改写成与 sidecar 不同的内容
  （decoy），typed 页面仍只显示 sidecar 内容，decoy 永不渲染；
- legacy 行继续支持旧编辑器入口；typed 行编辑入口保持禁用。

## 9. Corruption / privacy behavior

- 任一 typed 行的 sidecar 为 corrupt/partial/unsafe（malformed JSON、
  缺键/错类型、schema 不匹配、unsafe payload）时，整批
  `getPersistedQuestionsByBank` 安全失败：无 compatibility fallback、
  无 legacy-decoy 渲染、页面显示固定安全错误文案 + 重试按钮 +
  `onLoadFinished(null)`；
- 失败异常只携带固定分类 enum，不泄露题干、答案、解析、source id、
  路径、DB error 或 stack；
- diagnostics/日志/报告只允许 route/reason 等受限标量；payload、
  完整 prompt、provider 内容、原始 OCR 文本、Base64、私有路径一律
  不进输出；
- 所有证据为 synthetic/offline：不调用真实 OCR/AI provider、不联网、
  不读私有 PDF、不触碰 Replay；Provider calls 保持 0。

## 10. Deferred R8 scope

以下内容不在 R7E 范围，属于后续任务：

- PracticePage / WrongBookPage V2-first 迁移；
- typed 编辑器、选项结构编辑、历史 rejected audit、V1 backfill；
- 删除 legacy writer 或删除 V1 compatibility row；
- 数据库版本升级（保持 15）；
- MCP、P5/P6/P7、多文件 typed merge、AI repair typed reconciliation、
  attempt ownership / 原子事务重设计。

## 11. R1–R7 completion criteria

R1–R7 冻结契约以各自 current-contract 文档与永久 acceptance 测试为准：

- R1/R2：纯内容与 source-domain 隐私迁移（RichContentCodec、
  QuestionDraftV2Codec、SourceDocument 递归隐私准入）；
- R3：QuestionRegion 类型化组装与 legacy shadow 全量 parity；
- R5：RichContent 渲染器契约（test/r5_rich_content_renderer_test.dart）；
- R6：V2 持久化映射与 v15 迁移契约
  （test/r6_question_v2_persistence_acceptance_test.dart、
  test/question_v2_persistence_mapper_test.dart、
  test/database_v15_migration_test.dart）；
- R7A：typed review snapshot 任务级保存；
- R7B：OCR typed candidate 全批门禁与 envelope 随任务持久化；
- R7C：typed writer 激活与 staging 接续；
- R7C.1：attempt-aware typed commit finalization 与最终 review
  snapshot 闭包；
- R7D：V2-first QuestionList 读取与 RichContent 渲染；
- R7E（本文件）：以上契约连成一条生产链路的完整激活证明。

R7E 完成后，`test/r7e_full_production_v2_activation_acceptance_test.dart`
已加入 `pr-contract-checks.yml` 的 focused contract 矩阵；数据库版本
保持 15，无 schema/依赖/CI 结构变更。
