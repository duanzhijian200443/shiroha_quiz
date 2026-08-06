# R7C ReviewResult Writer Activation

## Status

R7C 首次启用生产 typed writer：受支持的、通过全部 R7B 门禁的**新单文件 OCR**
任务在解析时冻结为 `typedV2` + `typed_candidate_ready`，人工校对后经
`TypedReviewResultBuilder` -> `ReviewSession` -> `ReviewResult` ->
`QuestionRepository.saveQuestionDraftsV2ToBank` 入库。

历史 R7B pending task（`legacyV1` + `typed_candidate_shadow_ready`）**不迁移、
不改写、不自动升级**，继续走 legacy writer。

## 激活规则（C0 硬化后）

- eligible gate 成功：`route = typedV2`、`reason = typed_candidate_ready`、
  每道题携带 `_typed_review_v1` envelope。
- ineligible gate：`route = legacyV1`、对应固定失败 reason、整批**主动剥离**
  既有 envelope（新建不可变 question map，不原地修改调用方 map）。
- candidate 或最终 gate 验证 `draft.sourceRefs` 非空时每个 `sourceId` 为
  lowercase canonical UUIDv4；失败 -> `typed_candidate_identity_mismatch`，
  不输出原 source ID。
- 唯一严格验证边界 `validateImportStorageMetadata`：legacyV1 接受 null 或合法
  lower_snake_case reason；typedV2 只接受精确 `typed_candidate_ready`；
  未知 route、typedV2+null、typedV2+shadow_ready、非法 reason 一律失败。
  Pipeline、Coordinator、Staging 与 typed commit 全部经过该边界；旧的 const
  constructor 仅为兼容保留。

## 写入契约

- `ImportCommitService.commitLegacy` 为既有 legacy 行为；`commit` 仅委托
  legacy；`commitTyped` 只调用 `saveQuestionDraftsV2ToBank`，禁止 legacy
  writer、DatabaseHelper 或 raw SQL。
- `commitTyped` 流程：严格 route/reason 与 origin 验证 -> 现有 legacy
  finalization（`preserveRawExplanation: false`）-> analyzer/blocking 质量
  门禁 -> `TypedReviewResultBuilder` -> accepted finalDrafts -> V2 事务 ->
  `completeTask` -> 成功结果。质量门禁阻断时不构建 ReviewResult、不调用
  Repository。
- Repository 事务失败：不 completeTask、不 fallback、不清 review draft，
  抛出固定安全 `TypedReviewCommitException(persistenceFailed)`。
- 一个任务只调用一个 writer；typed 失败后 task 保持 `pendingReview`。

## TypedReviewResultBuilder

纯业务逻辑组件（不访问 SQLite/Repository/TaskManager/UI/Provider/filesystem/
network）：

- 输入 `TypedReviewCommitInput{reviewItemId, envelope, currentDraft}`（防御
  拷贝，不携带 provenance map、diagnostics、路径或 Provider 内容）。
- 输出 `TypedReviewBuildResult{reviewResult, acceptedDrafts}`；
  `acceptedDrafts` 只从 `ReviewResult.items where decision == accepted`
  的 `finalDraft` 提取。
- 必须提供 `taskId/attemptToken/attemptNumber`，经
  `QuestionDraftV2ReviewSessionAdapter.openSession` 创建 ReviewSession；
  `sessionId` 为受控 opaque（`review_<uuid-v4>`，可注入 factory）。
- 每个输入严格恢复 envelope：存在 -> `decodeRequired` ->
  reviewItemId 一致 -> questionId 一致 -> route typedV2 -> privacy admission
  -> sourceId canonical -> 同批 reviewItemId/questionId 唯一；任一失败整个
  typed commit 阻断。
- 与 snapshot baseline 严格比较：未变化字段一律 `ReviewFieldEdit.unchanged()`
  （保留原 RichContent 节点、InlineMath/BlockMath/RawFallback、sourceRefs、
  assetRefs、issues、optionId、option sourceRefs）；stem/explanation/answer
  编辑替换为精确 `TextNode`（不 trim、不重猜结构）；空 answer/explanation 映射
  clear；题型变化映射 QuestionKind。
- 题号保持 `snapshot.draft.questionNumber`，禁止从列表 index 重建；baseline
  与 draft 题号不一致即 block。
- options 首轮只支持 content 编辑（数量/顺序/label 不变，复用 optionId 与
  sourceRef）；新增/删除/重排/label 变化/重复 label/无法唯一解析 ->
  `unsupportedOptionEdit` block，固定用户提示：
  `当前结构化题目暂不支持修改选项数量、顺序或标签，请恢复后再入库`。
- 真实调用 `edit -> decide(accepted) -> complete`；无变化题不 edit 直接
  decide accepted；CompletionAssessment 与 session 顺序一致、issueCount 为
  original.issues 长度、policyBlockers 为空（仅 legacy 质量门禁通过后）。
  禁止手工 `new ReviewResult`。
- 当前 commit set 只覆盖 staging 中仍存在的题目；删除题不进入
  session/result/DB。R7C ReviewResult 是 commit-set result，不是完整历史
  审核审计日志；永久 rejected audit 延期。

## ImportStagingScreen 接线

- 从 `widget.diagnostics[keyImportStorageRoute / keyImportStorageReason]`
  读取并严格验证：missing -> legacyV1；legacyV1（含历史 shadow_ready）->
  `commitLegacy`；typedV2+ready -> `commitTyped`；其他组合 -> block。
- typed input 按 `_allItems` 顺序以 `originalIndex` 关联
  `_reviewItemIds` 与 `_snapshotProvenance`；不使用可见排序 index/列表位置；
  marker/envelope 缺失即阻断。marker 缺失时从 envelope 的 `reviewItemId`
  恢复（restart 后仍可构造 typed input）。
- task origin（taskId + attemptToken + attemptNumber）缺失即阻断。
- typed 失败显示固定文案、保持页面、保持 task pendingReview；禁止
  `Text('入库失败: $e')`；严禁 typed error fallback legacy。
- 成功仅 commit service 返回后触发 `globalBankUpdateNotifier.value++`、
  成功提示并返回。

## 安全错误

`TypedReviewCommitFailure` 固定 12 值：invalidRoute / invalidOrigin /
missingSnapshot / corruptSnapshot / identityMismatch / baselineMismatch /
unsupportedOptionEdit / qualityBlocked / emptyCommit / reviewCompletionFailed /
unsafePayload / persistenceFailed。`TypedReviewCommitException` 只携带 enum，
`toString()` 固定，不含题目/envelope/路径/source ID/DB error/stack/Provider
内容。

## 非目标（R7C 不实现）

QuestionListScreen V2-first、PracticePage/WrongBookPage 迁移、搜索 typed row、
typed editor、option 结构编辑、历史 rejected audit、历史 V1 backfill、
数据库迁移（版本保持 15）、删除 legacy writer、删除 V1 compatibility row、
MCP、P5/P6/P7、AI repair typed reconciliation、多文件 typed merge。

## 验收

- 纵向 acceptance（`test/r7c_review_result_writer_activation_acceptance_test.dart`）
  覆盖：完整链 typedV2 成功（真实 close/reopen database +
  `getPersistedQuestionsByBank -> TypedPersistedQuestion`）、Repository 事务
  失败零行、corrupt envelope 前置阻断、历史 shadow 保持 legacy。
- CI 仅把该 acceptance 追加到既有 focused contract 列表。
