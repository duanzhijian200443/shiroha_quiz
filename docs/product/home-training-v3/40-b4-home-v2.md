# B4 Home V2

Contract: `docs/product/home-training-v3/00-contract.md`

## 范围
- P9a：Today v2 real query projection；
- P9b：TodayController generation/context；
- P9c：Home v2 pure Presentation components；
- I2：Home / configuration production composition + activation。

## 前置
- CP2-T、CP2-A；
- B2 的 P7c；
- B3 / I1；
- contract 中 P9a/P9b/P9c 前置全部满足。

## 主要 ownership
- Today query/adapter；
- TodayController；
- Category / Home weekly presentation components；
- Home/config composition 与必要导航替换。

## 验收
- Category cards、current TrainingContent、new/review counts、weekly activity 使用真实 Application facts；
- latest-wins / stale generation 不覆盖新状态；
- current ordinary TrainingContent 与 global ActiveStudyPlan 继续独立；
- 旧 Today/Home 只有在替代入口真实可达后才被替换；
- required standing CI PASS，Independent Reviewer APPROVE。

## Documentation responsibility
- `docs/product/home-training-v3/00-contract.md`: CHECK_ONLY
- `docs/product/today-home-refresh-freeze.md`: UPDATE
- `docs/product/ui-finalization-ia-freeze.md`: UPDATE
- `ARCHITECTURE.md`: UPDATE
- `docs/architecture/shiroha-project-roadmap.md`: UPDATE
- `docs/product/home-training-v3/40-b4-home-v2.md`: UPDATE

## 实施边界
- Today adapter 捕获一次 clock 和可注入 local-day boundary；configuration、catalog、runtime selection、new/review/summary 在同一短只读事务投影。沿用 shared eligibility/ordering/fallback，不抽题、修复或写回 preference。
- 新题显示全部 positive-weight NEW；Category 到期池独立于内容且首页不 cap 40；摘要包含 0% member，今日已练按本地当天正式 ReviewLog distinct Question。
- TodayController 的 Training、week 和 singleton-plan 状态独立。generation/dispose 拒绝过期发布；Category settle 保存该 Category 已有 persisted content，corner 按正式排序循环 usable content；CAS stale 只 reload、不重试。
- 现有 HomePage 消费纯 Category/行动卡/周日历组件。新/复习入口使用正式 session service，ready 才打开 normal prepared Practice，并传入 B3 显式 scene/context；guard 持续到 route 返回。
- B2 配置页从 Home 可达；返回、tab reactivation、app resumed、Practice/import/题库/计划详情返回都刷新。融合内容详情选择真实 member bank；保留全局错题本、StudyPlan、导入/拍照、TaskCenter、模考、助手和我的。
- 单一 TrainingConfigurationRepository 同时供应 Today/configuration ports。生产 Home 停止使用旧 bank-scoped Today authority；旧 adapter/launcher/PlanConfigScreen 保留兼容，本包不物理删除。
- runtime schema 仍为 v31；I3/TaskCenter activation 与 B6 retirement 未实施，CP3 未完成。B4 的独立审查及最终文档 closure 另行完成；此处不预先声明 acceptance。
