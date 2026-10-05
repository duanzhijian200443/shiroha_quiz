# 按需自动化协议

入口：用户明确输入 `角色：自动化`。普通角色默认不读取本文件。

## 核心模型

Automation 不维护 tracked task queue，也不把施工状态写成
`docs/product/` 下的任务文件。长期 authority 只有 canonical contract /
roadmap；精确执行事实属于 Git / PR / CI / Reviewer。

每个 bounded task 使用临时 task package：
- PR 前只在当前 handoff/context；
- PR 后写入并维护 PR body 的 `## Task package`；
- 可在既有目标内补 ownership/acceptance/validation/Documentation responsibility；
- 不能扩大 scope 或产生新权限；
- 修改 PR body package 不改变 commit SHA；
- 不创建 Task-ID、READY/ACTIVE/DONE、`-完成.md`、`*-完成/`、execution plan 或第二套 queue。

## 启动与恢复

1. 先核对 master/base、已有 branch/PR、HEAD、dirty state、writer。
2. OPEN PR 优先恢复，读取 contract、PR body package、diff/CI/review。
3. GitHub 已报告 MERGED 的历史 PR 默认 review gate 已满足，不因缺旧 marker 重审。
4. later revert、明确 blocker 或用户要求重开时另建 bounded task。

### Legacy local queue 一次性接管

旧 `docs/automation/task-queue/*.md` 只作为兼容输入，不再是 authority。
已有对应 OPEN/MERGED PR 时旧文件 superseded；无对应 PR 且仍在授权范围时，
把内容转换为临时 package，创建 PR 后进入 `## Task package`，不要迁入
`docs/product/`。无法唯一确定 contract/scope/权限时 STOP。禁止新建 legacy item。
该目录继续被 `.gitignore` 忽略仅为兼容接管。

## 选择下一任务

没有待恢复 OPEN PR 时：
1. 读 roadmap 确定 active capability；
2. 打开该 capability 的 canonical contract；
3. 用 contract 的实施顺序/前置 + merged PR/runtime facts 判断 NEXT；
4. 生成最小临时 package；
5. 无法唯一判断或需要新产品决策时 STOP。

完成依据是 merged PR 与 canonical current-state amendment，不看文件名后缀。

## 执行

```text
temporary task package + authority + Documentation responsibility
→ Executor 实现 production/tests + required durable docs
→ checks + authorized commit/push/PR
→ PR body ## Task package 冻结为最终任务定义
→ current-head/current-target standing CI
→ 仅 CI coverage gap 时 Verifier
→ Independent Reviewer
→ blocking finding: same-PR repair -> new-head CI -> fresh review
→ APPROVE
→ authorized merge
→ refresh master/roadmap/contract
```

没有“APPROVE 后改完成文件名再跑一轮 CI”的阶段。Reviewer/Verifier 对现有 PR
各有一次本轮 evidence publication standing permission。

## Merge gate

合并前要求 final-head/current-target CI SUCCESS、适用的
`[REVIEW APPROVAL]`、必要 `[VERIFICATION APPROVAL]`、closed
Documentation responsibility、无 scope/contract blocker、PR 可合并且已有 merge
authority。PR body package 若实质改变 objective/acceptance/docs responsibility，
旧 Reviewer evidence 失效并 fresh review。

结束时报告 capability、temporary package/PR、base/branch/head、CI、
Reviewer/Verifier evidence、Documentation responsibility、repair counts 与下一步。