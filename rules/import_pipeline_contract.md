# Shiroha Quiz 导入管线中间数据合同契约 (Phase 4-D)

本文档定义了导入管线中，从文件适配器（Adapter）到大模型解析及合并的中间数据合同契约。本契约为 Phase 4-E / 4-F / 4-G 的基础规范，后续的格式优化与解析算法必须完全对齐此契约。

---

## 一、核心契约定义

### 1. ParsedDocument 合同
`ParsedDocument` 是 Adapter 输出的标准化文档实体，是管线的输入地基。

| 字段 | 类型 | 说明 / 契约约束 |
| :--- | :--- | :--- |
| `sourceName` | `String` | 必须是用户可识别的文件名或来源名。不允许为空字符串。Zip 内部子文档 diagnostics 可以使用内部文件名，但顶层 `ParsedDocument.sourceName` 必须是 Zip 文件名。 |
| `format` | `ImportFormat` | 必须反映入口格式：txt / md / docx / zip / pdf / image / unknown。Zip 解析出的顶层结果必须保留 `ImportFormat.zip`，不能因为内部是 Markdown 就改成 `md`。 |
| `parts` | `List<DocumentPart>` | 文档按阅读顺序展开后的结构化片段。必须按 `order` 升序排列。`order` 必须稳定、可比较，不要求连续，但在同一 `ParsedDocument` 内不应乱序。不允许出现没有意义的空 `TextPart`。Adapter 失败时允许 parts 为空，但必须 `fallbackUsed = true` 且 `diagnostics` 写明原因。 |
| `signals` | `DocumentSignals` | 从 `parts` / `imageAssets` 推导出的弱结构信号。不应该手写成与内容矛盾的值。`imageCount` 应与可登记的图片资产/图片引用数量一致。`tableCount` 应与 `TablePart` 数量一致，除非 Adapter 明确 diagnostics 说明无法保留表格结构。 |
| `fallbackUsed` | `bool` | `false`：Adapter 成功走结构化解析；`true`：Adapter 发生降级（如异常、空内容、格式不支持、只能读出纯文本）。当其为 `true` 时必须在 `diagnostics['warning']` 或等价 warning 信息中说明原因。 |
| `diagnostics` | `Map<String, dynamic>` | 只放“解析过程事实”，不放最终题目业务判断。例如：图片丢失、路径非法、结构信号弱、fallback 原因、Zip 内部文件解析摘要。不允许吞异常后只返回空文档。 |
| `imageAssets` | `List<DocumentImageAsset>` | 可供 Mixed Vision 使用的图片资产登记表。 |

---

### 2. DocumentPart 合同
`DocumentPart` 代表文档中的各种片段内容。

#### TextPart
保存普通文本、标题、答案区、疑似公式文本。
- `text.trim()` 不应为空。
- `role` 只能表达文本角色（`paragraph`, `heading`, `tableCell`, `formulaLike`, `answerBlock`），不能表达题目类型。
- 禁止在 Adapter 层把题目解析成 `standard_answer` 等最终题目字段。

#### TablePart
保存表格原始行列。
- `rows` 不应为空，且每行至少有一个非空单元格。
- 行顺序必须保留。
- 单元格文本应 `trim()`，但不要擅自删除用户内容。
- 如果表格无法结构化，才允许降级为 `TextPart(role: tableCell)` 或普通段落，并写 `diagnostics`。

#### ImagePart
表示文档中的图片占位位置。
- `path` 是原始引用或关系路径。
- `assetId` 如果存在，必须能在 `imageAssets` 找到同 `id`。
- `resolvedPath` 如果存在，必须指向提取后的本地文件。
- `order` 决定图片在 `toPlainTextForParsing()` 中出现的位置。

---

### 3. DocumentSignals 合同
`DocumentSignals` 用于量化文档内包含的弱结构特征。

| 字段 | 说明 / 契约约束 |
| :--- | :--- |
| `questionMarkerCount` | 题号、编号、明显题干标记数量。不代表最终题目数量。 |
| `answerMarkerCount` | 答案区、答案行、参考答案标记数量。不代表最终答案数量。 |
| `imageCount` | 图片引用/资产数量。用来判断是否需要 Mixed Vision。 |
| `tableCount` | 表格数量。用来判断 Word / Markdown / Zip 是否存在结构化表格风险。 |
| `formulaLikeCount` | 疑似 LaTeX 或数学公式片段数量。不负责修复公式，只负责给后续 repair 层提供风险信号。 |
| `hasTailAnswerBlock` | 文档尾部存在集中答案区。后续融合层可以把它视为 answer-only 来源风险。 |
| `hasInlineAnswers` | 题干附近存在内联答案。只作为信号，不直接覆盖最终答案字段。 |

**行为契约**：
- 数值累加：`signalsA + signalsB` 应将各个 `int` 字段数值相加。
- 布尔合并：`signalsA + signalsB` 的布尔值必须通过 `||` (OR) 进行合并。
- 字段名稳定性：`toMap()` 导出的字段名必须与上述字段完全一致，以防止后续 UI/diagnostics 读取断裂。

---

### 4. DocumentImageAsset 合同
`DocumentImageAsset` 登记了文档解压/解析中抽取的图片资源。

- `id`：必须唯一。
- `order`：必须对应图片在文档中的阅读顺序。
- `sourceName`：必须能追溯到原始文件或 Zip 内部文件。
- `isResolvable` 为 `true` 时，必须有可用 `extractedPath`。
- 不可解析的图片（如外部超链接图片且无本地缓存）不能丢弃，应标记 `isResolvable = false`，并在 `originalPath` 保留来源，同时以 `diagnostics` 记录。

---

### 5. ImportParseResult 合同
`ImportParseResult` 代表导入管线最后的集成输出。

- `questions`：最终进入暂存页的题目列表（`List<Map<String, dynamic>>`）。**只能在 AI parse / fusion / repair 后产生。Adapter 不直接产生最终 questions**。
- `warnings`：用户可见的风险摘要（`List<String>`）。例如：答案冲突、图片跳过、结构信号弱、Vision 部分失败。文案应尽量短，适合传输中心/暂存页展示。
- `diagnostics`：开发/排查用结构化事实（`Map<String, dynamic>`）。可以嵌套 Map / List。不要求全部用户可见，但关键风险必须有对应 warning。
- **失败语义**：空结果（`questions` 为空）不等于失败。失败语义由 pipeline 或 TaskManager 判定。有 diagnostics 时不应被 UI 静默吞掉。

---

## 二、边界防御清单

为了避免后续算法出现局部猜测，Adapter 及融合层必须在以下边界中坚守契约：

1. **空文件**：允许 parts 为空，但必须 `fallbackUsed = true` 并记录 `diagnostics` 异常事实，不能吞掉报错。
2. **弱结构文件**：解析不报错，记录 `questionMarkerCount` 低或为 0。
3. **图片缺失**：不丢原始引用（`ImagePart` 仍然保留），将 `imageAssets` 中的对应资产标记为 `isResolvable = false` 并记录在 `unresolvedImages`。
4. **Zip 非法路径 (Zip Slip)**：如果 Zip 内部存在目录逃逸路径（例如 `../../etc/passwd`），拒绝解析，抛出异常或记录在 warning 中。
5. **表格不规则**：保留行列文本，不强行猜题，通过 `TablePart` 原样输出。
6. **AI 占位答案**：任何形如 "无", "未提供", "未见答案", "暂无" 的占位答案，在 `QuestionFragment` 的推导中必须判定为 `hasAnswer = false`，不得视为真实有效答案。
7. **Orphan Fragment**：无匹配题号的孤立片段不得丢弃，必须保留并在 `QuestionFusionService` 中以 orphan 种类追加至结果尾部。
8. **Fallback 可追踪性**：当 `fallbackUsed == true` 时，必须能在 `diagnostics` 中明确追溯到降级的具体原因（如格式不支持、解密失败、内容损坏等）。

---

## 三、Fixture 矩阵设计

本阶段（4-D）建立 Fixture 目录矩阵并提供最小可用样例，供后续 4-E / 4-F / 4-G 进行全链路文件与算法测试。

| fixture 路径 | 阶段 | 目的 | 期望解析结果 |
| :--- | :--- | :--- | :--- |
| `test/fixtures/import_pipeline/txt/simple_questions.txt` | 4-D/4-E | 验证基础文本导入、题号和答案标记识别 | `signals` 包含 question/answer marker |
| `test/fixtures/import_pipeline/txt/tail_answers.txt` | 4-E | 验证尾部集中答案区识别 | `hasTailAnswerBlock = true` |
| `test/fixtures/import_pipeline/markdown/with_local_image.md` | 4-D/4-E | 验证 Markdown 中相对路径图片的占位及可解析 | `imageAssets` 存在且 `isResolvable = true` |
| `test/fixtures/import_pipeline/markdown/missing_image.md` | 4-E | 验证 Markdown 中缺失图片的占位及标记未解析 | `diagnostics` 有 `unresolved` 记录 |
| `test/fixtures/import_pipeline/markdown/path_traversal.md` | 4-E | 验证路径越界防御限制 | `warnings` 记录拒绝，拒绝解析逃逸路径 |
| `test/fixtures/import_pipeline/zip/md_plus_images.zip` | 4-E | 验证 Zip 内 Markdown + 图片的解压和资产挂载 | `imageAssets` 成功解压并登记 |
| `test/fixtures/import_pipeline/zip/images_only.zip` | 4-E | 验证纯图片 Zip 包解析降级与 Mixed Vision 提示 | `fallbackUsed = true` 且 warning 提示需要 Vision |
| `test/fixtures/import_pipeline/docx/paragraph_table_image.docx` | 4-E | 验证 Word 段落、表格与图片的阅读顺序及稳定性 | `parts` 顺序稳定且类型正确 |
| `test/fixtures/import_pipeline/docx/weak_structure.docx` | 4-E | 验证结构极弱的 Word 文档导入 | `warnings` 提示结构信号弱 |
| `test/fixtures/import_pipeline/vision/pdf_pages.pdf` | 4-G | 验证 PDF 视觉分批次按页解析 | 批次顺序稳定，无乱序 |
