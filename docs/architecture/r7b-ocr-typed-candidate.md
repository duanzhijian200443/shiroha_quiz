# R7B OCR Typed Candidate

> **Historical stage contract.** This file preserves the original R7B
> evidence and stage constraints. The focused authority for the P2-B1T2
> Phase 2B typed/legacy parity target is
> [`p2-b1t2-phase2b-typed-legacy-parity.md`](p2-b1t2-phase2b-typed-legacy-parity.md).
> Until that target is implemented, the exact parity checks recorded below
> remain current runtime comparison behavior. The original R7B statement that
> all routes remain `legacyV1` is historical; current production activation is
> governed by R7E.

## Status

R7B 在受支持的单文件 OCR 生产解析链上并行生成 shadow typed candidate，
与最终 legacy review map 做全批次严格一致性门禁，并在全部通过时把 R7A
`_typed_review_v1` envelope 随 pending-review 任务保存并跨重启保留。

R7B 不启用 typed writer：所有任务的有效存储路线仍是 `legacyV1`；
`ImportCommitService` 的 legacy 入库路径不变。

## 生产链路

```text
OcrImportService
  OcrDocument -> OcrSourceDocumentAdapter(random UUID sourceId, label null)
    -> SourceDocument
  merged OcrQuestionRegion -> OcrQuestionRegionBridge -> QuestionRegion
  QuestionRegion -> TypedQuestionAssembler -> QuestionDraftV2
  QuestionDraftV2 + QuestionRegion
    -> QuestionDraftV2LegacyProjector(OcrLegacyProjectionProfile)
    -> projected legacy shape
  -> OcrTypedCandidateBatch（随 OcrImportResult 传递，不进 diagnostics）

ImportPipelineService
  VisionQuestionQualityGate -> ImportQuestionFinalSorter
  -> finalizeAndAuditImportQuestions（最后一次 finalization）
  -> applyOcrTypedCandidateGate（全批次 all-or-nothing）
  -> ImportParseResult.storageRoute/storageReason

ImportTaskCoordinator
  -> TaskManager.keyImportStorageRoute / keyImportStorageReason
  -> requireAttemptReview 保存 envelope 随 parsedData
```

Candidate 永远来自真实生产对象，禁止从最终 legacy map 反向解析、从字符串
猜测 sourceRefs、从 diagnostics 猜测 issues、从 V1 QuestionDraft 反向生成。

## 身份与隐私

- `sourceId`、`reviewItemId`、`questionId` 均为 lowercase canonical UUIDv4；
- `questionId == draft.questionId`；同批 `reviewItemId`/`questionId` 唯一；
- 允许注入 `String Function() uuidV4Factory`，正式入口使用现有 `uuid` 依赖；
- `sourceId` 随机生成、`displayLabel = null`；typed draft/envelope 不含
  filePath、absolute path、sourceName、真实 PDF 名、临时文件名、Provider
  URL 或 OCR endpoint；
- candidate 不保存异常、raw OCR response、diagnostics map 或任意动态对象。

## 全批次门禁

任何一项失败即整批 `legacyV1`、整批无 envelope、记录一个固定 reason：

```text
typed_candidate_shadow_ready
typed_candidate_not_single_file
typed_candidate_unsupported_structure
typed_candidate_repair_applied
typed_candidate_projection_unsupported
typed_candidate_projection_mismatch
typed_candidate_count_mismatch
typed_candidate_identity_mismatch
typed_candidate_baseline_invalid
typed_candidate_raw_explanation_diverged
typed_candidate_snapshot_invalid
typed_candidate_internal_error
```

门禁顺序：

1. 单文件检查（`filePaths.length != 1` -> `not_single_file`）；
2. batch failure（repair applied / unsupported structure / projection
   unsupported / internal error）；
3. candidate 数量 == 最终问题数量；
4. identity：canonical 且唯一的 candidate UUID、唯一正整数 question number、
   candidate 与最终问题按 question number 唯一匹配（绝不按列表 index）；
5. baseline 严格六字段解码（type 0/2/3、content String、options
   List<String>、standardAnswer String、explanation String；禁止
   `toString()` 修复、禁止 silently drop 非字符串 option）；
6. `raw_explanation` 必须为 null / 空串 / 与 explanation 完全相同；
7. parity：type / questionNumber / content / options（顺序严格）/
   standardAnswer（大小写严格）/ explanation / source_page_indices /
   source_block_ids 全部一致；
8. 全部通过后才构造 `TypedReviewSnapshot` 并用 `TypedReviewSnapshotCodec`
   编码，逐题 `encode -> decodeRequired` 自检（identity 与 baseline 一致）；
9. 全部成功后一次性返回带 envelope 的新问题列表；任何一道失败则整批移除
   所有 envelope 并返回原问题列表。

Baseline 只从 `finalizeAndAuditImportQuestions` 完成后的最终 map 生成，
不得使用初始 map、repair 前、gate 前、sorter 前或最后一次 finalization
前的中间结果。

## 任务元数据

- `ImportParseResult` 新增 `storageRoute`（默认 `legacyV1`）与
  `storageReason`（默认 null）；`withStorageMetadata` 工厂用
  `normalizeImportStorageReason` 严格校验；
- route/reason 由 `ImportTaskCoordinator` 写入
  `TaskManager.keyImportStorageRoute` / `keyImportStorageReason`；
- route/reason、candidate、envelope 一律不进入用户可见
  `_import_diagnostics`；
- `TaskManager` 的 attempt 元数据白名单、restart、require review、
  attach diagnostics、中断恢复已由 R7A 保证 route/reason 与 envelope 保留；
- 历史任务无 route 时按 `legacyV1` 解析。

## 语义边界

- AI repair applied -> 整批 `typed_candidate_repair_applied`；attempted but
  unchanged / failed / skipped 可继续进入 parity 门禁；不实现 repair ->
  typed node reconciliation；
- SourceAssetPart / SourceTablePart / UnsupportedSourcePart /
  ocr_image / ocr_table / ocr_unknown / ocr_markdown_fallback /
  LegacyProjectionUnsupportedException / QuestionRegionUnsupportedException
  -> 整批 legacy，异常文本与 kindCode 不写入 task reason；
- 多文件 OCR 不做 typed merge / 跨文件 identity / 多 PDF fusion；
- stem-only 只要求 typed 投影与最终 stem-only baseline 完全一致，不一致即
  projection mismatch；不私改 QuestionDraftV2、不伪造 answer、不重新解析
  最终 map；
- 不新增 Markdown parser、LaTeX tokenizer、公式推断器、图片/表格节点或
  RawFallback 构造器；不声称生产生成 InlineMath/BlockMath/Image/TableNode。

## 非目标

ReviewResult bridge、typed writer 激活、V2-first product read、typed
editor、AI repair typed reconciliation、多文件 typed merge、MCP、数据库
迁移均不在 R7B 范围。数据库版本保持 15。

## 测试

- `test/services/import_pipeline/ocr_typed_candidate_test.dart`：candidate
  契约、batch builder、固定 reason 序列化、全批次门禁单元测试；
- `test/r7b_ocr_typed_candidate_acceptance_test.dart`：完整 synthetic 链
  （regionizer -> reference-answer merge -> legacy assembly -> typed
  candidate -> finalization -> parity gate -> envelope ->
  ImportTaskCoordinator -> 真实 TaskManager persistence/reload ->
  严格 decode `_typed_review_v1`）与 unsupported 整批剔除、多文件
  not_single_file、restart 清空旧 envelope、production 无 typedV2 route
  静态证明；
- `test/ocr_import_service_test.dart` / `test/import_pipeline_mode_routing_test.dart`
  / `test/import_task_coordinator_test.dart` 补充回归断言。

CI 仅在 `pr-contract-checks.yml` 的 focused contract 列表追加
`test/r7b_ocr_typed_candidate_acceptance_test.dart`，不重构 workflow。
