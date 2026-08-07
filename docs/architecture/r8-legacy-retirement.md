# R8 Legacy Surface Retirement

## Status

IN PROGRESS（R8D 先行包已落地 shared contract checkpoint；R8A/R8B/R8C 由独立任务关闭）

Database version: 15（不变）

## 1. Purpose

R8 的目标是让 QuestionList / Practice / WrongBook 三个消费者共享同一条
typed-authority 读取不变式：**typed 行的事实来源永远是 sidecar draft**，V1
compatibility row 只服务 legacy 行与旧消费者，绝不作为 typed 页面显示来源；
UI 不得直连 SQLite 或自行 join sidecar。

本文件冻结该不变式以及 R8A/R8B 将要消费的 repository/view 公共契约。本阶段
只做 repository 层 typed 读取与展示投影的扩展，不迁移任何页面，不删除任何 API。

## 2. Production legacy surface inventory

迁移前仍存在的 raw-map 消费面：

- `PracticePage` 经 `ReviewRepository.getStudySessionQuestions` 读 raw map，
  再经 `Question.fromMap` 重解析；typed 行的 V1 投影被当作事实来源，typed
  显式空会被占位化。
- `WrongBookPage` 经 `ReviewRepository.getDetailedWrongQuestions` 读 raw map，
  同样以 V1 投影为准。
- 两处都缺少复习指标以外的 typed 结构信息（stem/options/answer/explanation
  的 RichContent 结构在 raw map 路径下不可用）。

`QuestionRepository.getPersistedQuestionsByBank` 已是 union 双读（typed sidecar
权威），并保留全局错题本分支（`JOIN review_states WHERE lapses > 0 ORDER BY
last_lapse_time DESC`），是 R8 三消费者的公共读取地基。

## 3. Typed authority

- typed 行内容权威 = `question_v2_payloads` sidecar；`PersistedQuestion` union
  的 `TypedPersistedQuestion.draft` 携带权威结构。
- V1 compatibility row 仅在 legacy 行（无 sidecar）时解码为
  `LegacyPersistedQuestion`；corrupt/partial/unsafe sidecar 整表硬失败，绝无
  legacy fallback。
- typed 显式空保持显式空：空 stem/answer/explanation 在投影中保持为空，不得
  fallback V1 decoy、占位符（如「无题干」）或 legacy placeholder。
- 复习指标（lapses/difficulty/stability/lastLapseTime）只读 `review_states`
  已有列，无 schema 变更。

## 4. Compatibility surfaces that remain

- legacy 行继续按 V1 内容渲染，`LegacyPersistedQuestion.question` 与旧编辑器
  payload（`PersistedQuestionView.legacyEditPayload`）保持不变。
- `getQuestionsByBank` / `searchQuestions` / `updateQuestion` /
  `savePreviewQuestion` 等旧 API 继续存在；删除统一归 R8C，本阶段不动。
- `ReviewRepository.getStudySessionQuestions` / `getDetailedWrongQuestions`
  在 R8A/R8B 迁移完成前继续保留给旧消费者；删除归 R8C。
- DB 版本保持 15；不新增表、列、迁移或依赖。

## 5. Practice consumer migration

已由 R8A 关闭。Practice 会话读取与展示不再经过 raw map：

- 会话读取入口：`ReviewRepository.getPersistedStudySessionQuestions(
  bankName, nowUnix, {type, limit})` → `List<PersistedQuestion>`。SQL 形状与
  旧 `getStudySessionQuestions` 一致（新题/到期选择、type 过滤、limit、
  `state DESC, next_review_time ASC` 顺序、全局错题本 `lapses > 0` 且到期
  分支），仅增加 `LEFT JOIN question_v2_payloads` 并逐行 union 解码；任何
  corrupt/partial/unsafe sidecar 使整个会话读取安全失败，无 legacy fallback。
  会话读取不携带 review metrics（practice 不需要）。
- `ReviewEngineService` 会话队列改为 `Queue<PersistedQuestion>`；
  `popNextQuestion()` / `requeueQuestion(PersistedQuestion)` 只接受 union 行，
  不再向页面返回 `Map<String, dynamic>`。
- 页面投影：`PracticeQuestionView`（practice 专用只读投影，位于
  `lib/ui/models/practice_question_view.dart`）承载交互语义：
  - typed 选项以 `optionId`/结构映射（禁止从 V1 字母文本反推）；
  - typed 答案以 `ChoiceAnswer`/`ContentAnswer` 结构映射，显式空保持为空，
    不回退 V1 decoy/占位符；
  - typed 显示只走 `RichContentRenderer`（stem/选项/答案/解析），legacy 行
    保持旧解析与旧渲染（`buildLatexWidget` 路径）。
- 保留交互：选项选择/揭晓（typed 按 optionId 判正确，legacy 按字母）、FSRS
  提交（`submitReview(storageId, grade)` 写入 review_states/review_logs）、
  主观题输入与 AI 判卷（typed 用安全文本投影，RawFallback 不进文本）、题型
  过滤、limit、顺序语义、pomodoro 会话、preview 保存（仅 preview 行可达，
  DB guard 阻断 typed 冲突）、删除（`deleteQuestion(storageId)` + v15 FK
  cascade）。typed 行不出现 preview 保存/旧编辑入口。

## 6. Wrong-book consumer migration

已由 R8B 关闭。WrongBookPage 已是 V2-first 读取：
- 页面唯一读取入口是 `QuestionRepository.getPersistedWrongQuestions()`，
  返回 `List<PersistedQuestion>`；过滤（`lapses > 0`）与排序（
  `last_lapse_time DESC`）在 SQL 层完成。页面不再调用
  `ReviewRepository.getDetailedWrongQuestions` /
  `getWrongBookEntries`（旧 API 删除归 R8C）。
- 复习指标随 union 行返回：`PersistedQuestion.reviewMetrics`（
  `PersistedQuestionReviewMetrics`，含 lapses/difficulty/stability/
  lastLapseTime），经 `PersistedQuestionViewAdapter` 投影到
  `PersistedQuestionView.reviewMetrics`，由 `PersistedQuestionCard`
  展示错误次数/难度系数/稳定性。
- typed 行以 sidecar draft 为事实来源，经 `PersistedQuestionViewAdapter`
  与 `RichContentRenderer` 渲染；legacy 行保持 legacy 投影与旧渲染；
  typed 显式空不回退 V1 decoy/占位符。
- typed 行禁止进入旧编辑器（编辑入口禁用，`onPressed == null`）；
  legacy 行继续走 `QuestionEditScreen`。
- 删除统一走 `QuestionRepository.deleteQuestion(storageId)`，typed 依赖
  v15 FK `ON DELETE CASCADE` 清理 sidecar；清除错题（若只改
  review_states）保持不动。
- `getPersistedQuestionsByBank` 的全局错题本分支同样携带指标，QuestionList
  错题本视图与 WrongBook 共享同一语义。

## 7. Mutation safety

- 本阶段零 writer 改动：typed commit 事务、attempt 校验、preview REPLACE
  防碰撞、`updateQuestion` typed 行拦截全部保持不变。
- 删除仍统一走 `QuestionRepository.deleteQuestion(storageId)`，依赖 v15 FK
  `ON DELETE CASCADE` 清理 sidecar 与 review_states。
- 展示投影只读，任何 typed 行不得进入旧编辑器（`onPressed == null` 语义由
  R7D 冻结，本阶段不改）。

## 8. Retired production paths

R8A/R8B/R8C 已完成退役：

- `PracticePage` / `WrongBookPage` 的 raw-map 读取路径；
- 上述两个页面中对 typed 行 V1 投影的重解析与占位化行为；
- `QuestionRepository.getQuestionsByBank` / `searchQuestions`
  （R8C 删除，无剩余消费者）；
- `ReviewRepository.getStudySessionQuestions` / `getDetailedWrongQuestions`
  及 `ReviewEngineService.getWrongBookEntries` / `getDetailedWrongQuestions`
  转发（R8C 删除，无剩余消费者）；
- `ReviewRepository.deleteQuestionAndRelatedData` / `deleteQuestionBank`
  及 `ReviewEngineService` 对应转发（R8C 删除；删除统一走
  `QuestionRepository.deleteQuestion` / `deleteQuestionBank`）；
- `lib/core/quiz_session_controller.dart`（R8C 删除，无 UI 消费者）。

## 9. Deferred typed editing

- typed 编辑器、选项结构编辑；
- 历史 rejected audit、V1 backfill；
- 删除 legacy writer 或 V1 compatibility row；
- 数据库版本升级（保持 15）、MCP、P5/P6/P7、多文件 typed merge、
  AI repair typed reconciliation。

## 10. Final retirement criteria

全部满足才算 R8 关闭：

1. QuestionList / Practice / WrongBook 均经 `PersistedQuestion` union 读取；
   迁移后的三个消费面无 raw map 返回、无 UI 直连 SQLite/join sidecar。
2. typed 行三处展示均以 sidecar 为权威，显式空不回退 V1 decoy/占位符。
3. WrongBook 展示指标（lapses/difficulty/stability/lastLapseTime）来自
   `review_states` 已有列，无 schema 变更。
4. 旧 raw-map 消费面在确认无消费者后由 R8C 删除；legacy 行行为不变。
5. DB 版本保持 15，无 schema/migration/依赖变更。
