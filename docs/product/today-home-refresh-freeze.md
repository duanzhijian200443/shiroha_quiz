# 今日首页重构：内容与行为映射冻结

状态：**内容与行为已冻结；首页最小解耦、独立训练入口与统一首页已实现。实机视觉验收独立进行。**

本文件依据用户提供的《今日首页重构_UI任务.md》和参考图
`今日首页重构_UI.png`，记录新首页的目标及用户确认的收窄范围：
**先落地现有能力，展示单一活动计划；新统计与完整计划管理延期，保留目标设计。**
最初冻结仅交付文档；后续实现采用下述契约，不改数据库 schema。Git 操作仍按独立授权执行。

## 1. 权威与历史关系

- UI Finalization v0 的普通 / 特训 / 考试模式是历史交付；其历史验收不改写。
- 本文件是当前统一首页的内容与行为权威，以一个纵向页面取代三个模式
  切换器。旧 IA 文档、`ARCHITECTURE.md` 和 roadmap 保留历史并指向本契约。
- 一级导航继续为 **今日 | 助手 | 我的**。
- StudyPlan 业务仍以 `SPL-1 StudyPlan Agent Tool v0.md` 为准：全局单一
  活动计划，显式采用 / 替换 / 停止；不自动完成，不引入多计划存储。
- `ARCHITECTURE.md` 的分层、typed authority、Review / FSRS、隐私与
  写入审批边界继续有效。

## 2. 页面内容与点击行为

首页使用一个纵向滚动主体，顺序如下。展示数据必须来自真实状态；
参考图中的数字、计划名和比例均不是产品数据。

| 区域 | 本轮内容 | 点击行为与边界 |
|---|---|---|
| 品牌与标题 | `Shiroha Quiz`、`今日`、短副标题「继续你的学习节奏」 | 品牌与标题不附加业务操作；保留已有创建 / 导入和解析任务入口 |
| 欢迎 Banner | 随本地时段变化的问候、简短鼓励语、轻量插画 | 非操作区；不显示未经统计的连续学习天数，不发起 AI 请求 |
| 三张学习摘要 | **题库题量、已掌握、今日已练**；范围均为当前普通训练题库 | 展示为主，不新增三个统计详情入口；不能展示为全局或计划专属统计 |
| 今日训练 | 当前题库名称与切换入口；左右对称的 **新题挑战 N 题 / 复习巩固 N 题** | 题库切换沿用现有选择流程；两个训练卡片各自启动相应会话；移除统一开始训练按钮及重复待练总数 |
| 训练计划 | 一个真实活动计划或真实空状态；短标题、简洁状态；不铺详细策略 | 点击计划卡进入轻量「当前计划」详情；标题右侧使用 **查看计划**，不暗示存在多个计划；详情承接开始特训、停止计划等现有操作 |
| 学习动态 | 本轮使用 **学习动态**，显示「今日已练 N 题」与简短鼓励语、轻量视觉元素 | 非复杂统计入口；不展示虚构周视图、周学习天数或学习时长 |
| 模考与试卷 | 紧凑入口，副标题「开始模考 / 生成试卷 / 历史试卷」 | 打开现有 `MockCenterScreen` 独立页面（非嵌入模式）；保留其内部创建、历史、评阅和返回路径 |
| 一级导航 | 今日 / 助手 / 我的 | 沿用当前 shell、助手与设置职责；不增加顶层模考或计划管理 tab |

首页视觉以参考图为准：横向摘要与训练卡、猫与窗台横幅、纸张与铅笔
装饰、柔和阴影与紧凑比例。三种正式外观及共享 Token 以
`shiroha-appearance.md` 为准：浅色/深色保持灰阶，彩色读取正式强调色，
局部 Theme 不强制覆盖外观。插画、构图和尺寸不因主题改变。
其他页面逐步适配，不要求本轮全量美化；创建/导入和解析入口位置由
`home-training-v3.md` §1.6 的后续修订覆盖。
手机端优先，同一套组件适配宽屏，不复制两套完整页面。

## 3. 数据口径

### 3.1 普通训练与摘要

- 当前题库来自既有选中题库配置，经窄 Application 接口供页面读取。
- 新题数量、待复习数量沿用当前普通训练的统计语义：普通题库的新题
  `state == 0`，待复习 `state > 0 && next_review_time <= now`。
  不把已掌握题一律排除于到期复习，也不顺带修复统计或调度算法。
- 题库题量、已掌握和今日已练复用既有 `StudyQueryService.getStudyOverview`
  的 bank-scoped 查询。今日已练是该题库本地当日已有正式 review log 的
  **不同题目数**，重复练同一道题不增加这个数；不是作答次数、会话数或时长。
- Today 的 `StudyQueryService` 单独注入系统本地时区解析器（`local`）：
  将查询时刻转为系统本地日期，再构造该日的本地午夜转回 UTC，包含午夜的
  DST 偏移；不使用当前固定 offset 推算午夜，不硬编码上海或使用 UTC 日界。
  Agent / MCP 的既有 IANA resolver 与接口契约保持不变。
- 普通配置中可选择的「全局错题本」是虚拟题库：Today-only metrics adapter
  使用现有错误作答 / lapses 集合读取三项摘要；普通 T0 查询仍按真实 bankName
  精确作用域读取。该虚拟题库的新题入口保持 0，到期启动只选 state > 0 的
  到期候选；训练卡显示数量继续沿用其现有统计，不修改旧统计算法。
- `getStudyOverview.dueCount` 不直接替代普通训练卡的待复习数，两者当前
  生产口径并不相同。新接口只组合既有口径，不以名称相似为由混用。
- 数量是总可用数量，不承诺一次会话一定加载全部；继续保留现有会话
  数量限制与顺序语义。没有题库时显示「选择题库」及未就绪状态。
- 缺失、失败和加载中的数据不伪装为 0；确认成功返回的真实 0 才显示 0。

### 3.2 单一活动计划

- 首页只展示 `ActiveStudyPlan`，与当前普通训练题库相互独立；切换普通
  题库不能悄悄改写计划的 `bankName`、dailyTarget 或候选队列。
- 当前模型没有独立计划名。显示标题派生为「{bankName} · 训练计划」，
  不新增持久化 title，也不虚构「极限专项强化」等计划。
- 短状态沿用现有 focused state：今日可特训 N 题、今日暂无任务、
  计划题库不可用，或暂时无法加载。
- 本轮不显示 `今日 13/20`、完成百分比或未经核实的剩余天数。现有
  focused state 未提供这些累计进度；不能将可选题数量当作完成数量，
  也不能把普通题库掌握率当作计划完成率。
- 无计划时显示「尚未采用学习计划」及「去助手制定计划」入口，沿用
  现有助手规划、预览和显式采用流程；页面不自动发起模型请求。
- 轻量「当前计划」详情是本轮 Presentation 目标，复用现有能力，
  **不把旧 `PlanConfigScreen` 冒充 StudyPlan 管理器**。旧 PlanConfig
  仍是普通题库 / 训练配置，两套 quota 语义不互写。
- 详情可展示既有策略和 advisory，并保留停止计划确认。启动前重新
  读取 / 选择真实候选，沿用 exact-order materialization 与非 preview
  Practice 路径；不能用 `initialQuestions` 模拟正式特训。
- 停止只影响当前计划，沿用精确对象确认及 CAS；发生 stale 时不自动
  重试。已掌握或期限已过仅为 advisory，不自动停止或禁用正常训练。

## 4. 新题与复习：入口契约

冻结的目标行为：

1. 新题挑战只选择当前题库的新题候选进入正常 Practice；
2. 复习巩固只选择当前题库到期、已进入 Review 的候选进入正常 Practice；
3. 二者继续使用现有回答、评分、重排和 FSRS 持久化语义。新题在会话中
   被评分后可按正常规则重排；「只选新题」约束初始候选，不禁止正常重练；
4. 真实数量为 0 时保持对称布局并弱化、禁用该项启动；无题库则两项
   不启动。点击时重读实际候选，避免显示快照过时导致错开会话；
5. 两项不能都接回同一个无区分的题库详情或混合会话，以假装已经完成。

当前实现的最小会话入口为 Application `StudySessionLauncher` 与
`StudySessionPool`（mixed / newQuestions / dueReviews）。Home 只使用后两者；
Repository 既有调用默认 mixed，不改其他入口行为。

- Repository 在 SQL `LIMIT` 前筛选 `state == 0` 或
  `state > 0 && next_review_time <= now`；普通题库仍按 state DESC、
  next_review_time ASC 排序，虚拟错题本保留其 next_review_time 排序。
  现有题型筛选仍独立，默认上限 40 不变；不把 `filterType` 当学习状态。
- 点击时重新读取选定题库候选；typed / legacy 全量解码成功且非空后，
  infrastructure launcher 才替换 ReviewEngine 的 prepared queue。
  空集合和任何解码 / 读取失败均不替换原队列，不 fallback 或部分注入。
- 普通池通过非 preview Practice 运行，显式使用 normal 作答归属；既有
  StudyPlan prepared 调用默认 focused。手动与照片作答均使用该归属，
  回答、评分、重排、FSRS 与持久化格式不变。
- 普通与特训启动共用 Presentation guard，覆盖准备和整个 Practice 路由。
  返回后刷新普通摘要与计划；不自动开练、写入或调用模型。

## 5. 本轮暂缓与保留的目标设计

| 目标设计 | 本轮处理 | 后续恢复条件 |
|---|---|---|
| 连续学习 / 本周完成 / 最近导入摘要 | 用三项已有摘要替代；保留参考布局 | 另行冻结时间窗、计数单位、数据来源与查询边界 |
| 多计划横向预览，约 2～2.5 张 / 屏 | 只展示单一活动计划；不复制卡片或补假计划 | 单一活动计划契约需要正式变更后再扩展 |
| `See all` → 完整计划管理 | 本轮为「查看计划」→ 单计划详情 | 新建、编辑、暂停、完成、删除、多计划关系另行冻结 |
| 数值计划进度与每日完成目标 | 本轮仅显示真实可训练状态 | 独立进度事实源及其与普通训练 / 特训的归属口径冻结 |
| 学习日历、周学习天数与学习时长 | 本轮为轻量学习动态 | 日志口径、时间单位、去重和跨日边界另行冻结 |

本轮的单计划卡与详情复用计划展示组件和 Design Token；不为未来多计划
提前改 schema 或实现通用管理框架。AI 大题补答失败、PDF 补答封存恢复
及其他已延期能力不属于本轮。

## 6. 保留的可达性与状态边界

- 创建 / 导入仍能选择文件或拍照；解析入口仍到 TaskCenter。首页
  重构不改导入、校对、入库与任务恢复链条。
- 当前题库详情仍有明确次级入口，例如「题库详情」，保留补充答案等
  已有次级能力；不把新题 / 复习两张启动卡再当作该详情入口。
- 导入、练习、计划详情或题库选择返回后刷新受影响摘要；重新进入
  今日时也刷新计划状态，不再依赖「当前处于特训 mode」这一旧条件。
- 保留过期读取不覆盖新状态、重复启动防护和 dispose 后不发布状态。
  刷新不能自动启动会话、模型或正式写入。
- 助手和我的既有入口、状态与功能不因今日取消 mode selector 而丢失。
- 首页不再常驻嵌入整个考试中心；进入考试页面后复用其既有资源释放
  和轮询生命周期，不能在隐藏首页卡片中持续运行考试轮询。

## 7. 串行交付与验收

交付边界如下；独立训练入口与新布局在同一轮实现中串行落地：

1. **首页最小解耦**：复用已有 Application 查询 / 命令，整理普通摘要、
   focused 刷新及启动状态；旧外观与既有行为先保持。Production wiring
   由 main / composition root 负责。具体 Allowed paths 由执行包另行列明。
2. **独立训练入口包**：实现第 4 节入口契约，直接验证新题 / 到期集合、
   limit 前筛选、typed fail-closed、空集合和普通评分 / FSRS 路径。
3. **新首页与单计划详情**：移除三模式选择器，接入新题 / 复习独立入口，
   完成组件布局和必要导航；同步当前 canonical 首页描述。

验收必须覆盖：

- 顺序为欢迎 → 三项摘要 → 今日训练 → 单计划 → 学习动态 → 模考与试卷；
  不显示三模式 selector、统一开始训练按钮、假计划 / 假统计。
- 新题与复习的启动候选各自正确；真实 0、未加载、失败和无题库区分。
- 普通当前题库与计划题库不互相覆盖；无计划、无候选、计划题库不可用、
  stale stop、重复启动、旧请求晚到等路径继续正确。
- 模考创建 / 历史 / 评阅、题库详情、创建 / 导入、TaskCenter、助手与我的
  保持可达；返回到统一今日页面。
- 360×720 与 1024×768 下无溢出、无不可达入口；放大字体后内容不裁切，
  整卡点击有明确语义；单张真实计划不强制填充多卡 carousel。
- 调整测试以证明统一首页行为，不只删除旧 selector 断言；保留业务边界
  回归，执行与改动相关的 architecture / focused analyze / format 门禁。
- 静态测试不能替代实机视觉验收；实际 App 验收另行记录，不预先宣称通过。

历史冻结阶段未改变运行行为；当前实现仍不包含延期统计、多计划管理或 schema 变更。

## HOME-TRAINING-V3 successor（B4 Home v2 实施 amendment）

`docs/product/home-training-v3.md` 已冻结
**SHIROHA-HOME-TRAINING-IPF-V3** 作为本契约的 successor。TrainingContent、
launch、durable StudyActivity、v31 ImportTask event timestamps 与 TaskCenter
backend 已分阶段合并，用户已确认 B2/B3 完成。B4 在现有 HomePage 实现
Home/configuration Presentation 与 I2 production wiring；上述 bank-scoped
普通训练和学习动态描述保留为历史基线，新的行为由下列 amendment 与
`docs/product/home-training-v3.md` §7 管理。PR #234 已合并，B4/I2 已成为
当前 production truth；独立审查与 CI 的历史执行证据由该 merged PR 保留。

本轮实施包括：

- **Category → TrainingContent → 普通新题**：普通训练范围从当前单题库
  切换入口改为按 Category 配置的 TrainingContent（名称、题量、权重、
  顺序），新题候选来自正权重 member 题库；
- **Category → Category review pool**：到期复习改为当前 Category 下全部
  ordinary-training eligible 题库的完整到期池，不受当前 TrainingContent、
  member 或权重影响；
- **今日首页 v2**：Category 横滑卡、当前 TrainingContent 与翻页角、真实
  本周学习时长与轻量学习日历；
- 真实学习时长（StudyActivity durable timing）、任务事件时间与 TaskCenter
  Application facade；
- additive migrations v29 TrainingContent、v30 StudyActivity、v31 ImportTask
  event timestamps 已进入当前 runtime v31；B4 不增加 schema 或依赖。

**StudyPlan** 继续保持全局单一 ActiveStudyPlan（沿用 SPL-1），独立于
TrainingContent：TrainingContent 是普通训练范围配置，不是多计划能力；
切换 TrainingContent、题量或权重不改变已采用计划与计划题库。V3 排除
多计划、stable bankId、Category rename、第二套 taxonomy 与 AI Category
Visual 等能力。

三项摘要包含 current usable content 全部合法成员（包括 0%）；新题只计
positive-weight NEW，复习为整个 current Category 的独立到期池。首页 counts
不使用 queue limit，unconfigured/unavailable 不假装成功零。Today's projection
在同一短 read transaction 完成，read fallback 不写回；Category settle 与
corner cycling 通过正式 preference CAS，stale 仅 reload。

周视图只消费 durable StudyActivity 七天 DTO，以毫秒计数、floor minutes
展示，非零不足一分钟显示“小于 1 分钟”；partial 显示“记录可能不完整”，
query failure 显示暂不可用。它不显示连续学习、不猜实时 open interval。
配置入口直接到 B2 页面，融合题库详情先选择真实 member；normal prepared
新题/Category review 分别传入 B3 ordinaryPractice/categoryReview scene。
旧 adapter/launcher/PlanConfigScreen 保留兼容而不作为 production Home authority。
TaskCenter UI/I3、复杂统计与 B6 物理退休仍延期。实机视觉验收仍独立进行，
合成 widget visual evidence 不等价于实机验收。

## 2026-10-06 今日首页 UI 范围修订

以上首页学习动态/日历、周学习时长与 MockCenter 可达性条款保留为历史交付背景；后续实施与验收由 `home-training-v3.md` §1.6、§7、§12.8 覆盖。HomePage 不再构建学习日历、七日柱状图/热力图、学习时长摘要及模考入口，不将模考迁移到其他用户可见位置。StudyActivity 记录/周聚合、考试实现/历史/持久化结构及单一 StudyPlan 保留，Practice、FSRS、计时 lifecycle 与 Schema 不变。

顶部按解析任务、开书图标训练配置、创建/导入 `+` 顺序提供现有正式入口，并保留真实 TaskCenter badge 与返回刷新；底部不重复解析/导入。欢迎 Banner 增高，三摘要对应统计/勾选/火焰，Category 保留横滑/分页与可辨认的纸张卷角，新题/复习使用独立短卡。分类主卡仍至少 180 logical px，用户接受其相对图稿更高；无可靠连续天数 authority 时不展示虚构数字。

同日用户明确不增加 production TrainingContent 首页成员题库详情入口，其可达性优化延期至第二次训练配置页重构；题库详情能力、真实 member identity 与数据保留，legacy compatibility 路径不变。此条覆盖前文首页必须直达融合题库详情的要求。历史 UI-R1/UI-CL 记录保持，实际视觉验收仍须独立记录。
