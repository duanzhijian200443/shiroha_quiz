# R8 Legacy Surface Retirement

## Status

COMPLETE（R8D/R8A/R8B/R8C 已落地；final acceptance 由
`test/r8_legacy_retirement_acceptance_test.dart` 永久证明）

Database version: 15（不变）

## 1. Purpose

R8 的目标是让 QuestionList / Practice / WrongBook 三个消费者共享同一条
typed-authority 读取不变式：**typed 行的事实来源永远是 sidecar draft**，V1
compatibility row 只服务 legacy 行与旧消费者，绝不作为 typed 页面显示来源；
UI 不得直连 SQLite 或自行 join sidecar。

本文件描述退役完成后的当前契约：已退役的旧 raw-map 消费面、保留的兼容
表面、三个消费者共同的 typed 读取入口，以及明确延后的工作。

## 2. Retired

以下生产路径已删除，无剩余消费者：

- `QuestionRepository.getQuestionsByBank` / `searchQuestions`；
- `ReviewRepository.getStudySessionQuestions` /
  `getDetailedWrongQuestions`，及
  `ReviewEngineService.getWrongBookEntries` /
  `getDetailedWrongQuestions` 转发；
- `ReviewRepository.deleteQuestionAndRelatedData` /
  `deleteQuestionBank`，及 `ReviewEngineService` 对应转发（删除统一走
  `QuestionRepository.deleteQuestion` / `deleteQuestionBank`）；
- `lib/core/quiz_session_controller.dart`（无 UI 消费者）；
- `PracticePage` / `WrongBookPage` 的 raw-map 读取路径，以及这两个页面中
  对 typed 行 V1 投影的重解析与占位化行为。

## 3. Retained Compatibility

以下表面继续保留，legacy 行行为不变（retirement ≠ unsupported）：

- **legacy writer**：`saveQuestionsToBank` / `saveQuestionDraftsToBank` /
  `updateQuestion`（legacy 分支）/ `savePreviewQuestion`（legacy 分支）继续
  服务 legacy 行；`QuestionEditScreen` 旧编辑器只对 legacy 行开放；
- **historical legacy renderer**：历史 legacy 行继续按 V1 内容渲染
  （`StructuredContentRenderer` / `buildLatexWidget` 路径），
  `LegacyPersistedQuestion.question` 与
  `PersistedQuestionView.legacyEditPayload` 保持不变；
- **V1 compatibility rows**：typed 行仍保留 V1 兼容父行，仅服务旧消费者与
  旧编辑器，绝不作为 typed 页面显示来源；typed 显式空不回退 V1 decoy 或
  占位符；
- **migration / schema**：v15 schema（`question_v2_payloads` sidecar、
  `ON DELETE CASCADE`）保持不变，不新增表、列、迁移或依赖；
- **DatabaseHelper 底层旧读取**：`getQuestionsByBank` / `searchQuestions`
  作为底层数据库方法保留给未迁移的旧调用方；三个消费者不再使用；
- **统一删除入口**：`QuestionRepository.deleteQuestion(storageId)` /
  `deleteQuestionBank`，typed 行依赖 v15 FK 级联清理 sidecar 与
  review_states。

## 4. Typed production authority

三个消费者的读取入口全部返回 `PersistedQuestion` union：

- QuestionList：`QuestionListScreen` →
  `QuestionRepository.getPersistedQuestionsByBank`；
- Practice：`PracticePage` → `ReviewEngineService.initStudySession` →
  `ReviewRepository.getPersistedStudySessionQuestions`（新题/到期选择、
  type 过滤、limit、`state DESC, next_review_time ASC` 顺序、全局错题本
  分支均在 SQL 层完成，仅增加 sidecar LEFT JOIN 并逐行 union 解码）；
- WrongBook：`WrongBookPage` →
  `QuestionRepository.getPersistedWrongQuestions`（`lapses > 0` 过滤与
  `last_lapse_time DESC` 排序在 SQL 层完成，指标随 union 行返回）。

不变式：

- typed 行内容权威 = `question_v2_payloads` sidecar（`QuestionDraftV2`
  draft）；corrupt/partial/unsafe sidecar 使整批读取安全失败，绝无 legacy
  fallback；
- typed 显式空保持显式空，不回退 V1 decoy、占位符（如「无题干」）或 legacy
  placeholder；
- 复习指标（lapses/difficulty/stability/lastLapseTime）只读
  `review_states` 已有列，无 schema 变更；
- 页面只经投影（`PracticeQuestionView` / `PersistedQuestionView`）消费
  union 行，不直连 SQLite、不自 join sidecar。

## 5. Mutation safety

- `updateQuestion` / `savePreviewQuestion` 对 typed storageId 的 legacy
  content mutation 被拦截（`QuestionV2LegacyMutationBlockedException`），
  sidecar 与 V1 兼容投影不变；legacy 行 mutation 继续按既有行为工作；
- 删除统一走 `QuestionRepository.deleteQuestion(storageId)`，依赖 v15 FK
  `ON DELETE CASCADE` 清理 sidecar 与 review_states；清除错题（只改
  review_states）保持不变；
- 展示投影只读；typed 行禁止进入旧编辑器（编辑入口 `onPressed == null`）。

## 6. Deferred

以下内容明确延后，不属于 R8 关闭范围：

- typed 编辑器、选项结构编辑；
- 历史 rejected audit、V1 backfill；
- 删除 legacy writer 或 V1 compatibility row；
- 数据库版本升级（保持 15）、MCP；
- P5/P6/P7、多文件 typed merge、AI repair typed reconciliation；
- RichContent asset/table 扩展。

## 7. Final retirement criteria

全部满足，R8 关闭：

1. QuestionList / Practice / WrongBook 均经 `PersistedQuestion` union 读取；
   三个消费面无 raw map 返回、无 UI 直连 SQLite/join sidecar（由
   `test/r8_legacy_retirement_acceptance_test.dart` 的计数/边界场景永久
   证明）；
2. typed 行三处展示均以 sidecar 为权威，显式空不回退 V1 decoy/占位符；
3. WrongBook 展示指标来自 `review_states` 已有列，无 schema 变更；
4. 旧 raw-map 消费面已删除，legacy 行行为不变（历史 legacy 行在三个
   消费者中仍可用）；
5. DB 版本保持 15，无 schema/migration/依赖变更。
