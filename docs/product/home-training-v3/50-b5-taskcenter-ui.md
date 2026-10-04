# B5 TaskCenter UI

Contract: `docs/product/home-training-v3/00-contract.md`

## 范围
- P10a：TaskCenter pure visual components；
- P10b：TaskCenterScreen facade integration；
- I3：TaskCenter composition + review/retry compatibility bridge。

## 前置
- B1 / CP2-I；
- P10a/P10b contract prerequisites；
- B4 / I2 按当前串行 rollout 已完成。

## 主要 ownership
- TaskCenter pure components；
- TaskCenterScreen migration to Application facade；
- composition / review / retry bridge；
- focused Presentation + integration regressions。

## 验收
- UI 不直接访问 mutable TaskManager/SQLite/private source path；
- running / readyForReview / failed / completed 等冻结状态与 event times 正确展示；
- retry 仍是显式 picker + fresh admission；review 仍由后续正式 authority 重验；
- completed-only cleanup 保留 busy/changed/newly-completed records；
- required standing CI PASS，Independent Reviewer APPROVE。

## Documentation responsibility
- `docs/product/home-training-v3/00-contract.md`: CHECK_ONLY
- `ARCHITECTURE.md`: UPDATE if TaskCenter production boundary changes
- `docs/architecture/shiroha-project-roadmap.md`: UPDATE if stage-level availability changes
- 当前 task package：final Documentation Closure 时重命名为 `50-b5-taskcenter-ui-完成.md`
