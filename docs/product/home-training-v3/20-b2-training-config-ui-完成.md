# B2 Training Config UI

Contract: `./00-contract.md`

## Closure 依据

PR #230 已合并且 standing PR CI 已通过。按当前治理规则，GitHub 已报告为 `MERGED` 的历史 PR 默认视为 review gate 已满足，不要求为了旧流程缺失的 `[REVIEW APPROVAL]` 标记重新审查或补发评论。不要重复实现已合并的 production/test 代码。

## 范围
- P6：Category Visual 与共享纯 UI primitives；
- P7a：TrainingContent list pure Presentation；
- P7b：selector + editor pure Presentation；
- P7c：真实 Application Query/Command 集成。

## 前置
- B1 已完成；
- CP1、P2b 与 contract 中 P6/P7 各自前置继续成立；
- 不改变 TrainingContent、StudyPlan、Category identity 或已冻结 CAS 语义。

## 主要 ownership
- Category visual / shared presentation primitives；
- TrainingContent list / selector / editor / controller；
- 必要的 Application-facing UI integration；
- 直接相关 Presentation tests。

## 验收
- list / selector / editor 的 loading / unavailable / empty / stale / success fixture 状态可验证；
- ratio / limit / visual preference 与 current selection 使用既有 Application authority；
- CAS / stale failure 不自动重试、不绕过 binding/eligibility；
- 不新增 schema、不把 StudyPlan 与 TrainingContent 合并成同一概念；
- required standing CI PASS，Independent Reviewer APPROVE。

## Documentation responsibility
- `./00-contract.md`: CHECK_ONLY
- `docs/architecture/shiroha-project-roadmap.md`: UPDATE
- `./20-b2-training-config-ui-完成.md`: UPDATE
