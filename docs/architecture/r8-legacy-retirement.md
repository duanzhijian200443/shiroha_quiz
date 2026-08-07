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

由 R8A 关闭（本阶段只冻结契约）：

- Practice 的新读取必须返回 `PersistedQuestion`（或携带复习指标的 typed
  DTO/view），禁止向消费者返回 `Map<String, dynamic>`；禁止 UI 直连
  SQLite/join sidecar。
- 到期/新题过滤、limit、排序保持在 repository 层 SQL；全局错题本分支保持
  `lapses > 0` 且到期语义。
- typed 行渲染只走 `RichContentRenderer`（经 `RichContentFieldRenderer`），
  typed 显式空不回退 V1。
- 复习指标随 wrong-book 分支（含全局错题本）可用，普通 bank 读取可为 null。

## 6. Wrong-book consumer migration

由 R8B 关闭（本阶段已冻结读取契约）：

- 新读取入口：`QuestionRepository.getPersistedWrongQuestions()`，返回
  `List<PersistedQuestion>`；过滤（`lapses > 0`）与排序（`last_lapse_time
  DESC`）在 SQL 中完成。
- 复习指标随 union 行返回：`PersistedQuestion.reviewMetrics`（
  `PersistedQuestionReviewMetrics`，含 lapses/difficulty/stability/
  lastLapseTime），经 `PersistedQuestionViewAdapter` 投影到
  `PersistedQuestionView.reviewMetrics` 供卡片展示。
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

R8A/R8B/R8C 完成后退役：

- `PracticePage` / `WrongBookPage` 的 raw-map 读取路径；
- 上述两个页面中对 typed 行 V1 投影的重解析与占位化行为；
- `ReviewRepository.getStudySessionQuestions` / `getDetailedWrongQuestions`
  （删除归 R8C，需先确认无剩余消费者）。

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
