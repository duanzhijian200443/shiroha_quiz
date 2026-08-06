# R7A Typed Review Snapshot

## Status

R7A 只提供 typed review snapshot 的任务级保存基础设施。它不生成生产 typed
candidate，不启用 typed 数据库 writer，也不改变任何既有生产导入输出。

- R7B 才生成生产 typed candidate。
- R7C 才启用 typed writer。
- 显式 typed route 的任务若出现损坏的 typed envelope，必须阻断；不得静默回退到 V1。
- payload 绝不进入 diagnostics、日志、错误文案、报告或 UI；只有 route/reason
  受限标量可以进入 diagnostics。

## Task-level storage route

- `ImportStorageRoute { legacyV1, typedV2 }`，稳定序列化值 `legacyV1` / `typedV2`。
- `TaskManager` 新增 `keyImportStorageRoute = '_importStorageRoute'` 与
  `keyImportStorageReason = '_importStorageReason'`。
- 未声明 route 的历史任务按 `legacyV1` 解析；未知 route 值失败，不得猜测。
- reason 必须是长度 ≤64 的 lower_snake_case 标量。
- route/reason 随 attempt 元数据白名单在 restart、require review、
  attach diagnostics、中断恢复等转换中保留。
- R7A 不决定真实 OCR 任务走哪条路线，只定义、解析与保存该元数据。

## Per-question envelope

保留键固定为 `_typed_review_v1`（`TypedReviewSnapshotCodec.mapKey`）。不得改名、
不得创建多个并行版本键。

根对象为 strict exact-key schema，只允许六个键：

```text
schemaVersion    int == 1
route            'typedV2'
reviewItemId     lowercase canonical UUIDv4
questionId       lowercase canonical UUIDv4
draft            QuestionDraftV2 codec 输出
baselineLegacy   固定六字段 baseline
```

任何多余键、缺失键、错类型、错版本或未知 route 一律失败。typed envelope 内
route 不是 `typedV2` 时失败（`routeMismatch`）。

## draft

`draft` 必须直接使用现有 `QuestionDraftV2Codec`。禁止：

- 重新实现第二套 QuestionDraftV2 JSON codec；
- 先投影到 legacy map 再重建 typed draft；
- 将 draft 编码成字符串后嵌套；
- 宽松忽略未知字段；
- decode 失败回退 legacy。

`envelope.questionId == decoded draft.questionId` 不一致时必须失败。

## LegacyReviewBaseline

不可变 typed value object，固定字段：

```text
type            int，仅 0/2/3
questionNumber  null 或正整数
content         String
options         List<String>，defensive copy 且不可修改
standardAnswer  String
explanation     String
```

不允许 `rawExplanation`、文件路径、diagnostics、Provider 内容、异常或任意扩展
字段。baseline 仅用于后续 R7C 判断用户实际改动字段；R7A 不实现 diff 或
ReviewEdit。

## Identity

`reviewItemId` 与 `questionId` 必须是 lowercase canonical UUIDv4：

```text
xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx
```

R7A 只验证和保存，不在生产流程生成这些 ID（R7B 负责生成）。

## Privacy admission

encode 前与 decode 后，对 `QuestionDraftV2` 全部 RichContent 字段执行现有
`RichContentPrivacyAdmission`：

- stem；
- 每个 option.content；
- `ContentAnswer.content`；
- explanation。

发现 unsafe fallback 时统一映射为 `TypedReviewSnapshotFailure.unsafePayload`，
不得泄露被拒绝的值。安全的 `RawFallbackNode` 可以经过 snapshot round-trip；
R7B 是否允许其进入 typed 生产路线是后续能力路由问题。

## Errors

固定分类 `TypedReviewSnapshotFailure`：

```text
missingPayload / unsupportedSchema / invalidEnvelope / invalidIdentity /
routeMismatch / unsafePayload
```

`TypedReviewSnapshotException` 只携带分类枚举，不携带原始 cause；`toString()`
只输出固定文本，绝不包含题干、答案、解析、source ID、路径、URL、base64、
Provider 内容、token、API key、raw JSON、stack trace 或原异常消息。

## Immutability

解码后的 snapshot、baseline、options 与所有暴露 collection 均不可修改，且不得
保留调用者可变 map/list 的引用。codec 不提供吞掉损坏 payload 的宽松
`tryDecode`；只提供区分键是否存在的纯 helper，键存在时 decode 失败必抛固定异常。

## TaskManager preservation

- `ImportTask.toMap/fromMap` 对嵌套 JSON map（含 envelope）字节语义等价保留。
- `requireAttemptReview` / `_deduplicateQuestions`、`saveReviewDraft`、
  答案蒸馏状态更新均按整题 map 浅拷贝保留 `_typed_review_v1`。
- TaskManager 不主动 decode typed payload；领域验证由 snapshot codec 显式执行，
  TaskManager 的职责是无损保存。
- stale review draft 写入（revision 不匹配）不得覆盖更新版本中的 envelope。

## ImportStagingScreen provenance

`_typed_review_v1` 已加入 `_safeSnapshotProvenanceKeys`，按题 `originalIndex`
身份保存（非当前排序位置），删除/筛选/排序/批量修改/答案蒸馏/解释策略不会导致
未删除题目的 envelope 丢失。页面仍使用现有 `ImportReviewItem<QuestionDraft>`，
不创建 ReviewSession，不启用 typed writer，不向 UI 展示 envelope。

## Non-goals and Class C boundaries

以下任何需求都属于 Class C，立即 BLOCKED：

- 数据库迁移或 v15 sidecar 变更；
- 启用 typed writer（`saveQuestionDraftsV2ToBank` 生产调用）；
- 修改 `_typed_review_v1` schema 或 `QuestionDraftV2Codec` 既有协议；
- 重写 ImportStagingScreen 状态模型；
- 将 payload 放入 diagnostics；
- 触碰 OCR 生产路线或扩大到 R7B/R7C。

数据库版本保持 15；R6 privacy/schema/atomicity/mutation guard 不弱化。

## Verification

- Executor 聚焦验证：三个 R7A 测试文件 + format + analyze + `git diff --check`。
- Verifier 权威矩阵：R7A 测试 + codec/privacy/diagnostics/staging/R6 既有测试 +
  生产文件无差异静态证明。
- 永久验收：`test/r7a_typed_review_snapshot_acceptance_test.dart` 已加入
  `pr-contract-checks.yml` 的 focused contract 列表。
