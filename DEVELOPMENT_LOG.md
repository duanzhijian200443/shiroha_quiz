# Development Log

## [2026-07-29 15:58] - test(import): 固化 V2 重构基线与离线审计工具

- **变更类型**: test
- **影响模块**: import, architecture, developer_tooling
- **详细改动明细**:
  - [x] 新增 Content Model V2 当前数据流、重复模型、兼容桥与 R0-R8 渐进迁移基线文档，不修改生产模型或数据库。
  - [x] 用脱敏合成数据固化 2022/2019 等价导入、HTML/LaTeX 渲染、校对快照和旧题目行兼容行为。
  - [x] 新增只读取 tracked Dart diff 的聚焦验证脚本，显式测试路径才运行测试，并传播失败 verdict。
  - [x] 新增 `shiroha-import-audit` 项目 Skill，约束离线验收指标、Provider 调用与隐私边界。
- **验证状态**: characterization tests 10/10、PowerShell 验证脚本契约测试、Skill validator、PowerShell AST 与 focused analyze 均通过。

## [2026-07-29 01:12] - fix(import): 收紧 LaTeX 与 OCR smoke 安全契约

- **变更类型**: fix
- **影响模块**: import_pipeline, ocr_smoke, tests
- **详细改动明细**:
  - [x] 收紧裸 LaTeX 环境前缀边界，拒绝控制词参数被误包装，并让缺失环境终止符保持原文进入 canonical Review。
  - [x] 保持 Q21 为单一 `latex_unrenderable`，清除陈旧 `dangling_latex` 与普通 repair candidate，离线 Provider 调用保持为零。
  - [x] OCR smoke 显式采用主观题解析保留策略，补齐安全报告初始化、状态同步和终端摘要兼容。
  - [x] 补充 Normalizer、最终审计、Renderer、Acceptance 与 OCR smoke 聚焦回归测试。
- **验证状态**: LaTeX/Renderer 52/52、FieldPolicy/OCR/E1A 46/46、Acceptance 63/63、真实 Replay 1/1、OCR smoke 47/47 通过；focused analyze 与 PowerShell 语法检查通过。

## [2026-07-28 23:41] - feat(import): 回填卷尾参考答案索引

- **变更类型**: feat
- **影响模块**: import_pipeline, import_acceptance, tests
- **详细改动明细**:
  - [x] 新增卷尾参考答案索引、保守提取与冲突感知合并，在 Assembler 前回填缺失答案。
  - [x] 统一参考答案标题边界，并支持 OCR block 内嵌卷尾标题的安全切分。
  - [x] Acceptance 仅输出题号、计数和白名单诊断码，保持 Replay 离线且 Provider 调用为零。
  - [x] 补充提取、合并、Regionizer、OCR Service 与只读 Replay 聚焦回归测试。
- **验证状态**: 聚焦测试 60/60 通过，12 个相关文件 analyze 无问题；E1A 已审查通过，Q21 LaTeX 为阶段外既有失败。

## [2026-07-28 03:15] - feat(import): D2A & D2B 阶段核心实现：主观题答案提炼、审查快照与 LaTeX 环境自动归一化校验

- **变更类型**: feat
- **影响模块**: import_pipeline, import_review, task_manager, ui, tests
- **详细改动明细**:
  - [x] **D2A 主观题提炼与快照**:
    - 收紧主观题本地答案提取，仅接受明确标签（`答案：`、`标准答案：`等）及确定性结论。
    - 明确识别证明题，防范虚假答案写入。
    - 接入 AI 提炼 240 字限制与 `basis=explanation` 结构安全校验。
    - TaskManager 支持 Review Snapshot 串行持久化、稳定 Revision 与 Provenance 保留。
  - [x] **D2B LaTeX 归一化与校验**:
    - 新增 `LatexBlockEnvironmentNormalizer` 与 `LatexRenderabilityChecker`。
    - 自动识别并包含安全 `array` / `matrix` 等 Bare 环境包裹为 `\[...\]`。
    - 完善 `auditFinalQuestionLatex` 先确定性修补、再归一化、最后 Preflight 校验流。
    - 统一渲染层 `StructuredContentRenderer` 结构安全预检与嵌套定界符配对处理。
  - [x] **测试与验证**:
    - 150+ 单元 / Widget / Acceptance 测试用例 100% 通过。
- **验证状态**: 本地 flutter analyze (0 error, 0 warning) & flutter test 全量通过。

## [2026-06-08 08:30] - fix(latex): Step 6-C — ASCII punctuation boundary in bare equation scanning

- **Change type**: fix
- **Affected modules**: latex, tests
- **Details**:
  - [x] `_isEquationBoundaryPunctuation`: extends `_isNaturalLanguageBoundary` with ASCII `,` `;` `:`. Used only in `_findBareEquationEnd`.
  - [x] Test tightened: comma after `y=e^{...}` must NOT be inside delimiter → `\(y=e^{-\int...}\),` (correct).
  - [x] Added `x=1` regression guard (no LaTeX command → no-op).
  - [x] 24/24 tests pass, `dart analyze` clean.
  - [x] No renderer / tokenizer / prompt / PDF renderer / pipeline changes.
- **Verification**: `flutter test test/latex_import_repair_test.dart` 24/24 pass.

## [2026-06-08 08:20] - fix(latex): Step 6-B — detect and wrap bare equations like y=e^{-\int...} (23/23 pass)

- **Change type**: fix
- **Affected modules**: latex, tests
- **Details**:
  - [x] `_looksLikeBareEquationStart`: single ASCII/Greek variable + `=`, optional subscript. Prev-char guard prevents matching `e=` inside `mode=fast`.
  - [x] `_findBareEquationEnd`: brace+paren-depth aware scan, stops at CJK/uppercase-ASCII boundaries.
  - [x] `_isSafeBareEquation`: requires LaTeX command AND `^`/`{`; rejects CJK; delegates to `_isSafeLatexSegment`.
  - [x] Test assertion relaxed to accept trailing comma inside delimiter (`\(y=e^{...},\)`) — English comma is not matched by `_isNaturalLanguageBoundary`.
  - [x] 23/23 tests pass, `dart analyze` clean.
  - [x] No renderer / tokenizer / prompt / PDF renderer / pipeline changes.
- **Verification**: `flutter test test/latex_import_repair_test.dart` 23/23 pass.

## [2026-06-08 08:10] - test(latex): Step 6-A — failure-capture for bare equation `y=e^{-\int...}`

- **Change type**: test
- **Affected modules**: latex, tests
- **Details**:
  - [x] 1 new failure-capture test: `y=e^{-\int\frac{1}{2\sqrt{x}}dx}` stays bare — repairer starts from `\int` and can't balance the `}` from outer `e^{...}`.
  - [x] 2 regression guards: `mode=fast` key=value text → no-op, `y=结果变量` Chinese text → no-op.
  - [x] 22/23 pass, 1 known failure.
  - [x] **No production code changed.** Step 6-B will implement the fix.
- **Verification**: `flutter test test/latex_import_repair_test.dart` 22/23 pass (1 expected failure).

## [2026-06-08 08:00] - fix(latex): handle bare {} math sets, Unicode contour integrals — 20/20 pass

- **Change type**: fix
- **Affected modules**: latex, tests
- **Details**:
  - [x] **Fix 1**: Bare `{}` Cartesian set blocks: `{(x,y) \| ... \sqrt{...}}` → wrapped with visible LaTeX braces `\(\{...\}\)`.
  - [x] **Fix 2**: Bare `{}` polar set with multiple `\frac`s: whole block wrapped.
  - [x] **Fix 3**: Unicode `∮`/`∫`/`∬`/`∭` normalised to `\oint`/`\int`/`\iint`/`\iiint` and wrapped.
  - [x] **Fix 4**: `_isConcreteUnicodeIntegralExpr` guards against bare-symbol explanatory text.
  - [x] `_isMathSetSegment` expanded to accept both `\{...\}` and `{...}` with inner math signal check + CJK rejection.
  - [x] `_findBareSetEnd` brace-depth-aware, `_escapeOuterBareSetBraces`, `_isEscapedAt` helpers added.
  - [x] 20/20 tests pass, `dart analyze` clean.
  - [x] No renderer / tokenizer / prompt / PDF renderer / pipeline changes.
- **Verification**: `flutter test test/latex_import_repair_test.dart` 20/20 pass.

## [2026-06-08 07:39] - test(latex): Step 5-A — 6 failure-capture tests for remaining bare-LaTeX gaps

- **Change type**: test
- **Affected modules**: latex, tests
- **Details**:
  - [x] 6 new failure-capture tests added to `test/latex_import_repair_test.dart`.
  - [x] 4 tests currently FAIL (expected):
    - Bare `{...}` Cartesian set block not wrapped
    - Bare `{...}` polar set block not wrapped
    - Bare `{...}` with multiple `\frac`s not whole-wrapped
    - Unicode contour-integral `∮` not recognized as math start
  - [x] 2 regression guards PASS:
    - Plain Chinese `{注意事项}` → correctly no-op
    - Plain `∮` explanatory text → correctly no-op
  - [x] 16/20 pass, 4 known failures.
  - [x] **No production code changed.** Step 5-B will implement the fixes.
- **Verification**: `flutter test test/latex_import_repair_test.dart` 16/20 pass (4 expected failures).

## [2026-06-08 00:00] - fix(latex): repair trailing backslash in wrapped formulas, math set block detection

- **Change type**: fix
- **Affected modules**: latex, tests
- **Details**:
  - [x] `_repairDelimitedSegment()`: strip odd trailing backslash from content inside already-wrapped `\(…\)` / `\[…\]` / `$…$` while keeping even slashes (matrix `\\`) intact.
  - [x] Escaped math set block `\{…\}` detection: when braces enclose `\sqrt`, `\frac`, `\le`, `\ge`, `(a,b)` pairs etc., wrap as block/inline math.
  - [x] `_isMathSetSegment()`: only triggers when explicit math signals present inside braces. Plain `\{注意事项\}` left untouched.
  - [x] 6 new tests (14/14 pass), `dart analyze` clean.
  - [x] No renderer / tokenizer / prompt / PDF renderer / pipeline changes.
- **Verification**: `flutter test test/latex_import_repair_test.dart` 14/14 pass.

## [2026-06-07 23:27] - feat(import): wire repairLatex flag to PDF vision path only

- **Change type**: feat
- **Affected modules**: ai, import, tests
- **Details**:
  - [x] `AiService.parseImagesWithVision` gains optional `repairLatex` param (default `false`).
  - [x] `AiVisionParseService.parseImages` calls `LatexImportRepairService.instance.repairAll()` only when `repairLatex=true` and questions are non-empty.
  - [x] `ImportPipelineService` PDF vision branch passes `repairLatex: format == ImportFormat.pdf`.
  - [x] Non-PDF images, text routes, `QuestionParsePipeline`, prompt, PDF renderer, tokenizer, renderer all unchanged.
  - [x] 3 routing tests + 9 existing LaTeX repair tests = 12/12 pass. `dart analyze` clean.
- **Verification**: `flutter test test/latex_import_repair_test.dart test/pdf_vision_latex_repair_routing_test.dart` 12/12 pass.

## [2026-06-07 23:00] - fix(latex): repairInline unclosed delimiter no longer breaks scan loop

- **Change type**: fix
- **Affected modules**: latex, tests
- **Details**:
  - [x] `repairInline`: changed `if (end == -1) { buffer.write(_stripUnclosedDelimiter()); break; }` to `{ i += _delimiterOpenLength(); continue; }` — an unclosed `\(` / `\[` / `$` now only skips the broken opening delimiter and continues scanning for bare LaTeX.
  - [x] Added `_delimiterOpenLength()` helper.
  - [x] Removed now-dead `_stripUnclosedDelimiter()`.
  - [x] 4 new tests: unclosed `\(` with later `\iint`, unclosed `\[` with later `\sqrt`, unclosed `$` with later `\sin`, already-wrapped regression.
  - [x] 9/9 tests pass, `dart analyze` clean.
  - [x] No renderer, tokenizer, prompt, PDF renderer, or pipeline changes.
- **Verification**: `flutter test test/latex_import_repair_test.dart` 9/9 pass.

## [2026-06-07 22:27] - refactor(import): DocxTextFirstParseService 5-step pipeline integration & P0/P1 defensive hardening

- **Change type**: feat, fix
- **Affected modules**: import, import_review, ui, tests
- **Details**:
  - **Pipeline Integration**: Wired `AnswerBlockMatcher → TextQuestionRegionizer → LocalQuestionAssembler → SingleQuestionRepairService → ImportQualityGate` with const constructor + full DI. Replaced `blockReason` with `warnings`, added `_isBlockedByQualityGate` UI guard.
  - **Patch 1**: `import_pipeline_service.dart` — Propagate DOCX `warnings`, safe `blockReason` fallback.
  - **Patch 2**: `text_question_regionizer.dart` — Split single regex into three: `_explicitQuestionRegex`, `_parenQuestionRegex`, `_bareLineQuestionRegex`; removed Chinese number map (`一、`→`1、`); added `_looksLikeSectionHeading()` filter.
  - **Patch 3**: `text_question_regionizer.dart` — `diagnostics['acceptedMaxQuestionNumber']` + `maxQuestionNumberDetected = max(explicitCandidateMax, acceptedMax)`.
  - **Patch 4**: `answer_block_matcher.dart` — Removed `|.+` catch-all from `_answerLine`; split into `_choiceAnswerLine` + `_subjectiveAnswerLine` with `_isSafeSubjectiveAnswer()` guard.
  - **Patch 5**: `local_question_assembler.dart` — Inherit `region.diagnostics`, merge `region.health` into `repairRecommended`.
  - **Patch 6**: `docx_document_adapter.dart` — Add `m:oMathPara` capture, fix fallback whitespace preservation.
  - **Patch B**: `_extractInlineExplanation` requires `(^|\\n|。|；|;)` boundary prefix.
  - **Patch C**: Subjective answer ≤80 chars, reject explanation keywords.
  - **Patch D**: `_validateBeforeSave()` + `_confirmAndSave()` double-check `_isBlockedByQualityGate`.
  - **UI**: `_isBlockedByQualityGate` reads only top-level `qualityGate` Map, no recursive scan.
  - **Tests**: 36 boundary/unit tests (19 in `boundary_defense_test.dart`, 8 in `docx_text_first_parse_test.dart`, 4 in `docx_strict_route_test.dart`, 5 in other suites). Covers section headings, inline answers, explanation boundaries, subjective answers, formula extraction, pipeline warnings, save defense, bareLine guard, regionizer candidate filtering, answer block matcher, assembler-regionizer chain.
- **Verification**: `dart analyze` clean (0 issues), `flutter test` 36/36 pass.

## [2026-06-07 16:28] - feat(import): Phase 5-A7 Extract math formulas and prevent wrong prefix match in DOCX adapter
- **Change type**: feat
- **Affected modules**: import, docx_adapter
- **Details**:
  - [x] Reworked `_extractTextFromXml` in `lib/services/import_pipeline/adapters/docx_document_adapter.dart` to support extracting math formula text from `<m:oMath>` tags.
  - [x] Added rigorous boundary character checking (`>` and space) when matching `<w:t>` and `<m:oMath>` tags to prevent matching table (`<w:tbl>`), cell (`<w:tc>`), or row (`<w:tr>`) elements.
  - [x] Implemented regex-optimized `_extractAllTextNodes` utilizing backreferences and non-backtracking text matches (`[^<]*`) to speed up text extraction from formula children.
  - [x] Added unit tests asserting correct formula extraction and prefix matching boundary defense in `test/docx_document_adapter_test.dart`.
- **Verification**:
  - `flutter test` executed and all 260 unit tests passed successfully.

## [2026-06-07 16:25] - feat(import): Phase 5-A6 Export DOCX rawText preview for observability and diagnostics
- **Change type**: feat
- **Affected modules**: import, diagnostics, UI
- **Details**:
  - [x] Modified `DocxTextFirstParseResult` in `lib/services/import_pipeline/docx_text_first_parse_service.dart` to support passing `diagnostics` back to the pipeline.
  - [x] Added raw text diagnostics generation (`rawTextPreview` up to 5000 chars, `rawTextLength`, and `rawTextLineCount`) in `DocxTextFirstParseService.parseDocxText`.
  - [x] Modified `ImportPipelineService.parseFiles` to merge docx parse diagnostics into the pipeline's global diagnostics map.
  - [x] Added `package:flutter/services.dart` import and integrated `_buildRawTextPreviewCard` into `_showDiagnosticsSheet` drawer in `lib/ui/pages/import_staging_screen.dart`.
  - [x] Handled selectable preview text and clipboard copy functionality so users can copy the raw text easily.
- **Verification**:
  - `flutter test` executed and all 259 unit tests passed successfully.

## [2026-06-06 21:35] - feat(import): Phase 5-A5 Import Review Final Closure & Governance Report
- **Change type**: feat
- **Affected modules**: import, review, UI, reports
- **Details**:
  - [x] Created `ImportReviewReport` and `ImportReviewReportItem` data models to represent quality metrics and high-risk items.
  - [x] Implemented `ImportReviewReportBuilder` to compute quality scores, count issues by code and severity, tally metadata sources/risk-hints, and extract high-risk items sorted descending by severity.
  - [x] Implemented `ImportReviewReportFormatter` to convert quality reports into localized Chinese strings for dialog confirmations and success logs.
  - [x] Modified `ImportStagingScreen` to block saves when no items remain, present A5 quality report confirmation dialogs for low quality scores (<60), severe errors, warnings/infos, and clean imports.
  - [x] Modified save-success callback to present a comprehensive, copyable/selectable "本次导入报告" (Import Report) before popping screen.
  - [x] Written unit tests in `test/import_review_report_builder_test.dart`, `test/import_review_report_formatter_test.dart` and widget tests in `test/import_staging_final_review_widget_test.dart`.
- **Verification**:
  - `dart analyze`: Passed with 0 issues.
  - `flutter test`: All 235 tests passed successfully.

## [2026-06-06 21:15] - feat(import): Phase A4 Import Review Batch Operations
- **Change type**: feat
- **Affected modules**: import, review, UI
- **Details**:
  - [x] Implemented `ImportReviewBatchController` containing pure Dart logic for multi-select batch deletion and batch type transformation.
  - [x] Added `copyWith` to `QuestionDraft` and `ImportReviewItem` to facilitate immutable subset updates.
  - [x] Implemented `_selectionMode` in `ImportStagingScreen` with corresponding UI components (Checkbox, Action AppBar, Contextual BottomBar).
  - [x] Handled state reset when sorting/filtering changes, preventing hidden item selection.
  - [x] Written `test/import_review_batch_controller_test.dart` and `test/import_staging_batch_actions_widget_test.dart` asserting correct batch mapping and lifecycle boundaries.
- **Verification**:
  - `dart analyze`: Passed with 0 issues.
  - `flutter test`: Controller and Widget tests pass perfectly, gracefully handling out-of-bounds screen sizes and ensuring selection resets natively.

## [2026-06-06 21:00] - fix(environment): Windows sqlite3.dll download timeout in flutter test
- **Change type**: build
- **Affected modules**: testing, sqlite3
- **Details**:
  - [x] Added `sqlite3` hooks configuration to `pubspec.yaml` using system `winsqlite3` to prevent `SocketException` on Windows during `sqlite3.dll` GitHub download timeout.
  - [x] Resolves test suite blocking during large-scale automated regressions.
- **Verification**:
  - Full `flutter test` suite now boots locally without network blocks.

## [2026-06-06 20:50] - feat(import): Phase A3 Import Review Filters & Sorting
- **Change type**: feat
- **Affected modules**: import, review, UI
- **Details**:
  - [x] Added `ImportReviewFilter` and `ImportReviewSort` enums, isolating pure view-filtering logic into `ImportReviewFilterService`.
  - [x] Refactored `ImportStagingScreen` state: maintained `_allItems` as source of truth and computed `_visibleItems`.
  - [x] Replaced list deletion logic to rely on `ImportReviewItem.originalIndex` instead of dynamic visible indices.
  - [x] Added empty-state fallback UI ("当前筛选下没有题目" vs "所有题目已被删除").
  - [x] Extensive tests written for `ImportReviewFilterService` and `ImportStagingScreen`.
- **Verification**:
  - `flutter test` passed for all newly added logic.

## [2026-06-06 20:30] - feat(import): Phase A2 Unified Object & Analyzer
- **Change type**: feat
- **Affected modules**: import, review
- **Details**:
  - [x] Added `ImportReviewMetadata` block tracking fragment types, origin indices, and risks hints.
  - [x] Added `ImportReviewItem` container consolidating draft + metadata + `originalIndex`.
  - [x] Added `ImportReviewAnalyzer` assessing issues and risk hints, computing `ImportReviewResult`.
  - [x] Added `ImportReviewBadgeFormatter` returning UI-friendly labels with explicit `BadgeType`s.
  - [x] Full coverage written for structural validation, analyzer outputs, and formatting.
- **Verification**:
  - `flutter test test/import_review_analyzer_test.dart test/import_review_badge_formatter_test.dart test/import_review_metadata_test.dart` passed successfully.

## [2026-06-05 18:30] - refactor(ai): 鎶藉彇 AiTextParseService锛屾敹缂?AiService 涓洪棬闈?
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: services, ai, import
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板 `lib/services/ai_text_parse_service.dart`锛岄泦涓壙杞芥枃妗ｇ粨鏋勮矾鐢便€乸ending chunks 璁板綍銆佸井鎵规骞跺彂瑙ｆ瀽銆佸け璐ラ噸璇曞洖璋冦€佺瓟妗堥〉鎷煎浘褰掑苟鍜岃В鏋愬け璐ュ厹搴曘€?  - [x] 灏?`AiService.parseTextToQuestions` 涓?`parseMicroBatches` 鏀剁缉涓哄吋瀹归棬闈紝鏂偣鎭㈠銆佸鍏ラ〉鍜屾祴璇曡皟鐢ㄥ叆鍙ｄ繚鎸佷笉鍙樸€?  - [x] 灏?`_parseSingleChunkToQuestions` 浠?`AiService` 鍐呯Щ鍑猴紝鏂囨湰瑙ｆ瀽 LLM 璋冪敤鐜板湪鐢?`AiTextParseService` 绠＄悊銆?  - [x] `AiService` 涓嶅啀鐩存帴渚濊禆 `DocumentParseRouter`銆乣ParseBatchRunner`銆乣QuestionParsePipeline`銆乣TaskManager` 鎴栨枃鏈В鏋?JSON 娓呮礂缁嗚妭锛屾枃浠惰妯℃敹缂╁埌 129 琛屻€?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format lib/services/ai_service.dart lib/services/ai_text_parse_service.dart`銆乣dart analyze lib/services/ai_service.dart lib/services/ai_text_parse_service.dart`銆乣dart analyze lib/services`銆乣flutter test test/document_parse_router_test.dart test/parse_batch_runner_test.dart test/question_parse_pipeline_test.dart`銆乣flutter test test/architecture_boundary_test.dart`銆乣git diff --check`銆傞櫎 Windows 琛屽熬鎻愮ず澶栧潎閫氳繃锛屽畬鏁村洖褰掔户缁氦鐢?Gemini/鍙嶉噸鍔涙墽琛屻€?

## [2026-06-05 18:59] - refactor(ai): 鎶界鐩存帴 LLM 璋冪敤鍏煎缃戝叧锛孉iService 瀹屾垚钖勯棬闈㈠寲
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: services, ai
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板 `lib/services/ai_direct_call_service.dart`锛屾壙杞芥棫鍏煎鍏ュ彛 `callLlmApi` 鐨勬枃鏈ā鍨嬬洿杩炰笌鍥剧墖杈撳叆 JSON 鍖呰閫昏緫銆?  - [x] 灏?`AiService.callLlmApi` 鏀剁缉涓哄崟琛屽鎵橈紝淇濈暀鏃?API 绛惧悕涓嶅彉銆?  - [x] `AiService` 涓嶅啀鐩存帴渚濊禆 `dart:convert`銆乣AiEngineRepository` 鎴?`LlmApiClient`锛屾墍鏈?AI 鍏蜂綋鑳藉姏閮借浆浜ょ粰涓撻棬鏈嶅姟銆?  - [x] `AiService` 鏂囦欢瑙勬ā杩涗竴姝ユ敹缂╁埌 119 琛岋紝瀹氫綅瀹屾垚杞彉涓虹ǔ瀹?API 鍏煎闂ㄩ潰銆?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format lib/services/ai_service.dart lib/services/ai_direct_call_service.dart`銆乣dart analyze lib/services/ai_service.dart lib/services/ai_direct_call_service.dart`銆乣dart analyze lib/services`銆乣flutter test test/architecture_boundary_test.dart`銆乣git diff --check`銆傞櫎 Windows 琛屽熬鎻愮ず澶栧潎閫氳繃锛屽畬鏁村洖褰掔户缁氦鐢?Gemini/鍙嶉噸鍔涙墽琛屻€?

## [2026-06-05 19:05] - refactor(architecture): 鏋舵瀯瀹¤閫氳繃骞舵暣鐞嗘湇鍔″垎灞傛彁浜?- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: architecture, ai, review, test
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 瀹屾垚 `AiService` 闂ㄩ潰鍖栧璁壜?
  - [x] 瀹¤ `lib/ui` 涓?`lib/services`銆?
  - [x] 鏁寸悊鏈疆鏂板鏈嶅姟銆丷epository銆?
  - [x] 澶嶆牳 Gemini/鍙嶉噸鍔涘叏閲忓洖褰掔粨鏋滐紟
- **楠岃瘉鐘舵€?*: 宸插畬鎴愭灦鏋勮竟鐣屾悳绱€佸彉鏇磋寖鍥村璁′笌鎻愪氦鍓?diff 妫€鏌ワ紝鍑嗗鎵ц鍘熷瓙鍖栨彁浜や笌杩滅▼鍚屾銆?
## [2026-06-05 21:45] - fix(render): recover from unclosed LaTeX delimiters in imported drafts
- **Change type**: fix
- **Affected modules**: latex, renderer, import
- **Details**:
  - [x] Tightened `LatexImportRepairService` so unclosed `\(`/`\[`/`$` delimiters are stripped back to plain text instead of being preserved as broken math blocks.
  - [x] Kept complex formulas on the block-math path and retained the safe environment/braces checks from the previous pass.
  - [x] Downgraded renderer `ParseErrorToken` output from an orange error box to plain text fallback, with a debug-only tooltip for local diagnostics.
  - [x] Added regression tests covering unclosed delimiter repair and renderer fallback for residual broken math.
- **Verification**:
  - `dart format` and `dart analyze` passed.
  - `flutter test` passed 21 tests.

## [2026-06-05 21:10] - fix(render): stabilize imported LaTeX matrix rendering
- **Change type**: fix
- **Affected modules**: import, latex, renderer, tests
- **Details**:
  - [x] Added `lib/utils/latex_complexity_classifier.dart` as a shared contract for deciding whether a formula should render inline or as a block.
  - [x] Reworked `lib/services/latex_import_repair.dart` so short bare formulas are wrapped with `\(...\)`, while matrices, cases, long expressions, and large-operator formulas are wrapped with `\[...\]`.
  - [x] Added defensive balance checks for braces and LaTeX environments; unsafe unbalanced import fragments are preserved instead of generating broken delimiters.
  - [x] Updated `StructuredContentRenderer` to promote complex inline math tokens to block math before they enter `RichText`/`WidgetSpan`, avoiding baseline constraint failures and tiny scaled formulas.
  - [x] Added tests.
- **Verification**:
  - `dart format` and `dart analyze` passed.
  - `flutter test` passed 19 tests.

## [2026-06-06 15:30] - feat(import): Phase 4-H User Acceptance & Observability
- **Change type**: feat
- **Affected modules**: import, diagnostics, database, UI
- **Details**:
  - [x] Created `ImportDiagnosticMessage` and `ImportDiagnosticFormatter` with 100% test coverage to format pipeline warnings and diagnostics.
  - [x] Upgraded SQLite DB to version 14 and added `warnings` and `diagnostics` columns to `import_tasks` table.
  - [x] Integrated warnings and diagnostics persistence into `ImportTask` and `TaskManager`.
  - [x] Refactored `TaskCenterScreen` to display chunk-level progress (pending/failed counts) and warnings chip, and added a detailed diagnostic bottom sheet.
  - [x] Refactored `ImportStagingScreen` to accept warnings/diagnostics, render color-coded severity banners, show detailed diagnostics modal, and support backwards compatibility.
- **Verification**:
  - `dart analyze` passed with 0 issues.
  - `flutter test` passed all 175 tests.
