# 🚀 自动化 Git 提交与开发日志引擎 (Git & Changelog Engine)

## [2026-06-05 20:31] - refactor(ui): PlanConfigScreen 接入强类型学习计划目录
- **变更类型**: refactor
- **影响模块**: ui, models, core, tests
- **详细改动明细**:
  - [x] 新增 `StudyPlanBankCatalog` / `StudyPlanBank` / `StudyPlanFolderGroup` 领域模型。
  - [x] `ReviewEngineService` 新增强类型目录接口，并保留旧 Map 接口兼容。
  - [x] `PlanConfigScreen` 删除弱类型 Map 分组和 `bank['xxx']` 读取。
- **验证状态**:
  - `dart format lib\data\models\study_plan_bank_catalog.dart lib\core\review_engine_service.dart lib\ui\pages\plan_config_screen.dart test\study_plan_bank_catalog_test.dart`：已完成
  - `dart analyze lib test`：成功 (0 Error, 0 Warning)
  - `flutter test test\study_plan_bank_catalog_test.dart test\architecture_boundary_test.dart`：全部通过
  - `flutter test`：全部通过
  - `git diff --check`：通过

## [2026-06-05 20:21] - refactor(ui): DataCenterScreen 接入 SubjectTreeIndex 强类型题库树
- **变更类型**: refactor
- **影响模块**: ui, models, tests
- **详细改动明细**:
  - [x] 移除 `DataCenterScreen` 的弱类型 `Map<String, List<Map<String, dynamic>>>` 题库树状态。
  - [x] 页面改为调用 `QuestionRepository.instance.getSubjectTreeIndex()`。
  - [x] 搜索、移动文件夹、渲染逻辑全部改为使用 `SubjectFolderNode` / `QuestionBankNode` 强类型模型。
  - [x] 在 `SubjectFolderNode` 模型中新增并覆盖测试了 `copyWithBanks` 方法以支持不变性过滤。
- **验证状态**:
  - `dart format lib\data\models\subject_tree_index.dart lib\ui\pages\data_center_screen.dart test\subject_tree_index_test.dart`：已完成
  - `dart analyze lib test`：成功 (0 Error, 0 Warning, 84 Info)
  - `flutter test test\subject_tree_index_test.dart test\architecture_boundary_test.dart`：全部通过
  - `flutter test`：全部通过
  - `git diff --check`：通过 (仅有 Windows LF/CRLF 提示)

## [2026-06-05 20:02] - refactor(data): 引入 SubjectTreeIndex 统一题库树索引
- **变更类型**: refactor
- **影响模块**: data, services, ui, tests
- **详细改动明细**:
  - [x] 新增 `lib/data/models/subject_tree_index.dart` 领域模型，提供结构化题库树索引与去重逻辑。
  - [x] 修改 `QuestionRepository`，移除内部私有 `_BankFolderIndex`，统一使用 `SubjectTreeIndex` 提供树形结构状态。
  - [x] 修改 `DataCenterScreen` 弱类型字段读取，兼容 `name` 和 `bank_name`。
  - [x] 新增 `test/subject_tree_index_test.dart` 补齐索引覆盖与防卫边界验证。
- **验证状态**:
  - `dart format lib\data\models\subject_tree_index.dart lib\data\repositories\question_repository.dart lib\ui\pages\data_center_screen.dart test\subject_tree_index_test.dart`：已完成
  - `dart analyze lib test`：成功 (0 Error, 0 Warning, 84 Info)
  - `flutter test test\subject_tree_index_test.dart`：全部通过 (7 tests passed)
  - `flutter test test\architecture_boundary_test.dart`：全部通过 (1 test passed)
  - `flutter test`：全部通过 (45 tests passed)
  - `git diff --check`：通过 (仅有 Windows LF/CRLF 提示)

## [2026-06-05 19:48] - refactor(import): 引入 QuestionIdentity 统一题目身份判断
- **变更类型**: refactor
- **影响模块**: import, services, data, tests
- **详细改动明细**:
  - [x] 新增 `lib/data/models/question_identity.dart`，集中管理题号、题干与题型的身份归一化逻辑。
  - [x] 修改 `QuestionParsePipeline`，将题号归一化逻辑委托给 `QuestionIdentity`，保留旧方法兼容现有调用。
  - [x] 修改 `TaskManager._deduplicateQuestions`，用 `Set<QuestionIdentity>` 替代字符串拼接 key。
  - [x] 新增 `test/question_identity_test.dart`，覆盖题号归一化、Map 弱类型输入和题型区分。
- **验证状态**:
  - `dart format lib\data\models\question_identity.dart lib\services\question_parse_pipeline.dart lib\services\task_manager.dart test\question_identity_test.dart`：已完成
  - `dart analyze lib\data lib\services test`：成功 (No issues found)
  - `flutter test test\question_identity_test.dart test\question_parse_pipeline_test.dart test\parse_batch_runner_test.dart`：全部通过 (8 tests passed)
  - `flutter test`：全部通过 (38 tests passed)
  - `git diff --check`：通过 (仅有 Windows LF/CRLF 提示)

## [2026-06-05 19:29] - refactor(ai): 引入 QuestionParseMode 强类型解析模式
- **变更类型**: refactor
- **影响模块**: ai, services, tests
- **详细改动明细**:
  - [x] 新增 `QuestionParseMode` enum，替代文本解析链路中的 `all/stem_only/answer_only` 字符串模式。
  - [x] 修改 `DocumentParseRouter` 与 `AiTextParseService`，内部统一使用强类型解析模式。
  - [x] 修改 `AiPrompts.parseChunk`，通过 enum switch 生成不同解析模式的 prompt 指令。
  - [x] 保留 `AiService.parseMicroBatches` 的旧字符串签名，通过 `QuestionParseMode.fromLegacyValue` 做兼容转换。
  - [x] 补充解析模式兼容测试与路由断言更新。
- **验证状态**:
  - `dart analyze lib test`：成功 (0 Error, 0 Warning, 84 Info)
  - `flutter test`：全部通过 (34 tests)
  - `git diff --check`：通过 (仅有 Windows LF/CRLF 提示)
  - targeted test：已执行 `test/question_parse_mode_test.dart` 和 `test/document_parse_router_test.dart`

## [2026-06-04 22:30] - refactor(architecture): 鏋舵瀯鍐荤粨涓庡熬宸存竻鐞嗭紝鎶藉彇 LatexMigrationRepository 骞剁‘绔嬭鑼?(Phase 5.1)
- **鍙樻洿绫诲瀷**: refactor, docs
- **褰卞搷妯″潡**: data, services, docs
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 娓呴櫎浜嗛」鐩噷鏈€鍚庝竴涓竟缂樿剼鏈?`latex_migration_service.dart` 瀵?Database 鐨勭洿杩烇紝鎶藉彇鑷?`LatexMigrationRepository`銆?  - [x] 鎾板啓浜嗛」鐩浠藉畼鏂规灦鏋勬枃妗?`ARCHITECTURE.md`锛屼粠鍒跺害涓婃槑鏂囪瀹?UI灞?/ Service灞?绂佹鐩存帴寮曠敤 `sqflite` 鍜?`DatabaseHelper`銆?- **楠岃瘉鐘舵€?*: `dart analyze` 鍏ㄧ豢锛屾墍鏈夐泦鎴愭祴璇曠ǔ瀹氶€氳繃銆傝繖鏍囧織鐫€鍘嗘椂浜旇疆鐨勫ぇ鍨嬫灦鏋勯噸鏋勫交搴曞喕缁撻獙鏀躲€?## [2026-06-04 22:20] - refactor(service): 闅旂鏍稿績鏈嶅姟灞傜殑鏁版嵁搴撶洿鎺ユ搷浣滐紝杈炬垚瀹屽叏浣撴灦鏋?(Phase 5)
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: core, data, services
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 閲嶆瀯浜?FSRS 鏍稿績绠楁硶鏈嶅姟 `review_engine_service.dart`锛屾娊鍙栨墍鏈?SQLite 鐩磋繛閫昏緫鑷虫柊寤虹殑 `ReviewRepository`锛岃寮曟搸鍙樻垚绾补鐨勬暟瀛﹁绠椾笌璋冨害缂栨帓鍣ㄣ€?  - [x] 閲嶆瀯浜嗕换鍔＄鐞嗗櫒 `task_manager.dart`锛屾彁鍙栫姸鎬佹寔涔呭寲閫昏緫鑷虫柊寤虹殑 `ImportTaskRepository`銆?  - [x] 淇壀浜?`ai_service.dart` 閲岀殑瓒婃潈琛屼负锛屽皢璇诲彇閿欓杞彂鑷?`QuestionRepository`銆?- **楠岃瘉鐘舵€?*: 缁?`dart format` 涓?`dart analyze` 楠岃瘉閫氳繃锛屼慨澶嶄簡鍑犲灞€閮?API 鏇村悕甯︽潵鐨勮仈鍔ㄩ敊璇€傝嚜鍔ㄥ寲鍗曞厓娴嬭瘯 `flutter test` 鍦ㄦ渶楂樺嵄鐨勪簨鍔″墺绂绘搷浣滀笅渚濇棫淇濇寔 100% 缁跨伅銆傞」鐩灦鏋勫交搴曞疄鐜颁簡 UI -> Service -> Repository -> Database 鐨勮В鑰︺€?## [2026-06-04 22:05] - refactor(exam): 灏嗘ā鑰冮摼璺殑 UI 灞傜洿杩炲叏闈㈣縼绉昏嚦 ExamRepository
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: data, ui
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板缓 `ExamRepository` 浠ｇ悊鎵€鏈夎瘯鍗风浉鍏崇殑搴曞眰鏂规硶 (濡?`getAllExamPapers`, `generateMockExamPaper`, `submitExamPaper` 绛?銆?  - [x] 灏嗗師鏈斁缃湪 `QuestionRepository` 涓殑瓒婄晫鏂规硶 (`createExamPaper`, `createExamPaperFromDrafts`) 骞崇Щ鍒?`ExamRepository` 涓紝缁存寔鑱岃矗鍗曚竴銆?  - [x] 閲嶆瀯娲楀埛浜?`mock_center_screen`, `mock_exam_config_screen`, `mock_exam_screen`, `paper_review_screen`銆?  - [x] 淇浜?`ai_generator_screen` 鐢熸垚璇曞嵎鏃剁殑 Repository 璋冪敤銆?- **楠岃瘉鐘舵€?*: 缁?`dart format` 涓?`dart analyze` 楠岃瘉閫氳繃锛屼慨澶嶄簡鐢变簬寮虹被鍨嬩笉鍖归厤寮曞彂鐨勫嚱鏁板弬鏁板啿绐侊紝`flutter test` 缁х画 100% 閫氳繃銆傝嚦姝?UI 灞傜殑 `DatabaseHelper` 褰诲簳娓呴浂銆?## [2026-06-04 21:55] - refactor(questions): 灏嗛搴撲笌棰樼洰绠＄悊鐨?UI 灞傜洿杩炶縼绉昏嚦 QuestionRepository
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: data, ui
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鎵╁睍 `QuestionRepository`锛屼唬鐞嗗寘鎷?`getSubjectTree`銆乣updateQuestion`銆乣insertPomodoroSession`銆乣getHeatmapData` 鍦ㄥ唴鐨勮繎 15 涓簳灞傛柟娉曘€?  - [x] 灏佽 `savePreviewQuestion` 浜嬪姟锛屽交搴曟秷鐏簡 `practice_page` 閲岀殑 `db.insert` 绛夌‖缂栫爜銆?  - [x] 鍦?`deleteQuestionBank` 涓疄鐜拌仈鍔紝涓€鏃﹀垹闄ょ殑棰樺簱鏄綋鍓嶈閫変腑鐨勯搴擄紝鑷姩鍒锋柊 `SettingsRepository` 缂撳瓨涓洪粯璁ゆ€併€?  - [x] 鍑€鍖栦簡 `data_center_screen`, `import_screen`, `question_list_screen`, `question_edit_screen`, `practice_page` 鐨?`DatabaseHelper` 渚濊禆銆?  - [x] 椤哄甫娓呴櫎浜?`home_page`, `plan_config_screen`, `profile_screen` 鐨勯浂鏄熼仐鐣欒皟鐢ㄣ€?- **楠岃瘉鐘舵€?*: 缁忔湰鍦颁唬鐮佹牸寮忓寲銆侀潤鎬佸垎鏋愪笌鍏ㄩ噺 `flutter test` 楠岃瘉锛?8 涓祴璇曞畬缇庡洖褰掋€俇I 灞傚浜庨搴撴ā鍧楃殑鏁版嵁闅旂鐩爣鍏ㄩ潰杈炬垚銆?## [2026-06-04 21:35] - refactor(settings): 寮曞叆 SettingsRepository 涓庡唴瀛樼骇缂撳瓨锛岄殧绂?UI 灞傞厤缃鍐?- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: data, ui
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板 `lib/data/repositories/settings_repository.dart`锛屼綔涓洪厤缃」绠＄悊鐨勫己绫诲瀷鍏ュ彛銆?  - [x] 鍦?`SettingsRepository` 鍐呴儴瀹炵幇浜嗛拡瀵归珮棰戣鍙栬缃殑**楂樼骇鍐呭瓨缂撳瓨鏁版嵁缁撴瀯** (`Map<String, String> _cache`)锛屾湁鏁堝噺灏?SQLite 鐨勫紓姝?I/O 鏌ヨ銆?  - [x] 灏嗗急绫诲瀷鐨?`DatabaseHelper.instance.getSetting / saveSetting` 鏇挎崲涓哄己绫诲瀷鐨勪笓灞炴柟娉曪紝濡?`getAppTheme()`銆乣getCurrentBank()`銆乣getDailyQuota(bankName)`銆?  - [x] 閲嶆瀯浜?`lib/main.dart` 涓殑搴旂敤鍚姩涓婚鍒濆鍖栥€?  - [x] 閲嶆瀯浜?`lib/ui/pages/ai_settings_screen.dart` 涓?`lib/ui/pages/profile_screen.dart` 鐨勪富棰樺亸濂借缃€?  - [x] 閲嶆瀯浜?`lib/ui/pages/plan_config_screen.dart` 鐨勬瘡鏃ヤ换鍔￠厤棰濊鍐欎笌棰樺簱鍒囨崲钀界洏閫昏緫锛屽苟瑙ｈ€︿簡鎭跺績鐨勫瓧绗︿覆鎷兼帴锛堝 `${bankName}_daily_quota`锛夈€?  - [x] 閲嶆瀯浜?`lib/ui/pages/home_page.dart` 鍜?`lib/ui/pages/mock_center_screen.dart` 椤甸潰椤堕儴鐨勫綋鍓嶉搴撶紦瀛樿鍙栭€昏緫銆?- **楠岃瘉鐘舵€?*: 缁忔湰鍦颁唬鐮佹牸寮忓寲銆侀潤鎬佸垎鏋愪笌鍏ㄩ噺 `flutter test` 鍥炲綊楠岃瘉锛屽叏閮ㄦ祴璇曢€氳繃銆傞伒寰灦鏋勭邯寰嬶紝鏈閲嶆瀯鑼冨洿涓ユ帶鍦?UI 灞傘€?## [2026-06-04 21:18] - refactor(ai_ui): UI 灞?AI 寮曟搸閰嶇疆鍏ュ彛杩佺Щ鑷?Repository
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: ui, data, ai
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鎵╁睍 `lib/data/repositories/ai_engine_repository.dart`锛屽鍔?`saveEngine`銆乣setActiveEngine`銆乣deleteEngine` 涓?`renameEngine` 鏂规硶锛屽畬鍠勫畬鏁?CRUD 閾捐矾銆?  - [x] 閲嶆瀯 `lib/ui/pages/ai_engine_management_screen.dart`锛岀Щ闄?`DatabaseHelper` 鐩存帴璋冪敤锛屽叏闈㈡嫢鎶?`AiEngineRepository` 鍜屽己绫诲瀷 `AiEngineProfile`锛屼繚鎸?UI 浜や簰/娓叉煋灞傜函鍑€銆?  - [x] 淇敼 `lib/ui/pages/ai_settings_screen.dart`锛岄€氳繃 `AiEngineRepository` 璇诲彇娲昏穬鏂囨湰涓庤瑙夊紩鎿庨厤缃紝闃绘柇鐩存帴璇诲彇 DB銆?  - [x] 淇敼 `lib/ui/pages/profile_screen.dart`锛屼娇鐢?`AiEngineRepository` 鏇夸唬搴曞眰 `DatabaseHelper` 鏂规硶鍛堢幇褰撳墠娲昏穬閰嶇疆鍚嶇О銆?- **楠岃瘉鐘舵€?*: 缁忔湰鍦板崟鍏冩祴璇曞拰 widget 娴嬭瘯楠岃瘉閫氳繃 (All tests passed)锛屾垚鍔熼殧绂?AI Engine 绠＄悊鎿嶄綔锛岄伩鍏?UI 灞備笌搴曞眰 DB 鑰﹀悎銆?## [2026-06-04 20:28] - refactor(ai): 杩佺Щ閬楃暀 LLMService 鑷崇粺涓€ Provider 杈圭晫
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: ai, services, provider, test
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 淇敼 `lib/services/llm_service.dart`锛岀Щ闄?`SharedPreferences` 鏃ф枃鏈?瑙嗚寮曟搸閰嶇疆璇诲彇涓庢墜鍐?`http.post` 璋冪敤锛岀粺涓€鏀逛负 `AiEngineRepository` + `LlmApiClient`銆?  - [x] 淇敼 `_fetchCompletion`锛屼繚鐣欐棫 `systemPrompt` / `userPrompt` 璋冪敤濂戠害锛屼絾閫氳繃 active text engine 鍙戣捣缁熶竴 provider 鏂囨湰璇锋眰銆?  - [x] 淇敼 `parsePdfToJSON`锛岄€氳繃 active vision engine 璋冪敤 `LlmApiClient.callVision`锛屽苟鏄惧紡闄愬埗 Base64 PDF 璺緞褰撳墠浠呮敮鎸?Gemini 瑙嗚寮曟搸锛岄伩鍏?OpenAI-compatible 鍒嗘敮璇敹涓嶅彲闈?PDF data URL銆?  - [x] 淇敼 `LlmTextRequest`锛屾柊澧?`systemPrompt`銆乣chatMessages` 涓?`combinedPrompt` 娲剧敓缁撴瀯锛汷penAI-compatible provider 浣跨敤 system/user messages锛孏emini provider 浣跨敤鍚堝苟 prompt銆?  - [x] 淇敼 `test/ai_engine_profile_test.dart`锛屾柊澧?system prompt 璇锋眰缁撴瀯娴嬭瘯锛岄槻姝?Provider 璇锋眰閫€鍖栦负鍗?user prompt銆?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format`銆乣dart analyze` 鍙楀奖鍝嶆枃浠堕泦鍚堛€乣dart analyze lib/services lib/data`銆乣flutter test test/ai_engine_profile_test.dart`銆佹棫閰嶇疆娈嬬暀 `rg` 鎼滅储涓?`git diff --check`锛涘畬鏁?`flutter test` 浠嶆寜绾﹀畾浜ょ敱 Gemini/鍙嶉噸鍔涙墽琛屻€?
## [2026-06-04 19:35] - refactor(ai): 寮曞叆寮虹被鍨?AI 寮曟搸閰嶇疆妯″瀷
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: ai, services, data, test
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板 `lib/data/models/ai_engine_profile.dart`锛屽畾涔?`AiEngineType` 涓?`AiEngineProfile`锛岄泦涓鐞?DB 琛屽瓧娈靛綊涓€鍖栥€佹俯搴﹂粯璁ゅ€笺€佹縺娲荤姸鎬佽浆鎹€乥aseUrl 灏炬枩鏉犳竻娲椾笌缂哄瓧娈佃瘖鏂€?  - [x] 鏂板 `lib/data/repositories/ai_engine_repository.dart`锛屾妸涓氬姟灞傝鍙?active text/vision engine 鐨勫叆鍙ｆ敹鏉熷埌 Repository锛岄伩鍏嶆湇鍔″眰鐩存帴娑堣垂 `Map<String, dynamic>`銆?  - [x] 淇敼 `lib/services/llm_api_client.dart` 涓?`lib/services/llm_providers/llm_provider_client.dart`锛屽皢 `callText` / `callVision` 鐨?profile 鍏ュ弬鏀逛负 `AiEngineProfile`锛岀Щ闄ゆ棫鐨?`LlmProviderProfile.fromMap` 閫傞厤鍣ㄣ€?  - [x] 淇敼 `lib/services/ai_service.dart`锛屾枃鏈敓鎴愩€佺瓟棰樸€佺粍鍗枫€侀敊棰樼敓鎴愩€佹枃鏈В鏋愩€佽瑙夎В鏋愬拰澶氭枃浠跺悎骞剁粺涓€閫氳繃 `AiEngineRepository` 鑾峰彇寮虹被鍨嬪紩鎿庨厤缃€?  - [x] 淇敼 `lib/services/latex_migration_service.dart`锛屽巻鍙?LaTeX 杩佺Щ閫昏緫澶嶇敤 `LlmApiClient.callText`锛屽垹闄ゆ湇鍔″唴鎵嬪啓 Gemini/OpenAI/Zhipu HTTP 鍒嗘敮銆?  - [x] 鏂板 `test/ai_engine_profile_test.dart`锛岃鐩?DB 鑴忔暟鎹綊涓€鍖栥€佺己瀛楁璇婃柇涓?`LlmTextRequest` 浠庡己绫诲瀷 profile 鏋勯€犺姹傘€?  - [x] 娓呯悊 `lib/data/models/question.dart` 鐨勬湭鐢?import锛屽苟灏?`lib/services/llm_service.dart` 涓殑 `print` 鏇挎崲涓?`debugPrint`锛屼娇 `lib/services lib/data` 瀹借寖鍥撮潤鎬佹鏌ヤ繚鎸佸共鍑€銆?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format`銆乣dart analyze lib/services lib/data`銆乣dart analyze` 鍙楀奖鍝嶆枃浠堕泦鍚堛€乣flutter test test/ai_engine_profile_test.dart`锛涘畬鏁?`flutter test` 浠嶆寜绾﹀畾浜ょ敱 Gemini/鍙嶉噸鍔涙墽琛屻€?
## [2026-06-04 19:02] - refactor(ai): 鎶界鏂囨。瑙ｆ瀽璺敱 Router
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: ai, services, test
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板缓 `lib/services/document_parse_router.dart`锛岄泦涓壙杞芥枃妗ｇ粨鏋勬帰閽堝悗鐨?A/B/C/D 璺緞鍒ゅ畾銆?  - [x] 鏂板 `DocumentParseRoute`銆乣DocumentParseSegment` 涓?`DocumentParsePlan`锛屽皢姣忔潯鏂囨。璺緞杞崲涓哄甫 `parseMode` 鐨勬壒娆¤В鏋愯鍒掋€?  - [x] 灏?`AiService.parseTextToQuestions` 涓殑灏鹃儴绛旀瑁佸壀銆侀灏惧垎绂汇€佸叏鏂囨棤绛旀鍜屾爣鍑嗚鍐呰В鏋愬垎鏀縼绉诲埌 `DocumentParseRouter.buildPlan`銆?  - [x] 淇敼 `AiService.parseTextToQuestions`锛屾寜 plan 缁熶竴杩藉姞 pending chunks 骞堕€愭璋冪敤 `parseMicroBatches`锛屼娇鏈嶅姟灞傚彧淇濈暀鎵ц缂栨帓銆?  - [x] 鏂板 `test/document_parse_router_test.dart`锛岃鐩栬矾寰?A 灏鹃儴绛旀瑁佸壀鍜岃矾寰?B 棰樺共/绛旀鍒嗙涓ゆ潯楂橀闄╄矾鐢便€?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format`銆乣dart analyze lib/services/ai_service.dart lib/services/document_parse_router.dart test/document_parse_router_test.dart`銆乣flutter test test/document_parse_router_test.dart`銆乣flutter test test/document_chunker_test.dart`銆乣flutter test test/document_parse_router_test.dart test/document_chunker_test.dart test/parse_batch_runner_test.dart test/question_parse_pipeline_test.dart`銆佸叧閿矾寰?`rg` 鎼滅储涓?`git diff --check`锛涘苟琛岃繍琛?Flutter 娴嬭瘯鏃舵浘瑙﹀彂 Windows native assets 宸ュ叿灞傛嫹璐濆啿绐侊紝宸叉敼涓洪『搴忛噸璺戜笖鍏ㄩ儴閫氳繃銆?
## [2026-06-04 14:36] - refactor(ai): 鎶界鏂囨。鍒嗗潡鍣?DocumentChunker
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: ai, services, test
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板缓 `lib/services/document_chunker.dart`锛岄泦涓壙杞芥櫘閫氭枃鏈笌 Markdown 鐨勫井鎵规鍒嗗潡绠楁硶銆?  - [x] 淇濈暀鍘熸櫘閫氭枃鏈?1500 瀛楃闃堝€笺€丮arkdown 2000 瀛楃闃堝€硷紝浠ュ強 Markdown 鏍囬/搴忓彿鍒嗗壊瑙勫垯锛岄伩鍏嶆敼鍙樿В鏋愬閮ㄨ涓恒€?  - [x] 淇敼 `lib/services/ai_service.dart`锛岀Щ闄?`splitTextIntoMicroBatches` 涓?`splitMarkdownIntoMicroBatches` 鍐呰仈瀹炵幇锛岀粺涓€閫氳繃 `_chunker.split(...)` 鑾峰彇鍒嗗潡銆?  - [x] 鏂板 `test/document_chunker_test.dart`锛岃鐩栨櫘閫氭枃鏈钀藉垎鍧楀拰 Markdown 鏍囬/搴忓彿鍒嗗潡涓ゆ潯璺緞銆?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format`銆乣dart analyze lib/services/ai_service.dart lib/services/document_chunker.dart test/document_chunker_test.dart`銆乣flutter test test/document_chunker_test.dart`銆乣flutter test test/parse_batch_runner_test.dart test/question_parse_pipeline_test.dart`銆佸叧閿矾寰?`rg` 鎼滅储涓?`git diff --check`锛涘畬鏁村洖褰掓祴璇曚氦鐢?Gemini/鍙嶉噸鍔涢獙璇併€?
## [2026-06-04 14:27] - refactor(ai): 鎶界寰壒娆¤В鏋愯皟搴?Runner
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: ai, services, test
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板缓 `lib/services/parse_batch_runner.dart`锛岄泦涓壙杞藉井鎵规瑙ｆ瀽鐨勫苟鍙?worker銆侀噸璇曟鏁般€佸喎鍗寸瓥鐣ャ€佹垚鍔熸殏鍋滃拰澶辫触璁℃暟閫昏緫銆?  - [x] 灏?`AiService.parseMicroBatches` 涓殑璋冨害寰幆杩佺Щ鍒?`ParseBatchRunner.run`锛屼娇 `AiService` 鍙礋璐ｆ彁渚涘崟鍧楄В鏋愬嚱鏁板拰 TaskManager 鎴愬姛/澶辫触鍥炶皟銆?  - [x] 閫氳繃 `ParseBatchRunResult` 杩斿洖鎸夊師 chunk 椤哄簭灞曞紑鐨勯鐩垪琛ㄥ拰澶辫触鏁伴噺锛岄伩鍏?UI/浠诲姟灞傜洿鎺ユ帴瑙﹁皟搴﹀唴閮ㄧ姸鎬併€?  - [x] 淇濈暀鍘熸湁 3 骞跺彂銆? 娆￠噸璇曘€佹垚鍔熷悗 500ms 鏆傚仠銆侀鐜囬檺鍒?缃戠粶閿欒閫€閬垮喎鍗寸瓥鐣ワ紝闄嶄綆琛屼负鍥炲綊椋庨櫓銆?  - [x] 鏂板 `test/parse_batch_runner_test.dart`锛岃鐩栧苟鍙戝畬鎴愰『搴忎笉褰卞搷杈撳嚭椤哄簭锛屼互鍙婃案涔呭け璐ユ椂浼氬畬鎴愰噸璇曞苟鎶ュ憡澶辫触 chunk銆?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format`銆乣dart analyze lib/services/ai_service.dart lib/services/parse_batch_runner.dart test/parse_batch_runner_test.dart`銆乣flutter test test/parse_batch_runner_test.dart`銆乣flutter test test/question_parse_pipeline_test.dart`銆佸叧閿矾寰?`rg` 鎼滅储涓?`git diff --check`锛涘畬鏁村洖褰掓祴璇曚氦鐢?Gemini/鍙嶉噸鍔涢獙璇併€?
## [2026-06-04 14:19] - refactor(ai): 鎶界棰樼洰瑙ｆ瀽鍚庡鐞?Pipeline
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: ai, services, test
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板缓 `lib/services/question_parse_pipeline.dart`锛岄泦涓壙杞?AI 瑙ｆ瀽鍚庣殑棰樼洰缁撴瀯鍚庡鐞嗛€昏緫銆?  - [x] 灏?`parseMicroBatches` 涓殑棰樺彿鏍囧噯鍖栥€佺函绛旀椤佃瘑鍒笌绛旀姹犳嫾鍥惧綊骞剁畻娉曡縼绉诲埌 `QuestionParsePipeline.mergeAnswerOnlyQuestions`銆?  - [x] 灏嗚瑙夎В鏋愯繑鍥炴枃鏈殑 JSON 娓呮礂涓庨骞茶川閲忛椄闂ㄨ縼绉诲埌 `QuestionParsePipeline.parseVisionQuestions`銆?  - [x] 淇敼 `lib/services/ai_service.dart`锛岄€氳繃 `_parsePipeline` 璋冪敤鍚庡鐞嗚兘鍔涳紝浣?`AiService` 鏇翠笓娉ㄤ簬 LLM 璋冪敤銆佸垎鍧楄皟搴﹀拰浠诲姟鐘舵€佺紪鎺掋€?  - [x] 鏂板 `test/question_parse_pipeline_test.dart`锛岃鐩栫瓟妗堥〉鎸夐鍙峰洖濉拰鏈尮閰嶇瓟妗堜繚鐣欎袱鏉￠槻寰¤矾寰勩€?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format`銆乣dart analyze lib/services/ai_service.dart lib/services/question_parse_pipeline.dart test/question_parse_pipeline_test.dart`銆乣flutter test test/question_parse_pipeline_test.dart`銆佸叧閿矾寰?`rg` 鎼滅储涓?`git diff --check`锛涘畬鏁村洖褰掓祴璇曚氦鐢?Gemini/鍙嶉噸鍔涢獙璇併€?
## [2026-06-04 13:57] - refactor(ai): 灏嗚瑙?LLM 璇锋眰杩佺Щ鑷?Provider Strategy
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: ai, services
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鍦?`lib/services/llm_providers/llm_provider_client.dart` 涓柊澧?`LlmVisionAsset` 涓?`LlmVisionRequest`锛屾敮鎸佸唴鑱?base64 璧勪骇涓庝笂浼犳枃浠惰祫浜т袱绉嶈瑙夎緭鍏ュ舰鎬併€?  - [x] 涓?`GeminiProviderClient`銆乣OpenAiCompatibleProviderClient` 涓?`ZhipuProviderClient` 澧炲姞 `callVision` 瀹炵幇锛屽垎鍒皝瑁?Gemini `inline_data`銆丱penAI-compatible `image_url` 涓庢櫤璋?PDF 涓婁紶瑙ｆ瀽璺緞銆?  - [x] 鍦?`LlmApiClient` 涓柊澧?`callVision` 闂ㄩ潰鏂规硶锛屼娇鏂囨湰涓庤瑙夎姹傞兘缁忚繃缁熶竴 provider strategy 鍒嗗彂鍜岄厤缃畬鏁存€ф鏌ャ€?  - [x] 閲嶆瀯 `AiService.parseImagesWithVision` 涓?`parseFileWithVision`锛岀Щ闄ら〉闈㈡湇鍔″眰涓殑搴曞眰 HTTP 璇锋眰鎷艰锛屼粎淇濈暀鏂囦欢璇诲彇銆佸浘鐗囧帇缂┿€乸rovider 閫夋嫨绾︽潫涓庨鐩川閲忛椄闂ㄣ€?  - [x] 鏂板 `_parseVisionQuestions` 涓?`_readFileAsVisionBase64` 杈圭晫 helper锛屽皢瑙嗚杩斿洖鏂囨湰瑙ｆ瀽鍜屾枃浠堕澶勭悊闆嗕腑绠＄悊銆?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format`銆乣dart analyze lib/services/ai_service.dart`銆乣dart analyze lib/services/llm_api_client.dart lib/services/llm_providers`銆佸叧閿矾寰?`rg` 鎼滅储涓?`git diff --check`锛涘畬鏁村洖褰掓祴璇曚氦鐢?Gemini/鍙嶉噸鍔涢獙璇併€?
## [2026-06-04 13:33] - refactor(ai): 闃插尽寮忔敹鏉熸枃鏈?LLM 璇锋眰杈圭晫
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: ai, services
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鍦?`lib/services/llm_providers/llm_provider_client.dart` 涓柊澧?`LlmProviderProfile` 鍊煎璞★紝缁熶竴娓呮礂 `api_key`銆乣base_url`銆乣model_name`銆乣temperature` 涓?`reasoning_effort`銆?  - [x] 灏?`LlmTextRequest` 鐨勯厤缃鍙栨敼涓洪€氳繃 `LlmProviderProfile.fromMap` 鏋勯€狅紝骞跺湪 `LlmApiClient` 涓緭鍑虹己澶卞瓧娈靛垪琛紝鎻愬崌閰嶇疆閿欒鍙瘖鏂€с€?  - [x] 灏?`AiService.judgeAnswer` 涓?`mergeStructuredQuestions` 浠庢墜鍐?Gemini/OpenAI HTTP 鍒嗘敮杩佺Щ鍒?`_apiClient.callText`锛岃鏂囨湰璇锋眰缁熶竴缁忚繃 provider strategy銆?  - [x] 娓呯悊鏂囨湰鐢熸垚銆佸崟棰樹綔绛斻€佺粍鍗枫€侀敊棰樼敓鎴愪笌鍒嗗潡瑙ｆ瀽涓殑閲嶅寮曟搸涓変欢濂楁牎楠岋紝鐢辫姹傝竟鐣岀粺涓€闃插尽銆?  - [x] 浣跨敤 Dart fixer 琛ラ綈 `ai_service.dart` 涓?12 澶勫崟琛?`if` 澶ф嫭鍙凤紝闄嶄綆鍚庣画缂栬緫璇寕鍒嗘敮鐨勯闄┿€?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format`銆乣dart analyze lib/services/ai_service.dart`銆乣dart analyze lib/services/llm_api_client.dart lib/services/llm_providers`銆佸叧閿矾寰?`rg` 鎼滅储涓?`git diff --check`锛涘畬鏁村洖褰掓祴璇曚氦鐢?Gemini/鍙嶉噸鍔涢獙璇併€?
## [2026-06-04 13:18] - refactor(ai): 鎷嗗垎鏂囨湰 LLM Provider Strategy
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: ai, services
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板缓浜?`lib/services/llm_providers/` 绛栫暐鐩綍锛屽畾涔?`LlmProviderClient` 涓?`LlmTextRequest`锛屽皢鏂囨湰妯″瀷璇锋眰鍙傛暟浠庨棬闈㈠鎴风涓娊绂讳负鏄庣‘鐨勬暟鎹粨鏋勩€?  - [x] 鏂板浜?`GeminiProviderClient`銆乣OpenAiCompatibleProviderClient` 涓?`ZhipuProviderClient`锛屽垎鍒皝瑁?Gemini銆丱penAI-compatible 鍜屾櫤璋辨枃鏈ˉ鍏ㄨ姹傝矾寰勩€?  - [x] 鏂板浜?`LlmProviderRegistry`锛屾寜 `baseUrl` 鑷姩閫夋嫨瀵瑰簲 provider锛屼娇 `LlmApiClient` 浠庡簳灞傝姹傚疄鐜版敹缂╀负杞婚噺闂ㄩ潰銆?  - [x] 淇濈暀浜?`LlmApiClient.buildChatUrl` 涓?`extractContent` 鍏煎鍏ュ彛锛岄伩鍏嶅奖鍝嶅綋鍓嶈瑙夎В鏋愬垎鏀€?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format`銆佸畾鍚?`dart analyze` 涓?provider 鍏抽敭璺緞鎼滅储锛涘畬鏁村洖褰掓祴璇曚氦鐢?Gemini/鍙嶉噸鍔涢獙璇併€?
## [2026-06-04 13:08] - refactor(ai): 灏?AI 鐢熸垚棰樼洰鎺ュ彛鏀逛负杩斿洖 QuestionDraft
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: ai, ui, models
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 淇敼浜?`lib/services/ai_service.dart`锛屽皢 `generateQuestions`銆乣generateExamPaper` 涓?`generateAndSaveQuestionsFromMistakes` 鐨勫叕寮€杩斿洖绫诲瀷浠?`List<Map<String, dynamic>>` 鏀舵潫涓?`List<QuestionDraft>`銆?  - [x] 鍦?AI 鏈嶅姟鍐呴儴瀹屾垚 JSON Map 鍒?`QuestionDraft` 鐨勮竟鐣岃浆鎹紝璁╁急绫诲瀷鏁版嵁鍋滅暀鍦?AI JSON 瑙ｆ瀽杈圭晫鍐呫€?  - [x] 淇敼浜?`lib/ui/pages/ai_generator_screen.dart`锛岀Щ闄ょ敓鎴愰鐩拰 AI 缁勫嵎鍚庣殑閲嶅 `QuestionDraft.listFromMaps` 杞崲锛岀洿鎺ユ秷璐瑰己绫诲瀷杩斿洖鍊笺€?- **楠岃瘉鐘舵€?*: 宸插畬鎴?`dart format`銆佸畾鍚?`dart analyze` 涓庢畫鐣欒皟鐢ㄦ悳绱紱瀹屾暣鍥炲綊娴嬭瘯浜ょ敱 Gemini/鍙嶉噸鍔涢獙璇併€?
## [2026-06-04 12:56] - refactor(arch): 寮曞叆寮虹被鍨?QuestionDraft 缁熶竴 UI 涓庢寔涔呭寲灞傛暟鎹ā鍨?- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: models, repositories, ui, test
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板缓浜?`lib/data/models/question_draft.dart`锛屽畾涔変簡寮虹被鍨嬬殑 `QuestionDraft` 鍜?`QuestionType` 鏋氫妇锛屽彇浠ｄ簡鍘熸湰浼犻€?`Map<String, dynamic>` 鐨勫急绫诲瀷鏂瑰紡銆?
  - [x] 鏀归€犱簡 `lib/ui/pages/ai_generator_screen.dart` 涓?`lib/ui/pages/import_staging_screen.dart`锛屽皢鍏跺唴閮ㄧ殑 `_questions` 鍜?`_displayQuestions` 鐘舵€佹洿鏀逛负 `List<QuestionDraft>`锛屾墍鏈夐鐩睘鎬ч€氳繃鐐硅繍绠楃锛堝 `q.content`銆乣q.options`锛夎繘琛屽己绫诲瀷璁块棶銆?
  - [x] 浼樺寲浜?`lib/data/repositories/question_repository.dart`锛岄噸杞藉苟鏆撮湶 `saveQuestionDraftsToBank` 鎺ュ彛锛屼娇淇濆瓨閾捐矾鐩存帴鎺ユ敹 `List<QuestionDraft>`锛屼笉鍐嶅湪瀛樼洏鏃朵复鏃舵墽琛?Map 鍒?Model 鐨勮剢寮辫浆鍨嬨€?
  - [x] 鏂板浜?`test/question_draft_test.dart` 娴嬭瘯濂椾欢锛屽畬鏁磋鐩栦簡 AI JSON Map 鍒板己绫诲瀷 `QuestionDraft` 鐨勫閿欐竻娲楀拰闃插尽杞崲娴嬭瘯銆?
- **楠岃瘉鐘舵€?*: 缁忔湰鍦板崟鍏冩祴璇曞拰 widget 娴嬭瘯楠岃瘉閫氳繃 (All 16 tests passed!)銆?

## [2026-06-04 07:45] - refactor(arch): 灏嗚儢鏈嶅姟瑙ｈ€﹀苟閲嶆瀯鏁版嵁瀛樺偍涓?Repository 妯″紡
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: services, data, ui, utils
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板缓浜?`lib/data/repositories/question_repository.dart`锛岃礋璐ｇ粺涓€绠＄悊棰樺簱鎸佷箙鍖栥€佹爲鐘剁粨鏋勮鍙栥€佽€冭瘯璇曞嵎鍒涘缓鍜岄鐩垹闄わ紝褰诲簳娑堥櫎 UI 瀵瑰簳灞?SQL 鐨勭洿鎺ヤ緷璧栥€?
  - [x] 鏂板缓浜?`lib/services/ai_prompts.dart`锛屽皢鍘熷厛娣锋潅鍦?AI 鏈嶅姟涓殑 LaTeX 瀹氱晫绗﹁鍒欏拰瑙嗚瑙ｆ瀽闀跨瘒 Prompt 鎻愮ず璇嶆娊绂昏嚦涓撶敤绫荤鐞嗐€?
  - [x] 鏂板缓浜?`lib/services/llm_api_client.dart`锛岄泦涓皝瑁呭簳灞?HTTP 璇锋眰鐨勫弬鏁扮粍鍚堛€佽璇佸拰娴佸紡鍥炲鎺ュ彛銆?
  - [x] 鏂板缓浜?`lib/utils/image_utils.dart`锛屽皢 CPU 娑堣€楅珮鐨?Isolates 鍥剧墖寮傛鍘嬬缉閫昏緫鐙珛涓虹函鍑€宸ュ叿鍑芥暟銆?
  - [x] 閲嶆瀯浜?`lib/services/ai_service.dart`锛岀Щ闄ゅ崈琛屼互涓婄殑 Prompt 瀹氫箟鍜屽簳灞傝姹傜粏鑺傦紝绮剧畝涓虹函绮圭殑楂樺眰鎺ュ彛涓氬姟缂栨帓鑰呫€?
  - [x] 鏀归€犱簡 `lib/ui/pages/import_staging_screen.dart` 涓?`lib/ui/pages/ai_generator_screen.dart`锛岀敤 `QuestionRepository` 鍙栦唬浜嗙洿鎺ョ殑 SQL `db.transaction` 瀛樼洏鍜岃鍙栵紝瀹炵幇浜嗚鍥句笌鎸佷箙鍖栨暟鎹殑楂樺害瑙ｈ€︺€?
- **楠岃瘉鐘舵€?*: 缁忔湰鍦板崟鍏冩祴璇曞拰 widget 娴嬭瘯楠岃瘉閫氳繃 (All 14 tests passed!)銆?

## [2026-06-04 00:36] - fix(latex): 淇 LaTeX 宓屽瀹氱晫绗﹁В鏋愪笌鍏紡鍙岄噸鍖呰９闂
- **鍙樻洿绫诲瀷**: fix
- **褰卞搷妯″潡**: utils, test
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 淇敼浜?`lib/utils/content_tokenizer.dart` 涓殑 `_findClosingDelimiter` 鏂规硶锛屽紩鍏ユ繁搴︽劅鐭ワ紙depth-aware锛夋壂鎻忔満鍒讹紝瀹岀編澶勭悊浜?LaTeX 鍐呭祵濂楀畾鐣岀锛堝鍦?`\right)` 鍐呭祵濂?parentheses锛夊鑷寸殑鏃╂湡鎴柇 Bug銆?
  - [x] 淇敼浜?`lib/utils/content_normalizer.dart`锛屽悓姝ユ洿鏂板叾 `_findClosingDelimiter` 鏂规硶鑷虫繁搴︽劅鐭ョ増鏈紝缁熶竴浜嗚В鏋愯涓恒€?
  - [x] 淇敼浜?`lib/utils/content_normalizer.dart`锛屽湪 `_normalize` 绠￠亾涓柊澧?`_stripDoubleDelimiters` 姝ラ锛岃兘澶熻嚜鍔ㄥ鏁版嵁涓凡鏈夌殑鍙岄噸鍏紡鍖呰９瀹氱晫绗︼紙濡?`\(\(...\)\)`銆乣\[\[...\]\]`锛夎繘琛岃В鍖呮姌鍙犮€?
  - [x] 浼樺寲浜?`lib/utils/content_normalizer.dart` 涓殑 `_convertDollarDelimiters` 鏂规硶锛屽紩鍏?`_isFullyWrapped` 妫€娴嬫満鍒讹紝閬垮厤鍦ㄨ繘琛岀編寮忓垁甯佺锛坄$` / `$$`锛夎浆鎹㈡椂锛屽鏈氨宸插寘瑁逛簡 `\(` 鎴?`\[` 瀹氱晫绗︾殑 LaTeX 鍏紡閲嶅杩藉姞澶栧眰鍖呰锛屼粠婧愬ご涓婃潨缁濅簡鍙岄噸鍖呰９鐨勪骇鐢熴€?
  - [x] 鎵╁睍浜?`test/render_matrix_test.dart` 娴嬭瘯濂椾欢锛岃ˉ鍏呬簡閽堝鍙岄噸瀹氱晫绗︽姌鍙犮€佸垁甯佺闃插弻閲嶅寘瑁瑰鐞嗙瓑澶氶」娣卞害鐢ㄤ緥锛屼笖鏁翠綋鍗曞厓/Widget娴嬭瘯鍏ㄩ儴鏃犻敊閫氳繃銆?
- **楠岃瘉鐘舵€?*: 缁忔湰鍦板崟鍏冩祴璇曞拰 widget 娴嬭瘯楠岃瘉閫氳繃 (All 14 tests passed!)銆?

## [2026-06-04 00:13] - refactor(render): 鍩轰簬Tokenizer閲嶆瀯鍒嗚瘝涓庢暟瀛﹀叕寮忔覆鏌撶绾?
- **鍙樻洿绫诲瀷**: refactor
- **褰卞搷妯″潡**: render, ui, utils
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 鏂板缓浜?`lib/utils/content_tokenizer.dart`锛屽疄鐜板熀浜庣姸鎬佹満椤哄簭鎵弿鐨勬枃鏈€佹暟瀛﹀叕寮忋€佸浘鐗囧強绌虹櫧鍗犱綅鍒嗚瘝鍣紝鍙栦唬娣蜂贡鐨勬鍒欒〃杈惧紡鎵弿銆?
  - [x] 鏂板缓浜?`lib/utils/content_normalizer.dart`锛岀敤浜庢爣鍑嗗寲鍏紡瀹氱晫绗︼紙濡傛妸 `$$` 鍜?`$` 缁熶竴涓?`\[` 鍜?`\(`锛夛紝鑷姩鍓ョ LaTeX 鍐呴儴鐨勮繛缁笅鍒掔嚎 `___` 骞惰繃婊?`<think>` 鏍囩銆?
  - [x] 鏂板缓浜?`lib/ui/widgets/structured_content_renderer.dart`锛屽熀浜?Token 搴忓垪鍒╃敤 `RichText` 涓?`WidgetSpan` 缁撴瀯鍖栫粍鍚堣鍐呭厓绱狅紝骞跺鍔犱簡閽堝琛屽唴鍏紡鐨勮嚜閫傚簲缂╂斁銆佸潡绾у叕寮忕殑妯悜婊氬姩銆佺壒娈婃寚浠ゆ浛鎹笌 Unicode 瀛楃鑷姩绾犻敊绛夐槻寰℃€ф満鍒躲€?
  - [x] 淇敼浜?`lib/ui/widgets/markdown_extensions.dart`锛屽皢 `buildLatexWidget` 缁熶竴鎸囧悜鏂扮殑 `StructuredContentRenderer`锛屽疄鐜板叏灞€鏃犵紳鍗囩骇銆?
  - [x] 淇敼浜?`lib/utils/ai_data_sanitizer.dart`锛岄厤鍚堟柊褰掍竴鍖栧紩鎿庣畝鍖栨暟鎹叆搴撲笌娓呮礂绠￠亾銆?
  - [x] 閲嶆瀯浜?`test/render_matrix_test.dart` 娴嬭瘯濂椾欢锛岃ˉ鍏呰鐩栦簡 Tokenizer銆丯ormalizer 鍙?Widget 娓叉煋鐨勫悇椤硅竟鐣屾潯浠讹紝楠岃瘉鍏ㄩ儴閫氳繃銆?
- **楠岃瘉鐘舵€?*: 缁忔湰鍦板崟鍏冩祴璇曞拰 widget 娴嬭瘯楠岃瘉閫氳繃 (All 12 tests passed!)銆?

## [2026-06-01 07:34] - fix(ai): 绉婚櫎瑁稿懡浠ゅ寘瑁归€昏緫锛岀粺涓€灏?\(\) 鍜?\[\] 杞崲涓?\$锛屽己鍖?AI 鍗犱綅绗﹀寘瑁圭孩绾?
- **鍙樻洿绫诲瀷**: fix
- **褰卞搷妯″潡**: ai_engine, ai_sanitizer
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 淇敼浜?`lib/utils/ai_data_sanitizer.dart`锛岀Щ闄?`formatLatex` 涓笉绋冲畾鐨勮８ LaTeX 鍛戒护鎵弿鍖呰９鏈哄埗锛岄伩鍏嶈浼ら泦鍚堟弿杩扮瓑澶嶆潅鏂囨湰銆?
  - [x] 鏂板 `normalizeDelimiters` 杞崲娓呮礂灞傦紝鑷姩涓斿畨鍏ㄥ湴灏嗗ぇ妯″瀷鍊惧悜杈撳嚭鐨?`\(` `\)` 鍜?`\[` `\]` 鏇挎崲涓烘爣鍑?`$` 鍜?`$$` 鍖呰９锛屽悓鏃跺皢鍏跺湪鍏ュ簱鍓嶅拰娓叉煋鍓嶇疆鎷︽埅璺緞涓墽琛岋紝瀹岀編鍏煎鍘嗗彶閿欒鏁版嵁涓庢柊浠诲姟鏁版嵁銆?
  - [x] 淇敼浜?`lib/services/ai_service.dart`锛屽湪涓変釜鏍稿績澶фā鍨?Prompt 涓鍔犱弗鏍肩殑鈥滅粷瀵圭姝娇鐢?`\(` `\)` 鎴?`\[` `\]` 鍏紡鍗犱綅绗︹€濈孩绾跨害鏉熴€?
- **楠岃瘉鐘舵€?*: 缁忔湰鍦伴潤鎬佹鏌ュ強娌欑洅鍖归厤楠岃瘉鍏ㄩ儴閫氳繃銆?

## [2026-05-31 23:55] - fix(ai): 浼樺寲閫夋嫨棰橀€夐」鍓ョ涓庤В绛旈瑙ｆ瀽鎻愬彇锛屽己鍖?LaTeX 鍏紡鍖呰９闃插憜瑙勮寖
- **鍙樻洿绫诲瀷**: fix
- **褰卞搷妯″潡**: ai_engine, ai_sanitizer
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 淇敼浜?`lib/services/ai_service.dart`锛屽榻愬苟鍗囩骇鍏ㄩ儴瑙ｆ瀽鎻愮ず璇嶏紙Prompt锛夛紝娣诲姞閫夋嫨棰橀€夐」寮哄埗鍓ョ瑙勫垯锛屼互鍙婃洿鍋ュ叏鐨?LaTeX 琛屽唴涓庣幆澧冨叕寮忛槻鍛嗗寘瑁圭害鏉熴€?
  - [x] 鍦ㄨВ绛旈鐨?JSON Schema 涓樉寮忚ˉ鍏ㄤ簡 `explanation` 瀛楁锛屽苟淇浜嗘枃鏈垎鍧楄В鏋愭彁绀鸿瘝涓姝?鎻愬彇瑙ｆ瀽鐨勯€昏緫鍐茬獊锛屼粠鑰屽畬缇庢敮鎸佺畝绛旈/璇佹槑棰樻彁鍙栬В鏋愩€?
  - [x] 淇敼浜?`lib/utils/ai_data_sanitizer.dart`锛屾柊澧炰簡閽堝棰樺共娈嬬暀 A/B/C/D 閫夐」鐨勬鍒欏墺绂讳笌棰樺瀷绾犻敊鍏滃簳鎻愬彇鏈哄埗銆?
- **楠岃瘉鐘舵€?*: 缁忓崟鍏冩祴璇曚笌鏈湴闈欐€佹鏌ュ叏閮ㄩ€氳繃銆?

## [2026-05-31 23:07] - fix(ai_sanitizer): 寮曞叆鍗犱綅绗﹂殧绂绘硶骞朵慨澶?JSON 鍙嶆枩鏉犺浆涔?
- **鍙樻洿绫诲瀷**: fix
- **褰卞搷妯″潡**: ai_sanitizer, ui
- **璇︾粏鏀瑰姩鏄庣粏**:
  - [x] 淇敼浜?`lib/utils/ai_data_sanitizer.dart`锛岄噸鏋?`formatLatex` 鏂规硶锛屽紩鍏ュ熀浜庡崰浣嶇鐨?`___LATEX_BLOCK_x___` 闅旂鏈哄埗锛岃瘯鍥捐В鍐冲閲嶅畾鐣岀鍐茬獊闂銆?
  - [x] 鍦?`cleanAndParseJson` 涓慨澶嶄簡鐢变簬鐗╃悊鎹㈣鏇挎崲寮曞彂鐨勫ぇ妯″瀷鏈浆涔?LaTeX 鍙嶆枩鏉狅紙濡?`\mu`, `\frac`锛夐€犳垚鐨?JSON 瑙ｆ瀽宕╂簝銆?
  - [x] 浼樺寲 `cleanLatexBeforeDB` 浠ュ鐞嗙煩闃靛墠鐨勭郴鏁板苟鍔犲己 Markdown 鍧楃骇璇嗗埆銆?
  - [x] 淇敼浜?`lib/ui/widgets/markdown_extensions.dart`锛屽湪鍐呰仈鍏紡 `Math.tex` 鐨勬姤閿?Fallback 涓幓闄や簡鏄惧紡鐨勬鑹插瓧浣擄紝骞跺鍔犱簡瀛楁暟瓒?200 闄嶇骇绾枃鏈殑瀹夊叏闃插尽銆?
- **楠岃瘉鐘舵€?*: 缁忔湰鍦版鏌ヨ褰曟湰娆″彉鍔ㄣ€?

## [2026-06-05 09:22] - refactor(ai): 抽离 AI 导入任务恢复编排器
- **变更类型**: refactor
- **影响模块**: ai, task_manager, import-resume
- **详细改动明细**:
  - [x] 新增 `lib/services/ai_task_resume_coordinator.dart`，集中管理文本分块任务与视觉图片任务的断点恢复流程。
  - [x] 将 `AiService.resumeTask` 改为轻量委托，继续保留原有对外 API，避免影响 `task_center_screen` 的调用链。
  - [x] 通过函数注入方式向 `AiTaskResumeCoordinator` 提供 `parseMicroBatches` 与 `parseImagesWithVision` 能力，避免 coordinator 反向依赖 `AiService`。
  - [x] 清理 `TaskManager.fromMap` 中 pending/failed chunk 反序列化的单行 `if`，降低后续编辑分支误挂风险。
- **验证状态**: 已执行 `dart analyze lib\services\ai_service.dart lib\services\ai_task_resume_coordinator.dart lib\services\task_manager.dart`，结果 `No issues found`；并执行 `flutter test test\architecture_boundary_test.dart`，通过。全量回归测试交由 Gemini/反重力执行。

## [2026-06-05 09:05] - refactor(ai): 抽离视觉资产构建器，继续收束 AiService 职责
- **变更类型**: refactor
- **影响模块**: ai, vision, services
- **详细改动明细**:
  - [x] 新增 `lib/services/vision_asset_builder.dart`，集中处理视觉输入文件读取、图片压缩、Base64 编码与 `LlmVisionAsset` 构建。
  - [x] 将多图视觉解析中的大图压缩与 inline asset 组装从 `AiService.parseImagesWithVision` 迁移到 `VisionAssetBuilder.buildInlineImageAssets`。
  - [x] 将单文件视觉解析中的图片/PDF inline asset 构建从 `AiService.parseFileWithVision` 迁移到 `VisionAssetBuilder.buildInlineFileAsset`。
  - [x] 删除 `AiService` 内部遗留的 `_compressImageSync` 与 `_readFileAsVisionBase64` 辅助逻辑，使 `AiService` 更专注于引擎配置、provider 选择、LLM 调用和结果解析。
- **验证状态**: 已执行 `dart analyze lib\services\ai_service.dart lib\services\vision_asset_builder.dart`，结果 `No issues found`；并执行 `flutter test test\ai_engine_profile_test.dart`，全部通过。全量回归测试交由 Gemini/反重力执行。

## [2026-06-05 08:45] - fix(quality): 修复 ReviewRepository 编码损坏并清理复习模块 lint 噪声
- **变更类型**: fix, quality
- **影响模块**: review, dashboard, static-analysis
- **详细改动明细**:
  - [x] 将 `lib/data/repositories/review_repository.dart` 从“基本 UTF-8 但含损坏字节”的状态恢复为合法 UTF-8，修复 Dart analyzer 无法通过 package URI 解析 `ReviewRepository` 的硬错误。
  - [x] 抽出 `_globalWrongBookBankName` 常量，修复三处“全局错题本”比较字符串缺失 closing quote 的语法风险，并降低后续重复硬编码概率。
  - [x] 清理 `ReviewRepository.getStudySessionQuestions` 中的单行 `if`，降低后续编辑时误挂 `else` 分支的风险。
  - [x] 将 `ReviewDashboard` 中的 `withOpacity` 替换为 `withValues(alpha: ...)`，并把“明天”判断改为跨月安全的 `DateTime(...).add(Duration(days: 1))`。
  - [x] 将 `ReviewEngineService` 与 `lib/test_math2.dart` 中的 `print` 替换为 `debugPrint`，减少 analyzer 噪声。
- **验证状态**: 已执行 `dart analyze lib\ui\widgets\review_dashboard.dart lib\data\repositories\review_repository.dart lib\core\review_engine_service.dart lib\test_math2.dart`，结果 `No issues found`。全量 `dart analyze lib test` 与 `flutter test` 交由 Gemini/反重力执行。

## [2026-06-05 08:28] - test(architecture): 新增分层架构边界守卫测试
- **变更类型**: test, architecture
- **影响模块**: architecture, test
- **详细改动明细**:
  - [x] 新增 `test/architecture_boundary_test.dart`，扫描 `lib/**/*.dart` 并按规则表校验数据库边界。
  - [x] 明确允许 `DatabaseHelper` / `sqflite` 只出现在 `lib/core/database/`、`lib/data/repositories/` 与启动引导 `lib/main.dart` 的必要范围内。
  - [x] 将 `rawQuery` 与 `.transaction(` 限定在 DatabaseHelper/Repository 层，防止 UI、Service 或领域逻辑重新出现裸 SQL。
  - [x] 测试失败时输出文件、行号、命中的规则名与原因，便于后续开发即时定位越界调用。
- **验证状态**: 已执行 `dart analyze test/architecture_boundary_test.dart` 与 `flutter test test/architecture_boundary_test.dart`，均通过。全量回归测试交由 Gemini/反重力执行。

## [2026-06-05 08:12] - test(review): 接手复习仪表盘回归测试并稳定 Widget 用例
- **变更类型**: test, fix
- **影响模块**: review_dashboard, review_repository, ui tests
- **详细改动明细**:
  - [x] 修复 `dart analyze lib test` 中会阻断退出码的 warning，清理未使用的 `Uuid` 字段、未使用查询结果、未使用 import 与局部变量。
  - [x] 为 `ReviewDashboard` 增加可选 `ReviewDashboardLoader` 注入点，生产路径仍默认调用 `ReviewEngineService.getReviewDashboardData`，Widget 测试可使用 fake loader 隔离真实 SQLite 异步 I/O。
  - [x] 修复 `test/review_dashboard_test.dart` 中 bankName 切换测试的异步不稳定问题，使 UI 状态切换测试与数据聚合测试各自独立。
- **验证状态**: `dart analyze lib test` 命令正常退出，无 error/warning；仍保留 93 条历史 info 级 lint/弃用提示。`flutter test test/review_dashboard_test.dart` 4 项通过，`flutter test` 全量 32 项全部通过。

## [2026-06-05 08:58] - refactor(ai): 抽离结构化题目合并服务并修复 AiService 编码污染
- **变更类型**: refactor, fix
- **影响模块**: services, ai
- **详细改动明细**:
  - [x] 新增 `lib/services/structured_question_merge_service.dart`，集中承载多文件结构化题目结果的 LLM 合并、JSON 解析与错误边界。
  - [x] 将 `AiService.mergeStructuredQuestions` 收缩为兼容门面，外部调用契约保持不变，导入设置页无需调整。
  - [x] 重新恢复 `ai_service.dart` 的正确 UTF-8 语义后，重新套回断点恢复协调器、视觉资源构建器与结构化合并服务委托，消除一次错误编码写回造成的字符串解析风险。
- **验证状态**: 已完成 `dart format lib/services/ai_service.dart lib/services/structured_question_merge_service.dart`、`dart analyze lib/services/ai_service.dart lib/services/structured_question_merge_service.dart`、`flutter test test/architecture_boundary_test.dart`，均通过。完整回归继续交由 Gemini/反重力执行。

## [2026-06-05 12:31] - refactor(ai): 抽离文本生成用例服务，继续瘦身 AiService
- **变更类型**: refactor
- **影响模块**: services, ai
- **详细改动明细**:
  - [x] 新增 `lib/services/ai_text_generation_service.dart`，集中承载判分、AI 生成题目、单题作答、AI 组卷与错题重练生成五条文本模型用例。
  - [x] 将 `AiService.judgeAnswer`、`generateQuestions`、`answerSingleQuestion`、`generateExamPaper`、`generateAndSaveQuestionsFromMistakes` 收缩为兼容门面，UI 调用契约保持不变。
  - [x] 将错题重练的错题上下文组装、文本引擎读取、生成结果解析与题库保存移动到用例服务内，`AiService` 不再直接依赖 `QuestionRepository`。
  - [x] 保留原有异常语义、Prompt 入口与 `QuestionDraft` 返回契约，避免影响现有页面和 Repository 层。
- **验证状态**: 已完成 `dart format lib/services/ai_service.dart lib/services/ai_text_generation_service.dart`、`dart analyze lib/services/ai_service.dart lib/services/ai_text_generation_service.dart`、`dart analyze lib/services`、`flutter test test/architecture_boundary_test.dart`、`flutter test test/ai_engine_profile_test.dart`、`git diff --check`。除 Windows 行尾提示外均通过，完整回归继续交由 Gemini/反重力执行。

## [2026-06-05 18:46] - refactor(ai): 抽离视觉解析用例服务，继续收缩 AiService 门面
- **变更类型**: refactor
- **影响模块**: services, ai, vision
- **详细改动明细**:
  - [x] 新增 `lib/services/ai_vision_parse_service.dart`，集中承载图片批量解析、单文件/PDF 视觉解析、provider 类型约束、视觉模型调用与返回题目解析。
  - [x] 将 `AiService.parseImagesWithVision` 与 `parseFileWithVision` 收缩为兼容门面，UI 导入页和断点恢复调用链保持不变。
  - [x] 将 `VisionAssetBuilder`、`LlmProviderRegistry`、`LlmVisionAsset` 与 `callVision` 细节移出 `AiService`，使 `AiService` 不再直接关心视觉资源和 provider 分支。
  - [x] 保留原有 DOCX/PDF provider 限制、SocketException 兜底、Zhipu/Gemini/OpenAI-compatible 超时策略和视觉返回解析门槛。
- **验证状态**: 已完成 `dart format lib/services/ai_service.dart lib/services/ai_vision_parse_service.dart`、`dart analyze lib/services/ai_service.dart lib/services/ai_vision_parse_service.dart`、`dart analyze lib/services`、`flutter test test/architecture_boundary_test.dart`、`git diff --check`。除 Windows 行尾提示外均通过，完整回归继续交由 Gemini/反重力执行。

## [2026-06-05 18:51] - refactor(ai): 抽离文本解析编排服务，AiService 收缩为薄门面
- **变更类型**: refactor
- **影响模块**: services, ai, import
- **详细改动明细**:
  - [x] 新增 `lib/services/ai_text_parse_service.dart`，集中承载文档结构路由、pending chunks 记录、微批次并发解析、失败重试回调、答案页拼图归并和解析失败兜底。
  - [x] 将 `AiService.parseTextToQuestions` 与 `parseMicroBatches` 收缩为兼容门面，断点恢复、导入页和测试调用入口保持不变。
  - [x] 将 `_parseSingleChunkToQuestions` 从 `AiService` 内移出，文本解析 LLM 调用现在由 `AiTextParseService` 管理。
  - [x] `AiService` 不再直接依赖 `DocumentParseRouter`、`ParseBatchRunner`、`QuestionParsePipeline`、`TaskManager` 或文本解析 JSON 清洗细节，文件规模收缩到 129 行。
- **验证状态**: 已完成 `dart format lib/services/ai_service.dart lib/services/ai_text_parse_service.dart`、`dart analyze lib/services/ai_service.dart lib/services/ai_text_parse_service.dart`、`dart analyze lib/services`、`flutter test test/document_parse_router_test.dart test/parse_batch_runner_test.dart test/question_parse_pipeline_test.dart`、`flutter test test/architecture_boundary_test.dart`、`git diff --check`。除 Windows 行尾提示外均通过，完整回归继续交由 Gemini/反重力执行。

## [2026-06-05 18:59] - refactor(ai): 抽离直接 LLM 调用兼容网关，AiService 完成薄门面化
- **变更类型**: refactor
- **影响模块**: services, ai
- **详细改动明细**:
  - [x] 新增 `lib/services/ai_direct_call_service.dart`，承载旧兼容入口 `callLlmApi` 的文本模型直连与图片输入 JSON 包装逻辑。
  - [x] 将 `AiService.callLlmApi` 收缩为单行委托，保留旧 API 签名不变。
  - [x] `AiService` 不再直接依赖 `dart:convert`、`AiEngineRepository` 或 `LlmApiClient`，所有 AI 具体能力都转交给专门服务。
  - [x] `AiService` 文件规模进一步收缩到 119 行，定位完成转变为稳定 API 兼容门面。
- **验证状态**: 已完成 `dart format lib/services/ai_service.dart lib/services/ai_direct_call_service.dart`、`dart analyze lib/services/ai_service.dart lib/services/ai_direct_call_service.dart`、`dart analyze lib/services`、`flutter test test/architecture_boundary_test.dart`、`git diff --check`。除 Windows 行尾提示外均通过，完整回归继续交由 Gemini/反重力执行。

## [2026-06-05 19:05] - refactor(architecture): 架构审计通过并整理服务分层提交
- **变更类型**: refactor
- **影响模块**: architecture, ai, review, test
- **详细改动明细**:
  - [x] 完成 `AiService` 门面化审计，确认其不再直接依赖 `AiEngineRepository`、`LlmApiClient`、`DatabaseHelper` 或底层视觉/文本解析实现细节。
  - [x] 审计 `lib/ui` 与 `lib/services`，确认无 `DatabaseHelper`、`rawQuery`、`transaction(` 等底层数据库边界泄漏。
  - [x] 整理本轮新增服务、Repository、复习仪表盘模型/Widget 与架构边界测试，排除临时上下文导出 `project_context.txt`。
  - [x] 复核 Gemini/反重力全量回归结果：`dart analyze lib test` 为 0 Error / 0 Warning，`flutter test` 33 项全部通过，`git diff --check` 仅有 Windows 行尾提示。
- **验证状态**: 已完成架构边界搜索、变更范围审计与提交前 diff 检查，准备执行原子化提交与远程同步。
