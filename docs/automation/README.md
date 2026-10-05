# 按需自动化协议

入口：用户明确输入 `角色：自动化`。普通角色默认不读取本文件。
首要目标是在已有授权内自行定位、解决并验证问题，再继续推进到授权终点。
失败、worker 交付或运行中断本身都不是立即交回用户的理由。

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
- package revision/digest 遵循 `docs/agents/README.md`，最终定义在审查前冻结；
- 不创建 Task-ID、READY/ACTIVE/DONE、`-完成.md`、`*-完成/`、execution plan 或第二套 queue。

## 授权与控制边界

启动时记录用户已批准的范围、完成终点、是否允许后续 roadmap continuation，
以及 implementation、branch/worktree、stage/commit/push/fetch/PR/merge 的实际
动作授权和来源。PR metadata 只使用相应明确授权或已有 bounded standing permission。
既有批准在同一范围与终点内持续有效，不逐次请求交付、修复或 conditional merge
确认；缺失动作仍未授权。需要补权限时先完成独立可做的调查，准备具体 package
和最小权限缺口，再请求用户决定。package、roadmap、PR body 和 digest 都不产生权限。

控制者选择、冻结、派发和检查门禁，不直接修改 production/tests。沿用正常角色
及 `docs/agents/model-routing.md`；默认串行、一个 writer，隔离/并行仍需已有授权。
worker 只接收当前 bounded package、必须自行打开的 governing contract、真实动作
授权、验收、停止条件和累计修复计数；适用的验证修复例外必须写入该包。
worker 不加载本协议或后续任务，不创建后代、切换角色或自行扩展公共契约。

## 启动与恢复

1. 先核对 master/base、已有 branch/PR、HEAD、dirty state、writer。
2. OPEN PR 优先恢复，读取 contract、PR body package、diff/CI/review。
3. GitHub 已报告 MERGED 的历史 PR 默认 review gate 已满足，不因缺旧 marker 重审。
4. later revert、明确 blocker 或用户要求重开时另建 bounded task。

恢复时同时核对原用户批准、授权终点、package identity 和累计修复次数。
工具/额度导致的中断不撤销尚适用的批准；用户撤销/缩小范围、到达终点或责任
实质变化时不能继续沿用。意外 HEAD/dirty state/writer 先只读定位，不覆盖工作。
运行无法继续时留下最小交接：目标、阶段、Git/PR、失败证据、未完成检查、两类
累计修复次数及下一安全动作，不把这些运行事实写成 canonical 产品状态。

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
→ PR body ## Task package + revision/digest 验证并冻结为最终任务定义
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
Executor 的 STOP 结束 worker assignment，控制者继续等待 CI、派发审查和修复，
直到本次授权终点。独立审查使用与 implementation assignment 分离的上下文；
在原实现上下文声明切换 Reviewer 不构成独立审查。

## 先解决阻塞

先做有界诊断，区分 patch-caused、confirmed pre-existing、环境/工具问题和
契约/授权问题。优先派发已有授权内的最小 Executor 修复，重跑失败检查与直接
受影响回归，然后恢复原任务；不把失败本身、worker STOP 或已授予动作变成新确认。
环境/工具问题只在已有权限内有界处理，遵守停滞与重试限制，不无限重试。
当前改动导致的修复遵循 `AGENTS.md` 的责任、冻结语义和预算。

### 已确认既存验证失败的有限例外

仅显式自动化运行及携带以下全部条件的 Executor package 适用；普通角色的
默认停止规则不变。确认既存需要可信 base 证据及因果判断：相同环境/命令的
隔离 base 复现，或足以直接证明根因的历史与代码证据；仅“相关文件未改”不足。
额外 worktree、网络、runtime 验证仍需对应授权。

- 无关额外检查失败：所有必需检查已通过，且失败不涉及当前关键语义/安全边界、
  不损害验收可信度时，记录 `PRE_EXISTING / NON_BLOCKING` 后继续；不修无关代码。
- 直接必要的机械验证修复：未改变的 governing contract 能证明唯一正确修复，
  改动极小且只涉及 test/fixture 或验证编译联动，不改变 production semantics，
  不删除/放宽断言，并在已有授权责任及 strict whitelist 内，才派发 Executor
  修复并复验。handoff 单列 `pre-existing verification repair` 与根因/base 证据。
- schema literal、enum expected-list、fixture 不天然是机械修复。涉及冻结兼容性、
  持久化、并发、安全或验收定义时按对应风险处理；需要选择行为或改变覆盖时
  不适用该例外，不能为了变绿改 expected 值。

两类修复预算继承 `AGENTS.md`，worker/head/package/重启不重置。机械清理只有
符合共享定义才不消耗 semantic cycle；不确定时不能免计。
必需测试或 CI 失败始终阻止完成交付与 merge；不跳过/过滤失败，不降低 required
状态或用 `PASS_WITH_PRE_EXISTING_ISSUES` 绕过门禁。

### 无法在现有授权内解除时

只有有界调查后仍根因不明、需要新契约/授权、跨责任/另一 writer/strict whitelist、
必需验证无法可信完成或预算耗尽时，停止受影响写入和交付，保留证据，报告最小
所需决定。原任务保持未完成。其他已授权任务仅在被证明独立、契约允许乱序且
当前阻塞确实无法在本范围解决时才可推进，不因失败直接跳过当前任务。

## Merge gate

合并前要求 final-head/current-target CI SUCCESS、适用的
`[REVIEW APPROVAL]`、必要 `[VERIFICATION APPROVAL]`、closed
Documentation responsibility、无 scope/contract blocker、PR 可合并且已有 merge
authority。控制者必须重新读取 live PR body，以 identity helper 默认验证模式
重新计算 digest，并将 head/current base/package revision/digest 与适用的
Reviewer/Verifier approval 逐项匹配；字段缺失、声明不符或 evidence mismatch
都不可合并。`-Compute` 输出不是 merge evidence。

审查开始后任何 normalized package section 改动都使旧 pass/approval 失效，
包括 factual/wording correction；increment revision、重算 digest 后 fresh review。
CI 状态/运行记录写在 evidence 中，避免为状态更新改动冻结 package。
合并只使用已有明确授权及合规 Git 方式；合并后核实真实结果，再按已授权 fetch
刷新 master/contract/roadmap。仅在用户批准的 continuation 内选择下一任务。

结束时报告 capability、temporary package/PR、base/branch/head、CI、
Reviewer/Verifier evidence、Documentation responsibility、repair counts 与下一步。
