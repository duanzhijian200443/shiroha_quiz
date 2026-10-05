# B4 Home V2

Contract: `./00-contract.md`

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
- `./00-contract.md`: CHECK_ONLY
- `docs/product/today-home-refresh-freeze.md`: UPDATE
- `docs/product/ui-finalization-ia-freeze.md`: UPDATE
- `ARCHITECTURE.md`: UPDATE
- `docs/architecture/shiroha-project-roadmap.md`: UPDATE
- `./40-b4-home-v2.md`: UPDATE
