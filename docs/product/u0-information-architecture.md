# U0 Information Architecture Design Freeze

## 1. Status

**Frozen for U1**

本文件是 U0（Information Architecture Design Freeze）的唯一 deliverable。它冻结 Shiroha 的信息架构（IA）与入口责任，作为 U1 导航迁移与 F0/J0 入口接线的契约输入；不包含任何 UI 细节决策，不产生任何生产代码、schema 或依赖变更。

权威依据为 `docs/architecture/n0-post-p5-roadmap.md`（U0/F0/J0/U1 阶段定义、J0 关系形状、非目标）与 ADR-001/002/003。本文件不得与上述文档矛盾；本文件未覆盖之处以 N0 与 ADR 为准。

## 2. Current IA

现状调查（只读核对 `lib/ui/pages/main_screen.dart`、`lib/ui/pages/home_page.dart`、`lib/ui/pages/data_center_screen.dart`、`lib/ui/pages/mock_center_screen.dart`、`lib/ui/pages/profile_screen.dart` 的冻结基线；U0 只记录现状，不改动任何代码）。

主导航为 4 tab：

| Tab | 页面 | 现状能力 |
|---|---|---|
| 今日面板 | `HomePage` | 当前题库卡片（切换/修改选择题库 → PlanConfigScreen）、今日训练（开始今日训练、新题挑战、复习巩固 → 练习入口）、复习状态、任务中心入口 |
| 学科库 | `DataCenterScreen` | Subject/Folder 树（“学科树”）、新建学科文件夹、搜索学科/题库、题库浏览（点击题库 → BankDetailScreen）、长按移动归类题库、FAB“导入题库” → ImportSettingsScreen |
| 模考中心 | `MockCenterScreen` | 试卷列表（未开始/批改中/已出分）、AI 魔法组卷、经典随机抽卷 → 模考配置/考场/解析 |
| 我的 | `ProfileScreen` | 学习记录（错题记录 → WrongBookPage）、AI 与知识库（我的知识库 → KnowledgeBaseScreen、AI 服务 → AiSettingsScreen）、设置与数据（外观设置） |

关键现状语义：

- 今日训练/复习入口位于“今日面板”，依赖当前选择题库。
- “学科库”是题库组织与浏览的主入口：Subject/Folder 树（bank_folders/custom_folders 兼容体系）承担题库分组；“导入题库”从学科库 FAB 发起，进入 ImportSettingsScreen 完成文件选择与导入。
- “模考中心”承担模考创建、进行、批改与解析。
- “我的”承担错题、知识库、AI 服务与设置等个人/维护入口。
- 当前不存在 Project 概念，也不存在 File Library 概念；文件通过导入流程直接进入题库。

## 3. Target IA

U1 目标主导航为 4 tab：

**今日 / 项目 / 模考 / 我的**

- 今日：训练与复习的日常入口，沿用今日训练/复习职责。
- 项目：主要组织入口。Project 成为可选的长期学习上下文；创建/打开 Project、浏览 Project 引用的文件与题库均以“项目”为未来主入口。学科库的 Subject/Folder compatibility 浏览保留在可访问位置（具体承载位置由 U1 决定；本文件只冻结“必须保留可访问”这一约束）。
- 模考：沿用模考中心职责。
- 我的：沿用个人与设置职责（错题记录、我的知识库、设置等）。

学科库迁移说明：U1 中“学科库”不再担任主导航 tab；其 Subject/Folder 树、题库浏览、新建学科文件夹、移动归类等兼容能力迁移到保留位置，继续服务未使用 Project 的用户与既有数据。Project 成为主要组织入口，但不强制任何用户使用。

## 4. Primary navigation contract

CURRENT → U1 TARGET 映射：

| CURRENT | U1 TARGET | 迁移语义 |
|---|---|---|
| 今日面板 | 今日 | 训练/复习入口责任不变 |
| 学科库 | 项目 | 主导航角色由 Project 接管；Subject/Folder compatibility 保留在可访问位置 |
| 模考中心 | 模考 | 职责不变 |
| 我的 | 我的 | 职责不变 |

各 tab 责任：

- 今日：今日训练、复习巩固、当前学习上下文摘要等日常入口。
- 项目：Project 组织入口（创建/打开 Project、查看 Project 引用的 LibraryFile 与 QuestionBank），并承载学科库兼容位（Subject/Folder 浏览仍可访问）。
- 模考：模考中心。
- 我的：错题记录、我的知识库、设置等个人入口。

兼容约束：

- Subject/Folder compatibility 在任何新导航下都必须可访问，不得因迁移而丢失既有能力。
- 导航迁移不得要求用户先创建 Project（project = null 合法）。
- U0 只冻结上述契约；tab 图标、布局、文案等 UI 细节留给 U1 决策。

## 5. Project / File / Bank conceptual relationship

对齐 ADR-002 三层生命周期：

```text
LibraryFile（原始文件 + 持久 managed-storage 身份）
  -> ParsedArtifact / SourceDocument（可再生的解析/OCR 派生结构）
  -> QuestionDraftV2 -> Review -> PersistedQuestion（确认的学习数据）
```

- **Project 定位**：可选（optional）的长期学习上下文/组织层。它不是 QuestionBank 替代品、不是 File owner、不是强制文件夹、不是 OCR cache、不是 RAG knowledge base。
- **File Library 定位**：external file → File Library → optional Project reference → optional downstream actions（Import / P6 / Agent analysis / RAG 为未来动作，U0 不实现）。File Library 不是 Project 私有文件夹。
- **QuestionBank 定位**：继续是正式学习资产。Project 引用 Bank（reference）而非拥有/复制 Bank；bank_folders/Subject 体系保留 compatibility responsibility。U0 不规划物理删除；删除/替换 ParsedArtifact 不得删除已确认题目与复习状态（ADR-002）。
- **J0 关系形状**：

```text
Project
  <- project_files -> LibraryFile
  <- project_banks -> QuestionBank identity
```

- 一个 LibraryFile 可被多个 Project 引用而不复制字节；不得把 `library_files.project_id` 作为唯一归属关系。
- `project_banks` 需要稳定的 bank identity，该决策留给 J0-P0（bank_registry/bankId 不在 U0 决定）。

## 6. Unclassified assets UX

- `project = null` 合法：不创建 Project 也能导入文件、使用 QuestionBank、开始训练、进入模考。
- LibraryFile 未归类语义：文件可存在于 File Library 而不属于任何 Project、不被解析、不被导入。
- QuestionBank 未归类语义：题库可暂时不属于任何 Project，继续由 bank_folders/Subject 体系组织。
- 任何入口不得以“先建 Project”作为导入/学习的前置条件。
- 未归类资产在 U1 中应可被识别为“未归类”而非错误状态；具体视觉表达由 U1 决定。

## 7. Entry-point ownership

冻结以下动作的未来主要入口责任（只定义入口与归属，不写业务代码）：

| 动作 | 主入口 | 归属层级 | 未来兼容说明 |
|---|---|---|---|
| 添加原始文件 | File Library 入口（F0 起） | File Library（应用层） | 现状经“学科库 → 导入题库”进入；F0 后由 File Library 承担原始文件入口 |
| 浏览 File Library | File Library 入口（F0 起） | File Library（应用层） | U0 不实现；U1 在导航中给出可访问位置 |
| 创建 Project | “项目”tab（U1） | Project（应用层） | U0 不实现；J0 提供领域与持久化 |
| 打开 Project | “项目”tab（U1） | Project（应用层） | 同上 |
| 查看 QuestionBank | 学科库兼容位（Subject/Folder 树） | QuestionBank（应用层） | U1 后仍可经兼容位进入；Project 内 bank 引用是补充入口 |
| 从文件发起题目导入 | LibraryFile 下游动作（F0 seam） | File Library → 导入流程 | 现状经学科库 FAB 发起；未来从文件发起，现状路径在 U1 接线前保持兼容 |
| 开始训练 | “今日”tab | 训练/复习（应用层） | 责任不变 |
| 查看错题 | “我的”tab → 错题记录 | 我的（个人入口） | 责任不变 |
| 模考 | “模考”tab | 模考中心 | 责任不变 |
| 后续 Agent | 入口位置未来决定 | 应用层工具/查询层（ADR-001/003 peer adapter） | U0 只冻结 Agent 与应用层复用边界，不冻结 UI 入口；MCP v0 只读契约不变 |

## 8. Legacy Subject / Folder compatibility

- 保留，不提前退休：Subject/Folder 体系继续是题库浏览与组织的正式兼容能力，直到单独授权的迁移。
- bank_folders/custom_folders 责任：继续承担题库分组、新建学科文件夹、移动归类等既有行为；U1 导航迁移不得改变这些数据与行为语义。
- 现有 subject/folder 数据保留（N0 J0 规则：existing subject/folder data is retained until a separately authorized migration）。
- 未归类（不属于任何 Project）的题库仍由 Subject/Folder 体系组织，二者并存不冲突。

## 9. U1 implementation requirements

U1 实施合同的 IA 级要求（不包含 UI 细节决策）：

1. 主导航迁移为 今日/项目/模考/我的。
2. “学科库”兼容位保持可访问：Subject/Folder 树浏览、题库浏览、新建学科文件夹、移动归类等既有能力不因迁移丢失。
3. 入口接线：创建/打开 Project 挂接“项目”tab；F0 后 File Library 浏览入口与“从文件导入”下游动作完成接线；今日 tab 保持训练/复习入口；我的 tab 保持错题/知识库/设置入口。
4. 兼容面保留：bank_folders/custom_folders 行为不变；无 Project 用户（project = null）的导入/训练/模考全流程可用。
5. 未归类资产可被识别，不得要求先建 Project。
6. 导航迁移本身不得引入 schema/依赖变更（除 F0/J0 已批准项）。

## 10. Explicit non-goals

U0 明确不实现：

- fake Project、Project domain、repository、schema、File Library、UI placeholder；
- 任何 F0/J0/U1 生产代码；
- 不修改 ARCHITECTURE.md、AGENTS.md、N0 roadmap、ADR-001/002/003、mcp-v0-contract.md；
- 不退休 Subject/Folder；不改 schema；
- 不发明 bank_registry/bankId（留给 J0-P0）；
- 不做 UI redesign；不改 main.dart / navigation / database_helper / pubspec（shared hotspot 在 U0 零改动）。

## 11. Acceptance checklist

- [ ] 本文件为唯一 deliverable，diff 仅含 `docs/product/u0-information-architecture.md`
- [ ] 12 节齐全
- [ ] A–F 冻结语义逐条写入且与 N0/ADR-002 措辞一致（Project optional、引用而非拥有、unclassified 合法、Subject 兼容保留）
- [ ] 未发明新架构对象，bank identity 明确留给 J0-P0
- [ ] 无实现代码
- [ ] 未修改任何现有文件
- [ ] `git diff --check` 通过

## 12. Integration notes for F0/J0/U1

- **F0 seam**：LibraryFile 与 File Library 入口。F0 建立 external file → File Library → LibraryFile 生命周期；入口责任见第 7 节。
- **J0 seam**：project_files/project_banks 与 unclassified 语义。J0 实现 Project 可选、引用而非拥有、project = null 合法；bank identity 待 J0-P0。
- **U1 seam**：导航迁移与学科库兼容位。U1 将“项目”接入主导航并保留 Subject/Folder 可访问位置；见第 4、9 节。
- **shared hotspot 声明**：main.dart / navigation / database_helper / pubspec 在 U0 零改动（本阶段无任何代码或配置变更）。
