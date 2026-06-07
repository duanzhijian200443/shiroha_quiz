# Development Log

## [2026-06-07 22:35] - fix(import): Patches A-D — section heading filter, subjective answer safety, defense-in-depth

- **Change type**: fix
- **Affected modules**: import, ui
- **Details**:
  - [x] **Patch A**: `text_question_regionizer.dart` — Add `_looksLikeSectionHeading()` to reject Chinese section titles (一、选择题 / 二、填空题 etc.) before they become question candidates.
  - [x] **Patch B**: `local_question_assembler.dart` — `_extractInlineExplanation()` now requires `(^|\\n|。|；|;|\\.\\s+)` boundary prefix before markers.
  - [x] **Patch C**: `answer_block_matcher.dart` — Add `_isSafeSubjectiveAnswer()` guard: reject answers >80 chars or containing explanation keywords (本题/因为/所以/解析/分析/考查).
  - [x] **Patch D**: `import_staging_screen.dart` — `_validateBeforeSave()` and `_confirmAndSave()` both independently check `_isBlockedByQualityGate`.
  - [x] 19/19 boundary defense tests pass.
- **Verification**: `dart analyze` clean (0 issues), `flutter test` 19/19 pass.

## [2026-06-07 22:00] - fix(import): P0/P1 defensive hardening — regex narrowing, diagnostic chaining, defense-in-depth

- **Change type**: fix
- **Affected modules**: import, ui, tests
- **Details**:
  - [x] **Patch 1**: `import_pipeline_service.dart` — `allWarnings.addAll(docxParseRes.warnings)`, `_readBlockReason()` falls back to `severity` if `reason` absent.
  - [x] **Patch 2**: `text_question_regionizer.dart` — Split single `_questionCandidateRegex` into three: `_explicitQuestionRegex` (suffix-anchored), `_parenQuestionRegex` (parenthesized), `_bareLineQuestionRegex` (line-start + body-guarded `(?=[^\\d\\s])`). Ban plain inline digits as question markers.
  - [x] **Patch 3**: `text_question_regionizer.dart` — `diagnostics['acceptedMaxQuestionNumber']` + `diagnostics['maxQuestionNumberDetected'] = max(explicitCandidateMax, acceptedMax)`.
  - [x] **Patch 4**: `answer_block_matcher.dart` — Remove `|.+` catch-all from `_answerLine`; only extract verifiable answer values.
  - [x] **Patch 5**: `local_question_assembler.dart` — Initialize diagnostics from `region.diagnostics`; `repairRecommended = region.health == repairable || _shouldRecommendRepair()`.
  - [x] **Patch 6**: `docx_document_adapter.dart` — Add `m:oMathPara` capture group; fix fallback whitespace to preserve newlines.
  - [x] **P0**: Remove Chinese number map (`_normalize` "一、"→"1、") — section headers are NOT question numbers.
  - [x] **P0**: `_bareLineQuestionRegex` now requires math stem word (设/已知/若/求/…) after number.
  - [x] **P1**: Dual-pass answer extraction: `_choiceAnswerLine` (A-D/√×/对/错) + `_subjectiveAnswerLine` (short text ≤80 chars).
  - [x] **P1**: `_extractInlineExplanation` now requires `(^|\\n|。|；|;|\\.\\s+)` boundary prefix before markers.
  - [x] **P1**: `missing_explanation` → `info_missing_explanation` — answer is core field, explanation is informational.
  - [x] **P1**: Defense-in-depth: `_validateBeforeSave()` and `_confirmAndSave()` now independently check `_isBlockedByQualityGate`.
  - [x] 19/19 boundary defense tests pass (added 6 new: #13-#18).
- **Verification**: `dart analyze` clean (0 issues), `flutter test` 19/19 pass.

## [2026-06-07 17:15] - feat(import): integrate 5-step DocxTextFirstParseService pipeline with boundary defense tests
- **Change type**: feat
- **Affected modules**: import, import_review, UI, tests
- **Details**:
  - [x] Integrated 5-step pipeline in `DocxTextFirstParseService`: AnswerBlockMatcher → TextQuestionRegionizer → LocalQuestionAssembler → SingleQuestionRepairService → ImportQualityGate, with const constructor and full DI.
  - [x] Replaced `DocxTextFirstParseResult.blockReason` with `warnings`; adapt all callers and test suites.
  - [x] Added `_isBlockedByQualityGate` (read-only top-level `qualityGate` map access) and `_confirmButtonText` to `import_staging_screen.dart` — no recursive scan.
  - [x] Added Phase 4 boundary test (inline answer/explanation extraction from compact text) and Phase 6 test (critical_under_parse with regionCount=7/maxDetected=21/actual=7).
  - [x] New `import_pipeline/` adapters: docx, markdown, txt, zip document adapters; fusion coordinators; vision batch parsing; LaTeX repair; document signal detection.
  - [x] New `import_review/` module: analyzer, batch controller, filter, metadata, report builder, report formatter, summary.
  - [x] Updated `import_staging_screen` with A5 quality report dialog, batch selection operations, rawText preview card, diagnostics drawer.
  - [x] Various companion fixes: task manager diagnostics, AI prompts, sanitizer, database helper, question draft copyWith.
- **Verification**: 13/13 boundary defense tests pass, dart analyze clean (0 issues).

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
