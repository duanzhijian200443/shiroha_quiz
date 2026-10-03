# Shiroha Quiz Implementation Planning Freeze V3

**契约标识：SHIROHA-HOME-TRAINING-IPF-V3**
**冻结日期：2026-10-03**
**状态：产品与实施规划已冻结；尚未实施。**
**替代关系：完整替代本专项 V2、V1，以及此前针对本专项的候选分析与修订建议。**

本契约冻结训练内容配置、今日首页 v2、真实学习时长和解析任务页面的实施依据。后续 Agent 不得自行改变本文定义的产品语义、状态 authority、生命周期、迁移、架构边界或交付顺序。

本 V3 是对 V2 的精度修订，不重新扩大产品范围。保存本规划不代表目标能力已经成为当前运行事实。

---

# 1. 权威、范围与已确认决策

## 1.1 唯一施工入口

本专项使用两个文件：

- 契约正文：docs/product/home-training-implementation-freeze-v3.md
- 执行附录：docs/agents/home-training-v3-execution-plan.md

契约正文是本专项唯一产品、架构和生命周期施工入口。执行附录只记录当前基线、PR/任务拆分、文件 ownership、worktree、Git authority、验证与交付操作，不得重新定义产品语义、authority、状态机或迁移行为。

权威顺序：

1. 平台要求、用户明确指令、AGENTS.md；
2. ARCHITECTURE.md 及未被本轮正式 amendment 改变的 focused canonical contracts；
3. 本 V3 对本轮目标行为的明确冻结；
4. 本轮执行附录；
5. Drive 原始任务文档和设计图；
6. 历史方案、聊天记录、V1/V2、外部审阅建议。

本 V3 是待实施目标契约。保存本规划不代表 v29～v31 已存在，不代表新页面已经实现，不代表生产入口已经激活，也不代表 runtime 验收已经完成。

实施状态 amendment（P1c）：P1a Domain 和 P1b Application contracts 已存在，runtime schema 已升级为 v29；TrainingContent 三表、一次性旧 current bank seed 和 B0 INCLUDE / staged validation 已实现。v30 / v31、配置 CRUD、binding lifecycle、Home/Today 新入口、训练启动和 Activity / TaskCenter runtime 仍待实施。本 amendment 不宣称这些功能已经 production-activated。

实施状态 amendment（P2a）：真实只读 TrainingCatalog、TrainingContent Query/Command、配置 CRUD、current selection 和 Category Visual preference CAS 已实现，继续使用 v29 schema 和单一数据库 eligibility adapter。Application 负责 captured catalog 的 usability 与 deterministic runtime fallback；query 不写回 fallback，也不持久化 binding invalidation。配置 mutation 在同一事务内重验并原子提交，content 与 preference revision 独立。P2b invalidation/rebind、Home/配置 UI、新训练启动与后续 runtime 接入仍待实施，当前生产入口未因此激活。

如发现本文与更高层 canonical contract 存在未明确处理的实质冲突，停止受影响任务并报告冲突。不得自行选边、降级、扩大范围或通过“兼容实现”绕过冲突。

## 1.2 本轮包含

- 沿用现有题库分类的 TrainingContent 配置体系；
- 单题库与同分类多题库融合的新题训练；
- 按分类构建统一到期复习池；
- 今日首页 v2 的 Category 横滑、当前 TrainingContent、翻页角和 Category Visual；
- 新题/复习独立入口；
- 真实学习时长、本周学习天数和轻量学习日历；
- 解析任务页面视觉重构；
- TaskCenter Application facade；
- ImportTask 当前 attempt 事件时间；
- 成功解析记录精确清理；
- 为上述能力必需的 additive schema、migration、B0 兼容与 focused regression；
- 替代能力完整可达后退休旧普通训练配置页面。

## 1.3 本轮排除

- StudyPlan 多计划创建、切换、管理、持久化模型和迁移；
- 稳定 bankId、bank registry、题库重命名；
- 新建第二套 Category 或题目 taxonomy；
- 题库 Category rename；
- TrainingContent 跨 Category 融合或直接迁移；
- 新增独立题目作答/解析详情页；
- 为第五种计时场景新增页面；
- AI 自动生成 Category Visual；
- 番茄钟、手动计时、idle 检测、后台计时宽限；
- 助手聊天、文件阅读、OCR/解析处理耗时计入学习时长；
- 复杂统计 Dashboard、独立统计详情页；
- FSRS 算法、Review 评分、AnswerAttempt authority、typed content authority 改造；
- OCR 核心、Provider、Agent/MCP 新工具或写权限扩展；
- P6 恢复、P7 扩展及其他延期能力。

## 1.4 StudyPlan 边界

StudyPlan 继续维持全局单一活动计划。

- 首页最多展示一个真实 ActiveStudyPlan，并保留“查看计划”；
- 无计划时保留真实空状态与既有助手制定计划入口；
- draft/adopt/replace/stop/CAS、candidate selection 和 focused attribution 保持既有契约；
- TrainingContent 不读写 study_plans；
- TrainingContent 的切换、题量和权重不改变 StudyPlan；
- StudyPlan.dailyTarget 不作为 TrainingContent.questionLimit；
- Category/TrainingContent 切换不改变计划题库；
- 不生成虚构计划名称、进度或完成百分比；
- 多计划能力另立独立阶段。

TrainingContent 是普通训练范围配置，不属于 StudyPlan 多计划能力。

## 1.5 V3 对 V2 的明确修订

V2 其他产品与架构冻结继续有效。V3 新增或修订：

| 项目 | V3 冻结 |
|---|---|
| StudyActivity lifecycle | 明确 status × endReason × endedAt 合法矩阵 |
| route 生命周期 | temporary cover/background → pause；真正 pop/replace/owner release → end |
| current content restore | preference 可指向仍存在、同 Category 但当前 unavailable 的 TrainingContent |
| current category restore | structurally valid 但当前不可展示的 CategoryKey 不因 runtime fallback 成为损坏数据 |
| ordinary bank eligibility | 引入单一 OrdinaryTrainingBankEligibility authority |
| retry file selection | 显式文件选择为 ephemeral command/composition handoff，不进入 TaskCenter read DTO 或持久 snapshot |
| P8 并行 | 只有达到各自执行附录开始条件后，P8a/P8b 才可彼此并行 |

继续保留 V2 核心决策：结构化 CategoryKey、继续使用 bankName、不引入 stable bankId、binding 持久 invalidation、同名题库重建不自动恢复、0% 不抽新题且不参与不足回填、只迁移旧 current bank、Category Visual 属于 Category、read fallback 不隐式持久化、injectable RNG bounded sampling、StudyActivitySession 命名、第五场景不在本轮激活、fixture-driven Presentation 可提前并行、schema/B0/composition 按 writer ownership 串行、TaskCenter 最终只消费 Application facade。

---

# 2. 来源覆盖与冲突裁决

## 2.1 Drive 设计来源

来源目录：UI设计 / 手机端UI / 今日。

| 任务文档 | 对应设计图 | 本契约采用方式 |
|---|---|---|
| 训练内容配置_UI任务.md | 训练内容配置_UI.png | TrainingContent、权重、分类复习池、临时队列 |
| 今日首页重构_v2_UI任务.md | 今日首页重构_v2_UI.png | 分类卡、翻页角、Category Visual、真实时长 |
| 今日首页重构_UI任务.md | 今日首页重构_UI.png | 总体信息架构、周视图和既有首页节奏 |
| 解析任务_UI任务.md | 解析任务_UI.png | TaskCenter 四状态、事件时间、操作和视觉 |

设计图中的名称、数字、日期、比例、计划卡和示例进度均为设计样例。生产 runtime 必须使用真实数据，不得将图中样例写死。

## 2.2 冲突裁决

| 冲突 | V3 冻结 |
|---|---|
| 首页 v2 曾把复习数量绑定 TrainingContent | 复习按 Category 全池 |
| 旧首页图存在多个计划 | 只保留单一 ActiveStudyPlan |
| 早期建议 bankId/独立 Category id | 本轮继续 bankName + 现有 folder，不新增 registry |
| 编辑器出现 Visual | Visual 是 Category preference，不属于单个 content |
| “做过”与 NEW 混淆 | NEW 退出继续由 ReviewState/FSRS 评分决定 |
| 五类学习场景 | 本轮真正接入四类，第五类不新增入口 |
| 旧首页暂缓学习时长 | 本轮在独立 durable authority 落地后激活 |
| TaskCenter 文档说不改业务 | 保留既有业务 authority，只增加事件时间与 facade |
| retry 可能需要文件 path | 文件选择只允许 ephemeral handoff，不进入 read/persisted DTO |

## 2.3 当前实现认知

规划时已知 master 已有统一今日首页、今日/助手/我的一级导航、普通新题与到期复习入口、StudySessionLauncher、typed-aware prepared queue、单一 ActiveStudyPlan、当前 Practice UI、AnswerAttempt、FSRS grading/requeue/preview、四状态 TaskCenter、ImportTask attempt 状态、v28 schema、ImportedQuestionSet 与 B0。

尚未完整具备：TrainingContent persistence、多题库融合、weighted new selection、Category review pool、Category 横滑与翻页角、Category Visual preference、durable StudyActivity、真实本周学习时长、attempt_started_at/parsed_at/failed_at、成功任务精确清理、完整 TaskCenter Application facade。

已知危险边界：

- getSubjectTree() 含副作用，不得作为新纯查询；
- 当前 completed cleanup 还包含 error，不能直接复用；
- 当前题目列表不存在可直接复用的独立学习详情页；
- B0 文档部分 current-state 描述滞后于实际 v28 runtime。

这些信息只是规划依据，不代表已重新执行测试或完成 runtime 验收。正式开工必须重新核验。

---

# 3. 产品对象、身份与状态 Authority

## 3.1 唯一对象关系

现有题库 Folder → Category → 一个或多个 TrainingContent → 一个或多个真实 bankName。

Question.storageId 继续拥有唯一 typed/legacy 内容 authority、唯一 ReviewState/FSRS 状态，以及既有 AnswerAttempt/ReviewLog 历史。

TrainingContent 只负责范围、名称、题量、权重与顺序，不拥有 Question、ReviewState、FSRS、AnswerAttempt、ReviewLog 或永久练习队列。

禁止复制 Question、创建 TrainingContent-local ReviewState/NEW flag、在 Question/ReviewState 中加入 TrainingContent 归属、持久化每个 TrainingContent 的预抽题队列，或删除 TrainingContent 时删除学习事实。

## 3.2 CategoryKey

Category 沿用现有真实题库 folder，不创建 Category registry。

Domain 值：

- FolderCategoryKey(exactFolderName)
- UncategorizedCategoryKey

canonical persistence encoding：

- real folder：["folder", exactFolderName]
- uncategorized：["uncategorized"]

要求：

- exact folder name 保留原 Unicode 与大小写；
- 不用 emoji、UI 展示文案、visual key 或关键词匹配结果作 identity；
- 无 bank_folders 映射的真实普通训练题库属于 UncategorizedCategoryKey；
- “默认学科”若为真实 folder，就是普通 FolderCategoryKey；
- 即使真实 folder 名为“📁 未分类题库”，也必须与系统 sentinel 区分；
- 非法 CategoryKey 返回 safe unavailable，不通过 read 自动修复；
- File Library Folder 与题库 Category 不得混用。

本轮不新增 Category rename。

## 3.3 真实题库身份

TrainingContent member 继续引用真实 bankName。

- exact lookup；
- 不自动 rename，不猜 rename；
- 不通过显示名、TrainingContent name 或 folder name 反查 bank；
- 不引入 stable bankId、generation id 或 bank registry；
- bankName 是当前兼容查找键，不宣称为永久实体 identity。

## 3.3.1 OrdinaryTrainingBankEligibility

V3 冻结单一产品/Application 概念 OrdinaryTrainingBankEligibility，用于回答某个当前存在的 bank 是否允许进入普通训练体系。

它是以下能力的唯一 eligibility authority：

- TrainingCatalog；
- TrainingContent selector；
- v29 seed；
- TrainingContent admission；
- same-category member validation；
- Category review pool；
- Home Category catalog；
- Home TrainingContent counts；
- new-question candidate bank set。

禁止调用方各自维护特殊 bank 排除逻辑。

要求：

1. 只使用既有明确 bank authority/reserved identity/visibility policy；
2. 不根据任意 emoji 前缀或用户可自由输入名称关键词推断；
3. 全局错题本不可作为 ordinary bank；
4. 模考专属隐藏 bank 不可作为 ordinary bank；
5. 其他既有明确非普通训练 bank 按当前 canonical policy 排除；
6. 真实用户普通题库才可 eligible；
7. Eligibility 查询只读，不创建 ReviewState、不修改 folder、不自愈 legacy 数据；
8. 同一个 captured catalog snapshot 中，同一 bank 只有一个确定结果。

CP1 必须冻结 Application-facing contract。Infrastructure adapter 负责消费已有 visibility/reserved identity authority。若当前规则分散，本轮只允许通过 adapter 收敛读判定，不借机新建 bank registry。

## 3.4 TrainingContent

字段：

| 字段 | 语义 |
|---|---|
| contentId | opaque unique id |
| categoryKey | 所属 Category |
| name | trim 后非空用户名称 |
| questionLimit | 本次新题初始题量，1～100 |
| sortOrder | Category 内顺序 |
| revision | CAS revision |
| members | 有序 member bindings |

TrainingContent name 可重复，identity 由 contentId 决定。同一 bank 可被多个 TrainingContent 引用。

既有 TrainingContent 不通过普通 edit 直接跨 Category 迁移。需要另一 Category 下配置时新建，原配置由用户决定是否删除。

## 3.5 Member Binding

每个成员保存 bankName、weightPercent、position、bindingStatus 和 nullable safe invalidationReason。

bindingStatus：

- valid
- invalidated

可用 TrainingContent 必须同时满足：

1. 至少一个 member；
2. member bankName 唯一；
3. position 唯一；
4. weight 为整数 0～100；
5. weight sum = 100；
6. 至少一个成员 weight > 0；
7. 所有 bindingStatus = valid；
8. 所有成员 bank 当前真实存在；
9. 所有成员满足 OrdinaryTrainingBankEligibility；
10. 所有成员当前仍属于 content.categoryKey。

任意 member invalidated，整个 TrainingContent unavailable。禁止自动删坏 member、设为 0%、重新配权、用剩余 member 开练、自动换同名 bank 或自动跨 Category 修复。

## 3.6 持久失效与 Rebind

下列已经成功提交的 durable 变化必须 invalidated 相关 binding：

- 删除整个 bank；
- 删除 bank 内最后一道题；
- 最后一道题被迁出原 bank；
- bank 被移到其他 Category；
- clear-all questions 导致 bank 不再存在；
- 其他既有 durable mutation 导致 bank 不存在、不再 ordinary eligible 或 category 与 content 不一致。

规则：

- invalidation 与造成变化的 durable mutation 同事务；
- 只根据事务最终状态决定，不根据逐行中间态；
- 临时 delete→replace 且最终 bank 仍合法同 Category，不误 invalidated；
- invalidation 时对应 TrainingContent revision +1；
- 同名 bank 重建或移回原 Category，旧 binding 仍 invalidated；
- query/startup/migration 均不得自动恢复。

恢复必须来自用户显式 rebind，并重新读取 TrainingCatalog、校验 eligibility/category/expected revision，再原子更新 binding 与 revision。

本轮使用 transaction-final-state binding validation helper，不用逐行 delete trigger 判断“最后一道题”。这是 TrainingContent relation lifecycle，不是 stable bank identity。

---

# 4. 配置、选择与比例

## 4.1 页面职责

交付：

1. 分类分组的 TrainingContent 列表；
2. 创建/编辑共用的真实题库多选器；
3. TrainingContent 编辑器。

列表支持查看、新增、编辑、设为当前、简单顺序调整、显示并修复 invalidated 配置。失效配置不隐藏、不自动删除、不进入首页快速 content cycle。空 Category 可进入选择器。不做复杂 drag reorder 或 TrainingContent nesting。

选择器只展示属于当前 Category 且 OrdinaryTrainingBankEligibility == eligible 的真实题库，支持多选、已选数量、编辑时恢复 selection 与 invalidated member 修复上下文。

编辑器包含名称、关联题库、1～100 Slider、−/+ 微调、多题库比例、环形总览、每 bank 比例滑块、预计理想 quota、上移/下移、删除 content。

返回/取消只丢弃 draft，不产生 durable write。删除提示必须明确只删除训练配置，不影响题库、Question、ReviewState、AnswerAttempt、ReviewLog 或学习时长历史。

## 4.2 Category Visual

Visual 只属于 Category。

v0 preset：math、english、computerScience、genericLearning。

无显式设置时可根据 Category display name 提供默认建议；关键词只影响建议，不改变 identity。持久化有限 visualKey，不持久化 absolute path、remote URL、Base64、model prompt 或 AI image result。

TrainingContent 不拥有独立 Hero Visual。若编辑器提供 Visual 控件，必须明确“修改分类视觉，将应用于该分类全部训练内容”。

Visual/current-content preference 使用独立 revision；Visual update 不增加 TrainingContent revision。

## 4.3 当前 Category 与当前 TrainingContent

持久化：

- 一个全局 currentCategoryKey；
- 每 Category 一个 nullable currentContentId。

Runtime：

1. persisted Category 当前可展示则使用；
2. 否则 deterministic fallback 到目录首个可展示 Category；
3. 当前 content 存在、属于当前 Category 且 usable，则使用；
4. 否则按 (sortOrder, contentId) 选首个 usable content；
5. 没有 usable content，显示 unconfigured/unavailable。

Category 固定排序：real folder name deterministic order，uncategorized 置末，CategoryKey 最终 tie-break。

首页 Category 范围：含至少一个 ordinary eligible real bank，或仍有 TrainingContent 配置。仅空 custom folder 且无 content 时只留在配置界面。

read fallback 不隐式持久化。

合法 persisted state 可以是：preference.currentContentId 指向仍存在且同 Category 的 A，但 A 因 invalidated member 当前 unavailable；runtime 可临时展示 B，数据库仍保留 A。Availability 不属于 preference referential validity。只有 content 不存在、contentId malformed 或跨 Category 才是非法 currentContent reference。

同理，currentCategoryKey 只要编码合法，即使当前 runtime catalog 不再展示该 Category，也不因 fallback 自动成为损坏 persisted data。运行时 fallback，查询不得改写设置。

显式选择保存成功后才发布新 context；失败保留旧 selection。删除 content 可在同一 mutation 中清理指向该 content 的 preference。快速连续切换由 Application 串行，Presentation latest-wins。

## 4.4 比例

所有 weight 为整数百分比，总和 100。

- 单成员固定 100%；
- 初次多选等分；
- 调整 i 为 x 后，其余按原相对比例分配 100−x；
- 其余原权重和为 0 时等分；
- 整数化用 Largest Remainder Method；
- remainder tie-break 为 position、bankName；
- 无比例锁定。

删除 member 后按剩余相对比例 normalize；若剩余全 0，等分。新增 member 后当前全部 selection 重新等分并立即展示，用户可继续调节；保存时不得隐藏再次调整。

环形图只做总览，比例编辑使用逐 bank Slider。预计题数必须与正式 quota 使用同一纯算法。

## 4.5 0% 语义

weight == 0 表示该 member 本次不参与普通新题抽取：

- initial quota = 0；
- 不计入 new pool count；
- 不参与 initial selection；
- 不参与 shortage redistribution；
- 不作为其他 bank 不足时 fallback；
- 不删除 binding，不改变学习状态或 Category membership；
- 不影响 Category review pool；
- relation-level summary 仍可包含它。

UI 提示：“0% 不参与新题抽取；分类复习仍保留。”

所有 member 都为 0 时配置无效，不能保存。

---

# 5. 新题、复习、抽样与临时队列

## 5.1 NEW Authority

唯一新题资格：ReviewState.state == 0。

必须区分 AnswerAttempt 已保存、答案已 reveal、正式 FSRS grading 已成功。只有正式 grading 更新 ReviewState 后，Question 才退出 NEW。

AnswerAttempt/reveal 后未 grade 可仍是 NEW；Again 也是正式 grade，第一次 Again 后不再 NEW。其他 TrainingContent 下次实时读取同一份 ReviewState。FSRS reset 回 state 0 后重新符合 NEW。

禁止增加 hasSeen、hasPracticed、trainingContentCompleted 或第二套 NEW flag。

## 5.2 新题范围

普通新题候选必须同时满足：

- current usable TrainingContent；
- valid member；
- weight > 0；
- bank ordinary eligible；
- bank 仍属于 content Category；
- ReviewState.state == 0。

禁止跨 Category、0% member、未选择 member、invalidated bank、虚拟错题本、hidden exam bank。

首页“新题数量”显示正权重成员范围内全部 eligible NEW 的 distinct 总数，不显示 questionLimit 或本次预计队列长度。

## 5.3 Category Review Pool

普通复习候选：

- current Category 下所有 ordinary-training eligible real banks；
- state > 0；
- next_review_time <= capturedNow；
- DISTINCT storageId。

不受 current TrainingContent、members、weights、0%、questionLimit、TrainingContent 是否 deleted、当前 Category 是否有 usable TrainingContent 影响。

排序：next_review_time ASC，然后 storageId ASC。普通 Category review 初始上限 40。state==3 只要按现有 authority 到期仍可进入复习。

StudyPlan 保持自己的 exact-order/dailyTarget 语义，不复用 Category review algorithm。

## 5.4 quota 与候选不足

L = questionLimit，只对 weight > 0 member 分配。

第一轮按 Largest Remainder 得到 targetQuota，总和 L。读取 availableNewCount，每成员 take = min(targetQuota, availableCount)。

missing 只在 weight > 0 且仍有余量的 member 中回填，继续按原正权重比例 + Largest Remainder，并受剩余 capacity 限制，可多轮，直到达到 L 或全部正权重 member 耗尽。

最终数量 = min(L, 正权重成员 eligible NEW distinct 总数)。

0% 永不参与。实际比例因候选不足可偏离设置比例；设置比例只是 target distribution。

## 5.5 有界随机选择

同一次启动的 count、window selection 与最终 materialization 所需读取应尽量来自同一个短读取 snapshot/transaction。

每个 member：

1. eligible Question 按 storageId 确定性数据库顺序；
2. 获取 eligibleCount；
3. injectable RNG 生成 startOffset ∈ [0, eligibleCount)；
4. 从 startOffset 读取所需 quota ID window；
5. 到尾不足时从头回绕；
6. 每 member 最多两段 ID window；
7. 不重复 storageId。

合并 member IDs 后 distinct，用 injectable RNG 对最终集合 shuffle，再 materialize full Question。

要求：

- full typed Question 最多 materialize 100；
- 不把候选全集题干/解析读入内存；
- 不使用候选全集 ORDER BY RANDOM()；
- 不预生成所有 TrainingContent queue；
- 不缓存长期 random queue；
- 不宣称该 window algorithm 是均匀子集抽样。

明确承认 SQL OFFSET 可能随 offset 增大产生扫描成本；bounded returned rows 不等于 constant query cost。必须用 synthetic large-bank 和 EXPLAIN QUERY PLAN 检查真实边界，仅补本专项 SQL 必需索引，不引入通用 sampling cache/index framework。

## 5.6 Typed Materialization

继续使用现有 typed-aware persisted Question authority。

candidate IDs → final ordered IDs → materialize → typed decode → prepared queue。

只有全部 ID 存在并安全 decode，才允许 replace Practice queue。任一 missing Question、required row、corrupt typed sidecar、unsafe payload 或 stale membership 都使整次启动失败。

禁止部分 queue、跳坏题、自动补替换题、V1 fallback、silent typed fallback。ready/empty/stale/unavailable 均不能留下半成品 queue。Required ReviewState 缺失返回 safe unavailable，新读路径不得自动补 ReviewState。

## 5.7 启动接口

保留既有 bank-scoped StudySessionLauncher 供未迁移调用方使用。

新增窄 Application seam：

- startNew(contentId, expectedRevision)
- startCategoryReview(categoryKey)

返回至少区分 ready、empty、staleConfiguration、unavailable。

新题启动必须重新查询 content、校验 revision/bindings/eligibility、重新读取 ReviewState、重新计算 quota 并生成 queue。Category review 捕获 current category、统一 eligibility、查询实时 due state。

成功继续使用既有 prepared queue seam。禁止通过 preview initialQuestions 实现正式训练。

普通新题/普通复习使用 normal attribution；StudyPlan 保持 focused。融合内容标题可以显示 TrainingContent.name，但每道题真实 bankName 保持真实。

## 5.8 临时队列生命周期

“进入练习时生成”定义为一次用户显式启动 Practice 的 admission workflow。允许在点击后、route transition 前做必要 preparation；禁止 Home refresh、TrainingContent 翻页、Category 横滑、App 启动时预抽，禁止为每个 content 持久缓存 queue。

一次 admission 只生成一个临时 queue。正式 Practice route 尚未成功建立时不开始 StudyActivity；preparation failure 不入场。

进入 Practice 后 queue 成为当前进程内 queue，并开始 StudyActivity。真正离开 Practice 时释放 queue；后台/system overlay 保留 queue 但 pause StudyActivity；返回同一 Practice 继续原 queue；process death 不恢复 queue。

未做到题不产生学习状态变化；已持久 AnswerAttempt/ReviewState/ReviewLog 按既有 authority 保留；Again requeue 保持原行为。初始 queue 数不等于实际访问/评分次数，禁止据此增加固定 N/M 完成 authority。

启动 guard 覆盖 preparation + Practice route lifetime；重复点击不得替换 active queue。

---

# 6. 真实学习时长契约

## 6.1 与 Practice Queue 分离

durable 学习活动为 StudyActivitySession，duration facts 为 StudyActivitySegment，Practice queue 只负责当前进程中的题目顺序和 requeue。

StudyActivity storage 禁止保存 queue IDs、Question body、answer、explanation、未完成题或 requeue list。

## 6.2 Scene

本轮接入：

- ordinaryPractice
- categoryReview
- studyPlanPractice
- mockExam

singleQuestionStudy 只保留定义，不激活。本轮不为了凑齐第五场景新增页面。

preview、import review、TaskCenter、OCR、AI processing、普通题目列表浏览、历史试卷普通查看、assistant chat、file reading 不计时。

## 6.3 唯一 Activity Owner

Application 管理唯一 active learning owner。

计时条件：app resumed，且当前 learning owner route 具备 foreground eligibility，且 session 非终态。

同一个 Practice 内 answer/reveal/explanation/grading/Again 共用同一个 activity owner，不创建嵌套 ActivitySession。

Temporary Cover：app inactive/background、system dialog/picker、temporary overlay、临时非学习 route 覆盖但原 owner 仍保留时，只 pause，不释放 queue、不结束 Session。遮盖消失回到同一 owner 时 resume。

True Exit：learning route 被 pop、replace 且旧 owner 释放、owner dispose、Practice 明确结束、queue lifecycle terminal、Exam 成功提交并退出时 checkpoint 并终止。Presentation 不得仅凭“页面一时不可见”自行判断 ended；以 owner lifecycle 是否仍存活为准。

## 6.4 StudyActivity 合法矩阵

lifecycleStatus：

- active
- paused
- ended
- interrupted

endReason：

- exited
- queueFinished
- submitted
- processInterrupted
- snapshotInterrupted

合法组合：

| lifecycleStatus | endedAt | endReason |
|---|---|---|
| active | null | null |
| paused | null | null |
| ended | non-null | exited / queueFinished / submitted |
| interrupted | non-null | processInterrupted / snapshotInterrupted |

任何其他组合均为 authoritative invalid state，包括 active+reason、paused+endedAt、ended+processInterrupted、interrupted+submitted、terminal+null endedAt 或 terminal+null reason。restore validator 必须 fail-closed。

事件：

| 事件 | 状态 |
|---|---|
| 正式学习 route admission 成功 | active |
| checkpoint | status 不变 |
| app background / temporary cover | active→paused |
| 回到同一 owner | paused→active |
| true route exit | ended/exited |
| Practice queue 正常终止 | ended/queueFinished |
| MockExam submit 成功并结束 | ended/submitted |
| submit 失败 | 不写 submitted |
| startup recovery 发现残留 | interrupted/processInterrupted |
| sanitized backup snapshot 中 active/paused | interrupted/snapshotInterrupted |

queueFinished 只描述 Practice queue lifecycle terminal，不建立“所有题学会”、TrainingContent completion、StudyPlan completion 或 FSRS completion。ended 只表示一次 ActivitySession 正常结束。

## 6.5 时钟与日期

elapsed authority 使用 monotonic clock，duration 存整数毫秒，UTC 用于事件定位，本地日期用于日历归属，并保存当时 UTC offset。不要求 IANA zone id 或新 timezone package。

跨午夜必须把实际 elapsed 按本地日界拆分。例如 23:59:50→00:00:20 的 30 秒必须拆成前一日 10 秒与后一日 20 秒。DST 使用本地真实午夜边界转 UTC，不能用当前固定 offset 推算所有日界。

系统时间/时区变化不改变 monotonic elapsed。检测到 wall-clock mapping 或 timezone mapping 变化时关闭当前 attribution，后续使用新观察 mapping；上一个 checkpoint 到变化被观测期间按上次有效 mapping 归属，不重写历史。明确承认无法精确回溯未被进程观察到的人工时区变化瞬间。

## 6.6 Checkpoint 与并发

约每 30 秒 checkpoint，并在 pause/end/interruption handling 时尝试 checkpoint。

只保存已确认 elapsed segment，不 durable 保存开放且未确认 interval。

checkpoint 原子提交；segment sequence 与 session sequence/revision 由 Application 串行管理。同 sequence 相同 payload 重放 idempotent；同 sequence 不同 payload conflict；terminal session 不允许追加。

widget dispose、lifecycle callback、route pop、submit callback、checkpoint timer 竞争时只允许一个 terminal transition，禁止 double end、double segment、double duration。不得持有贯穿整个学习页生命周期的长 DB 事务。所有 durable write 遵守既有 B0 mutation gate。

## 6.7 崩溃与失败

下次启动发现 active/paused 残留 Session：不恢复 queue/owner、不补宕机时间，以最后成功 checkpoint 为边界，收尾为 interrupted/processInterrupted；恢复幂等。

正常 checkpoint 条件下 crash 最多丢失约一个 30 秒 interval；若 checkpoint 持续失败则不承诺该上界。

计时写失败不得阻止 answer/grading/ReviewState/submit/Practice 正常退出，但不能以“0 分钟”冒充完整统计。projection 必须能表达 unavailable/partial/recorded-only。禁止对不确定写入自动 replay 造成重复 duration，也禁止根据 wall-clock 或题数猜补。

## 6.8 首页周聚合

周定义 Monday→Sunday，使用用户系统当前本地周。

本周总时长 = 当前周 localDate 下 StudyActivitySegment.durationMs 总和。学习天数 = durationMs > 0 的 distinct localDate 数。

未来日期不显示完成；空成功查询显示真实 0，查询失败显示 unavailable。禁止从 ReviewLog、Question count、Attempt count、Pomodoro 推算时长。不回填历史时长，不把本周学习天数称为连续学习天数。

内部保留毫秒；UI 向下取整整数分钟；0<duration<60s 显示“小于 1 分钟”。

---

# 7. 今日首页 v2

## 7.1 信息结构

品牌/今日 → 欢迎 Banner → 三项学习摘要 → 今日训练(Category + 当前 TrainingContent) → 单一活动 StudyPlan → 学习日历与本周时长 → 模考与试卷 → 创建/导入/TaskCenter 等次级入口。

一级导航保持：今日｜助手｜我的。不增加 mode selector、第四 tab 或嵌入式考试 polling。

## 7.2 三项摘要

继续使用题库题量、已掌握、今日已练。

范围为当前可用 TrainingContent 的所有关联 ordinary-training-eligible banks，Question distinct。0% member 仍属于 relation，因此三项摘要包含 0% member；只有新题候选数排除 0%。

题库题量为真实 distinct Question 数；已掌握沿用现有 mastered predicate；今日已练为当前 member 范围内本地当天正式 ReviewLog 的 distinct Question 数。

不能用 Attempt count、grade count、Session count、duration。没有 usable TrainingContent 时显示未配置/unavailable，不能拿 Category 总数冒充 current content summary。

## 7.3 Category Card 与翻页角

外层横滑切 Category；当前分类为主卡；下一 Category 露出约 15%～20%；单 Category 不制造假邻卡；pagination dots 只表示 Category；无第二层横滑/chips/dropdown。

当前卡右上角使用固定 folded page corner。点击按 (sortOrder, contentId) 切下一个 usable content。只有一个 usable content 时隐藏；没有 usable content 时显示配置 CTA；invalidated content 不进入快速 cycle。

动画约 200ms 局部替换，不使用 refresh/loop/sync 图标，遵守 Reduce Motion。可访问性 hit target 不能只限装饰尖角，semantic label 为“切换下一个训练内容”。

## 7.4 新题与复习入口

新题：current TrainingContent + positive-weight NEW pool。
复习：current Category complete due review pool。

同一 Category 切换 content 时，新题 count 与三项 content summary 更新，但 Category review count 与 StudyPlan 不应变化。

loading、real zero、unavailable、unconfigured 必须区分。真实 0 弱化禁用；新题无 content 时提供配置 CTA；Category review 仍可独立有效。不增加统一“开始训练”按钮。

## 7.5 单一 StudyPlan 与导航刷新

继续复用 singleton StudyPlan，保留真实 title/查看计划/开始特训/停止计划，并区分 no plan、unavailable、no candidate、query failure。不得展示多卡 carousel、假名称、假百分比或 N/M 进度。

保留题库详情、补充答案、全局错题本、文件/拍照导入、TaskCenter、MockExam 创建/历史/评阅、Assistant/Profile。

融合 TrainingContent 的题库详情入口应列出真实 member banks，不跳转虚构融合题库。

刷新触发包括 import/Practice/config/题库删除或分类移动/StudyPlan detail/Today reactivation/app resumed。每次 query 带 context generation，late result 不覆盖新 selection，dispose 后不 publish。Home refresh 禁止触发 Practice、模型、OCR、catalog self-heal 或 durable write。

## 7.6 页面改造策略

保留现有 HomePage 作为最终装配位置，优先复用 Banner/PlanCard/design token。新增 Category training card、page corner、weekly activity view 等纯展示组件。

TodayController 负责 loading/generation/UI context state，不计算 quota、eligibility、FSRS 或业务 selection。Application query 提供完整 snapshot。

不复制 Mobile/Desktop 两套业务页面。Practice 保留当前视觉只接 scope/StudyActivity 生命周期；MockExam 保留倒计时和提交，只接 StudyActivity。

---

# 8. TaskCenter 契约

## 8.1 页面与 Application 边界

保留进行中、待校对、已完成、异常四个 coarse tab；底层 queued/running/cancelRequested/cancelled/failed/interrupted/readyForReview 继续是既有 attempt state，coarse tab 只是 projection。

最终 TaskCenterScreen 禁止直接依赖 TaskManager.instance、ImportTaskCoordinator、mutable ImportTask、database row、parsedData、raw diagnostics/provider body/raw exception，也不得自行判断 eligibility、执行 cleanup SQL 或 retry state transition。

只消费 immutable task-list DTO、安全详情 DTO、action eligibility、Application commands、navigation requests 和 injected file-selection/navigation callback。Infrastructure adapter 可封装现有 TaskManager/Coordinator，不因此整体重写 ImportTask engine。

## 8.2 Review Compatibility Bridge

TaskCenter 发出的 review navigation request 携带 task identity、expected attempt number/token 与必要 expected revision。

Composition bridge 重新验证 task/attempt，通过现有 service 取得 current review input，打开既有 ImportStaging，并保持 review draft CAS、lease 与 Question commit authority。旧构造输入只允许留在显式 composition bridge，不能把 parsedData、mutable task 或 raw file path 塞回 TaskCenter read DTO。

## 8.3 Event Time

import_tasks additive 增加 nullable UTC seconds：attempt_started_at、parsed_at、failed_at，继续保留 created_at 与 completed_at。

投影：

| 状态 | UI 时间 |
|---|---|
| queued | 排队于 createdAt |
| running/cancelRequested | 开始于 attemptStartedAt |
| pendingReview | 解析完成于 parsedAt |
| completed | 完成于 completedAt |
| failed | 失败于 failedAt |
| cancelled/interrupted | 对应真实状态；无可靠事件时间不猜 |

completedAt 只有 completed 状态投影为正式完成时间，不重写 legacy auto-expiry policy。显示格式为系统本地 YYYY.MM.DD HH:mm。

## 8.4 写入 ownership 与 retry

当前 accepted attempt 真正开始写 attemptStartedAt；成功发布 review candidate 写 parsedAt；正式失败写 failedAt；正式校对 commit 继续由既有 QuestionRepository-owned transaction 写 completedAt。所有 callback 校验 attemptNumber/attemptToken，原路径要求 review revision 时继续验证。

accepted retry：attemptNumber 按既有规则增加，生成新 token，并将 attemptStartedAt/parsedAt/failedAt/completedAt 重置为 null；新 attempt 真正开始后才写 startedAt。

旧 attempt late callback 必须 stale/rejected、zero mutation，不写新时间、不覆盖 state/candidate/error/UI。cancelled/interrupted 不得伪装 failed。

## 8.5 Retry 文件选择跨层 handoff

TaskCenter read DTO 永远不暴露 absolute local path，也不得保存 picker platform object、file bytes、file handle 或 raw OS URI 到 task list/detail DTO、UI snapshot 或 persisted TaskCenter projection。

若合法 retry 需要用户重新选择 source file：

TaskCenter → emit RetryFileSelectionRequest(task target) → composition/presentation host 打开 FilePicker → 用户显式选择 → ephemeral selection handoff → 既有 Application/infrastructure retry adapter。

该 selection 只是命令输入过程中的 ephemeral value。path/URI 只允许存在于 file picker boundary、composition adapter 与必要的既有 infrastructure ingestion adapter 内，不得进入 TaskCenter read model、durable public DTO、reusable Presentation snapshot、logging 或 diagnostics projection。

若既有 retry adapter 接收 path，path 只能停留在兼容 adapter 内。本轮不因此新建 managed-file architecture 或重写 FilePicker/import pipeline。

## 8.6 历史数据与清理

新增事件字段不 backfill 猜测。禁止用 createdAt 冒充 startedAt、pendingReview legacy completedAt 冒充 parsedAt、error legacy completedAt 冒充 failedAt。已确定 completed 可继续显示 completedAt；缺失显示“时间未记录”或省略。

“清理已完成记录”流程：Application 生成当前 eligible completed snapshot → UI 确认“仅删除解析任务记录，不影响已经保存的题库” → command 提交 snapshot identity → execution revalidate completed/current attempt/non-busy/lease → 只删仍满足条件的 snapshot members。

禁止删除 error/pendingReview/processing/busy、确认后新完成任务，禁止直接复用旧 completed+error cleanup、禁止只删内存报告成功，禁止删除 Question/ReviewState/QuestionSet/source file。

## 8.7 视觉

低饱和灰/蓝、无明显蓝色卡片描边、无旧高饱和紫主 CTA、统一线性图标。卡片显示文件名、状态、安全计数、正确事件时间和操作；文件名最多两行；提供 empty state、CTA、refresh。Light/Dark 共用业务组件。渲染、切 tab、自动刷新不得触发 OCR/Provider。

---

# 9. 架构与公共接口冻结

## 9.1 Dependency Direction

Flutter Presentation → Application Query/Command/Lifecycle → Domain Values/Pure Policies。

Repository/SQLite/existing infrastructure 实现 Application ports；composition root 组装 concrete dependencies。

禁止 UI→Repository、UI→SQLite、UI→mutable ImportTask、Domain→Flutter。

## 9.2 最小公共能力

| Capability | Contract |
|---|---|
| OrdinaryTrainingBankEligibility | ordinary-training bank 单一 eligibility policy |
| TrainingCatalogQuery | CategoryKey、bankName、eligibility、catalog snapshot |
| TrainingContentQuery/Command | immutable config、expectedRevision、safe result |
| TrainingSessionApplicationService | startNew/startCategoryReview |
| TodayTrainingQuery | current context、summary、new/review count |
| StudyActivityService/Query | owner lifecycle、checkpoint、weekly aggregate |
| TaskCenterQuery/Command | immutable safe DTO、expected attempt、精确动作目标 |
| Retry file handoff | composition-bound ephemeral user selection |

App read DTO 不含 SQL、database row、provider payload、raw exception、absolute path；TaskCenter DTO 不带完整题目。clock、RNG、local-day resolver 可注入，errors typed/safe。

Domain 负责 CategoryKey、allocation/quota、percentage normalization、lifecycle pure invariants；Application 负责 eligibility contract、跨 Repository 校验、CAS、command orchestration、session admission、activity owner 与 Task facade；Repository/Infrastructure 负责 SQL/transaction/typed materialization、existing bank visibility adapter、clocks、TaskManager adapter、FilePicker/path compatibility boundary；Presentation 负责 UI state、动画、确认、导航和显式文件选择启动。

不新增第三方依赖。

## 9.3 CAS 与事务

TrainingContent create 在一个事务保存 parent+members；update/delete 使用 contentId+expectedRevision。成员、weight、position、limit、name、revision 原子提交，事务内重验 bank exists、ordinary eligibility、same Category、weight sum、member uniqueness。stale 零写入，不自动 retry。

Category preference 使用独立 revision。visual 与 currentContent 不增加 TrainingContent revision。非 null currentContent 必须指向同 Category 中仍存在的 TrainingContent，但不要求当前 usable，因为 usability 由 runtime fallback 处理。

StudyActivity checkpoint sequence/revision 由 Application 串行，Repository 验证 terminal invariant。Task event 以 attempt identity 为 authority。

## 9.4 保留既有契约

本轮不得改变 typed sidecar authority/corrupt fail-closed/typed explicit-empty、RichContent structural rendering、AnswerAttempt append-only、ReviewState 与 Question 内容分离、FSRS、normal/focused attribution、grades 1/2/3/4 与 Again requeue、preview discard/save、P7 review/confirmation/commit、P6 shelved、MCP 六只读工具、Provider/credentials/managed files/ContentAsset lifecycle。

---

# 10. Schema、Migration 与 B0

## 10.1 版本

基于当前规划时 v28：

| Version | Capability |
|---|---|
| v29 | TrainingContent / members / Category preferences |
| v30 | StudyActivitySession / Segment |
| v31 | ImportTask current-attempt event timestamps |

版本 writer 严格串行。如果其他已授权工作占用版本，STOP，由 Planner 修订映射；Executor 不得自行 +1。

## 10.2 v29

training_contents：content_id PK、category_key、name、question_limit CHECK 1～100、sort_order、positive revision。

training_content_members：content_id FK cascade、bank_name、weight_percent CHECK 0～100、position、binding_status、nullable invalidation_reason；同 content bankName unique、position unique。不建立 bank FK，因为本轮没有 bank entity registry。

training_category_preferences：category_key PK、visual_key、nullable current_content_id、revision。全局 current Category 使用独立 app_settings key，不复用 current_bank。

P1c persisted key 为 `current_training_category`，value 使用 P1a `CategoryKeyCodec.encodeString` 的 canonical string。B0 只校验其结构，不要求对应 Category 当前可展示。Schema authority 为 `training_content_v29_schema.dart`；migration / B0 使用 transaction-bound `DatabaseOrdinaryTrainingBankEligibility` 最窄只读 bridge，复用现有全局错题本和隐藏模考题库精确 reserved identity，不调用带自愈写入的旧 subject-tree query，也不推断任意 emoji 名称。

跨 row invariant（non-empty member、weight sum 100、positive member、same Category、eligibility、preference relation）由 transaction-level validation 保证，B0 staged validation 同样验证。

## 10.3 v29 Migration Seed

只检查旧 current_bank。

若它真实存在、ordinary eligible、非 virtual/hidden 且仍有 Question，则创建一个 single-bank TrainingContent：name=exact bankName，Category 来自 catalog，weight=100，questionLimit 读取旧 bank quota；缺失/非法/<=0 用 40，否则 clamp 1～100，并设为 current Category/current content。

其他 bank 不 seed。禁止为全局错题本、hidden exam bank、StudyPlan、所有历史题库或后续 import bank 自动生成 content。migration 幂等；用户以后删除 seed content，restart 不得重建。

旧 current_bank/quota 可留给 legacy caller，但不是新首页第二 write authority。Migration 禁止改 Question、ReviewState、ReviewLog、AnswerAttempt。

## 10.4 v30

study_activity_sessions：

- session_id PK；
- scene；
- lifecycle_status；
- started_at_utc_ms；
- last_checkpoint_at_utc_ms；
- nullable ended_at_utc_ms；
- nullable end_reason；
- checkpoint_sequence/revision；
- optional soft categoryKey/contentId/bankName/plan/paper identity。

必须验证 V3 lifecycle matrix。

study_activity_segments：

- segment_id PK；
- session_id FK；
- sequence；
- local_date；
- utc_offset_minutes；
- UTC interval boundaries；
- duration_ms >= 0；
- unique(session_id, sequence)。

Segment duration 是 aggregation authority，不维护第二套可漂移累计时长。上下文为 soft historical reference，删除 TrainingContent/Bank/Plan/ExamPaper 不 cascade 学习时长。不回填旧 duration。

## 10.5 v31

import_tasks additive 增加 nullable UTC seconds：attempt_started_at、parsed_at、failed_at。保留现有 status、diagnostics、attempt identity、old columns、completedAt，不 rewrite historical payload。

## 10.6 B0 INCLUDE/SCRUB

INCLUDE：TrainingContent、members、bindingStatus/invalidationReason、weight/position、Category preferences/visual/currentContent、StudyActivitySession/Segment、原 durable Question data 与 QuestionSet relations。

继续 SCRUB：ImportTask（含新事件时间）、ParsedArtifact、retrieval cache、reclamation observation、credentials 及既有禁止 export 数据。

SQLite schema 增加不自动升级 backup packageVersion；packageVersion 与 schemaVersion 继续分离。

## 10.7 Activity Snapshot

导出 sanitized snapshot 时只改 snapshot，不改 live DB。active/paused activity 在 snapshot 中变为 interrupted/snapshotInterrupted，endedAt 取最后成功 checkpoint，保留 existing segments，不用 export current time 补时长，不改 live owner/Practice，不携带 queue restore 能力。

## 10.8 Restore Validation

必须验证：

- schema/table/column/required index；
- CategoryKey canonical encoding；
- content/member uniqueness、weight 0～100、sum 100、positive member；
- valid binding 的 bank 真实存在、ordinary eligible、same Category；
- invalidated binding 允许引用已缺失、移动或当前不 eligible 的旧 bankName；
- preference current_content_id 非 null 时目标 content 必须仍存在且同 Category，但允许该 content 当前 unavailable；
- global currentCategoryKey 只要求 structurally valid encoding，不要求当前 catalog 必须展示；
- segment parent/sequence/non-negative duration；
- StudyActivity lifecycle/endReason/endedAt 合法矩阵；
- 既有 typed/QuestionSet/ContentAsset/managed asset/scrub invariants。

因此合法备份可以保留 preference.currentContentId=A，而 A 仍存在、Category 正确但含 invalidated binding。restore 后 runtime query fallback 到其他 usable content，不得自动清空 A 或改写成 B。

非法情况包括 dangling contentId、cross-category current content、malformed identity。runtime fallback 不属于 restore repair。

非法 authoritative state fail-closed。禁止 restore 时删 member、改 weight、把 invalidated 改 valid、改 current content、猜补 duration 或修补 Question。

旧 schema 只在 staged DB 走合法 migration；高于 runtime schema 拒绝。restore 后旧 Activity owner handle 不得向已收尾/缺失 session 追加；相同 session id 不表示恢复原 runtime owner。

## 10.9 Rollback

migration/restore failure 保留原 DB。可回退尚未 production-activated 的 UI wiring。禁止 schema downgrade、drop 新表作为回退、让旧 binary 打开 unsupported schema、rebuild DB 或 silent reset config。

---

# 11. Canonical 文档与激活

## 11.1 P0 文档

获得文档写授权后保存 V3 正文与执行附录；当前首页契约标记 V3 successor planned；记录 scope/excluded scope；修正 B0 current-state 为实际 v28/QuestionSet 已存在；保留历史版本记录。

P0 禁止宣称 v29/v30/v31 已存在、Home v2 已 production、Activity timing 已 production、TaskCenter facade 已 production。

## 11.2 实施同步

| 实际变化 | Canonical Sync |
|---|---|
| v29 | Architecture / B0 / focused training contract |
| v30 | Architecture / B0 / StudyActivity focused contract |
| v31 | Architecture / TaskCenter focused state |
| TrainingContent production | Today/Home current contract |
| Home v2 production | Today/IA current contract |
| Practice Activity production | Practice lifecycle amendment |
| Weekly duration production | Today deferred clause |
| TaskCenter facade production | current TaskCenter implementation truth |
| final closure | Roadmap + V3 + execution appendix |

StudyPlan focused contract 不为记录“没有变化”而修改。

## 11.3 Checkpoints

CP1：冻结并审查 Domain types、CategoryKey、OrdinaryTrainingBankEligibility、Application ports/DTO、allocation/quota、StudyActivity lifecycle matrix、safe errors、retry file-selection handoff 与 ownership。

CP2-T：v29、seed、CRUD、invalidation、B0、quota、random window、materialization、startNew/startCategoryReview 可验证。

CP2-A：Activity pure lifecycle、v30、checkpoint、date split、crash recovery、B0、aggregate 可验证。

CP2-I：v31、attempt timestamps、retry reset、old callback rejection、TaskCenter facade、cleanup、retry file handoff 可验证。

CP3：真实 composition、Application injection、production page entry 通过。

CP4：整体 scope、navigation、current docs、accessibility、visual acceptance 闭合。

每个 capability 通过自己的 gates 后即可更新 canonical current fact，不必等最终 P11。Fixture-only UI 不得声明 production implemented。

---

# 12. 测试与验收矩阵

## 12.1 Configuration / Identity / Eligibility

必须覆盖：

- FolderCategoryKey / Uncategorized 正确区分；
- 与未分类同名的真实 folder 不碰撞；
- 默认学科不等于 uncategorized；
- selector 只显示 ordinary eligible；
- global wrong book / hidden exam bank excluded；
- 不靠 emoji heuristic；
- selector、seed、admission、review pool 使用同一 eligibility；
- 多个 content 共享同 bank 不复制 ReviewState；
- same Category、unique bank、unique position、weight sum 100、至少一项 positive、limit 1/100；
- stale update/delete 零写入；
- query 不触发 getSubjectTree side effect；
- catalog read 前后 DB 不变。

## 12.2 Binding Invalidation

覆盖整库删除、最后一题删除/迁出、Category movement、移出再移回、同名 bank 删除后重建、clearAll、同事务 replace 临时空库、显式 rebind、失败 mutation 不提前 invalidated、revision 原子递增、既有考试引用删除 guard 不受影响。

## 12.3 Ratio / Quota / Sampling

覆盖单成员 100%、等分、Largest Remainder/tie-break、其他权重和为 0、member 增删、0% 不 quota/count/refill 但仍进入 Category review、候选不足和多轮回填、limit 1/100、随机 offset/回绕/每 bank 最多两窗口、无重复、fake RNG 可重现、final shuffle、materialize≤100、大池不全量 payload/ORDER BY RANDOM、typed corrupt whole failure、empty/stale/failure 不替换 queue。

## 12.4 Learning State

覆盖 AnswerAttempt+reveal 未 grade 仍 NEW、首次正式 grade 包括 Again 后共享 content 不再 NEW、Again requeue、未提交/未做到题零状态、exit 零隐式 grade、preview 无正式 Activity/FSRS、normal/focused 不变、FSRS reset 后 NEW 跟随真实 ReviewState。

## 12.5 StudyActivity

四个已接入 scene、第五 scene 不激活；active/paused/ended/interrupted 合法矩阵与非法组合 fail；background/system dialog/temporary overlay pause、same owner resume、pop/replace owner release ended、submit failure 不写 submitted、submit success submitted；重复 pause/end/dispose 竞争、checkpoint replay、same sequence different payload conflict、terminal no append；monotonic、midnight split、DST、system time/timezone change、毫秒精度/UI rounding；crash recovery 幂等、宕机不计时、queue 不恢复；空历史 0 与查询失败区分。

## 12.6 TaskCenter

覆盖四 coarse state、详细 attempt state；queued/running/pending/completed/failed 时间；历史 null 不猜；retry 重置所有 current-attempt 时间与 token、旧 callback 零 mutation；cleanup 只删确认 snapshot 中仍 completed，error/pending/busy/确认后新完成保留；durable failure 不 fake success；Question/QuestionSet/source file 不受影响；TaskCenterScreen 无 TaskManager/Coordinator/mutable ImportTask/raw parsedData/raw path DTO；retry file selection 由 host 发起 ephemeral handoff，取消不产生 retry mutation，file selection 后 attempt stale 安全失败；existing review CAS 保持。

## 12.7 B0

覆盖 fresh schema 与 v28→29→30→31；seed 只旧合法 current bank；无 mass seed；binding invalidated/visual/current selection/StudyActivity round-trip；unavailable currentContent reference 与 structurally valid stale currentCategory round-trip；dangling/cross-category preference 拒绝；snapshot activity 收尾不改 live DB；ImportTask 新字段仍 scrub；invalid weight/member/lifecycle 拒绝；typed/QuestionSet/ContentAsset regression；old staged migration；newer schema rejected。

## 12.8 UI / Reachability

360×720、1024×768、放大字体、Light/Dark、Category peek、pagination、page corner/accessibility/Reduce Motion、无第二层 carousel/chips/dropdown/假多计划、loading/zero/unavailable/unconfigured、invalidated repair、0% 说明、content 切换不改变同 Category review 或 StudyPlan、既有次级入口可达、return refresh/latest-wins/repeated-start guard、无第五 scene 页面。实机视觉验收必须单独记录，静态 widget test 不等价于实机视觉闭合。

---

后续 Agent 可以决定局部实现细节，但不得重新决定本 V3 已冻结的产品语义、authority、事务边界、生命周期、迁移规则、eligibility、状态矩阵或交付边界。
