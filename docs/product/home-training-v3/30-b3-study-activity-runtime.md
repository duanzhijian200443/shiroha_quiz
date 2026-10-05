# B3 StudyActivity Runtime

Contract: `docs/product/home-training-v3/00-contract.md`

## 范围
- P8a：Practice StudyActivity integration；
- P8b：MockExam StudyActivity integration；
- I1：Practice / Exam production composition。

## 前置
- P4b / CP2-A 已接受；
- P3b launch semantics 保持；
- B2 按当前串行 rollout 已完成。

## 主要 ownership
- PracticePage Activity wiring；
- MockExam Activity wiring；
- composition root / injection 中直接必要的 I1 路径；
- focused lifecycle/runtime regressions。

## 验收
- Practice 与 MockExam 使用同一已冻结 StudyActivity lifecycle/persistence authority；
- grading、queue、countdown、submit 与 FSRS 行为不回归；
- owner / pause / resume / terminal / process interruption 语义保持；
- 不引入第二套累计时长 authority；
- required standing CI PASS，Independent Reviewer APPROVE。

## Documentation responsibility
- `docs/product/home-training-v3/00-contract.md`: CHECK_ONLY
- `ARCHITECTURE.md`: UPDATE
- `docs/architecture/shiroha-project-roadmap.md`: UPDATE
- `docs/product/home-training-v3/30-b3-study-activity-runtime.md`: UPDATE
