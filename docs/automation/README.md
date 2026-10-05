# 按需自动化协议

入口：用户明确输入 `角色：自动化`。普通角色默认不读取本文件。
目标是在已有用户授权内连续推进、处理可恢复阻塞并在中断后恢复上下文；
Automation 的恢复便利性不得反向增加正常开发流程的门禁。

## 核心模型

长期 authority 只有用户指令、canonical contract / roadmap 与真实 Git/PR/CI/
Reviewer 事实。Automation 不维护 tracked task queue，不把施工状态写成
`docs/product/` 任务文件。

Automation 可以为当前 OPEN PR 维护一个可丢弃的：

```text
## Automation state
```

它只用于断点恢复，可记录：
- 当前 bounded objective / stage；
- canonical contract 路径；
- branch/base/PR；
- 已完成检查和最近 blocker；
- 两类 repair count；
- next safe action；
- 已知用户授权来源的引用/摘要。

该 section **不是 authority**：不能扩大 scope、授予 Git/merge/runtime 权限、
修改 canonical semantics、改变 acceptance、替代 CI/Reviewer，也不参与
Reviewer/Verifier approval identity 或 merge gate。它可以随运行进度更新，不需要
revision、digest、hash、冻结或独立 Verifier。

在一个已经由用户授权给 Automation 继续推进的 PR 上，controller 有一个窄 standing
permission：只维护 `## Automation state` section。这个权限不包含 title、base、
labels、close/reopen、merge 或其他 PR metadata 修改。

## 授权与控制边界

启动时从当前用户指令/仍适用的既有明确授权恢复范围、完成终点以及
implementation、branch/worktree、stage/commit/push/fetch/PR/merge 的动作权限。
Automation state 可以帮助定位授权来源，但不能作为授权来源本身。

缺失动作仍未授权。需要补权限时先完成可做的只读调查，报告具体缺口，再请求用户。
控制者选择、冻结、派发和检查门禁，不直接修改 production/tests。沿用正常角色和
`docs/agents/model-routing.md`；默认串行、一个 writer。

worker 只接收当前 bounded execution handoff、必须打开的 governing contract、
真实动作授权、验收、停止条件和累计修复计数。worker 不加载本协议或后续任务，
不创建后代、不切换角色、不自行扩大公共契约。

## 启动与恢复

每次运行：

1. 核对 master/base、已有 branch/PR、HEAD、dirty state 和 writer。
2. OPEN PR 优先恢复：先读 canonical contract、真实 diff、CI/review、当前 Git
   target，再把 `## Automation state` 作为提示。
3. state 与 Git/contract/user authority 冲突时，以 Git/contract/user authority 为准，
   丢弃或修正 state；绝不根据 state 推导新权限。
4. GitHub 已报告 `MERGED` 的历史 PR 默认视为 review gate 已满足，不因缺旧 marker
   重审。
5. later revert、明确 blocker 或用户要求重开时另建 bounded work。

工具/额度中断不撤销仍适用的用户批准。用户撤销/缩小范围、到达授权终点或责任实质
变化时停止继续。意外 HEAD/dirty state/writer 先只读定位，不覆盖工作。

### Legacy local queue 一次性接管

旧 `docs/automation/task-queue/*.md` 只作为兼容输入，不再是 authority。

- 已有对应 OPEN/MERGED PR：旧文件 superseded；
- 无对应 PR 且任务仍在现有用户授权：把必要内容转换成当前 execution handoff；
  创建 PR 后可摘要进 `## Automation state`；
- 无法唯一确定 contract/scope/权限：STOP；
- 禁止创建新的 legacy queue item。

旧目录继续被 `.gitignore` 忽略仅为兼容接管。

## 选择下一任务

没有待恢复 OPEN PR 时：

1. 读 roadmap 确定当前用户范围内的 active capability；
2. 打开 capability canonical contract；
3. 用 contract 实施顺序/前置 + merged PR/runtime facts 判断 NEXT；
4. 生成最小 bounded execution handoff；
5. 无法唯一判断、需要新产品决策或超出用户 continuation authority 时 STOP。

完成依据是 merged PR 与 canonical current-state amendment，不看 task 文件名或
Automation state。

## 执行

```text
canonical contract + Git facts + user authority
→ bounded Executor handoff
→ implementation/tests + required durable docs
→ checks + authorized commit/push/PR
→ current-head/current-target standing CI
→ only if CI has a real acceptance gap: Verifier
→ Independent Reviewer
→ blocking finding: same-PR repair -> new-head CI -> fresh review
→ APPROVE
→ authorized merge
→ refresh master/roadmap/contract
```

Automation state 只记录恢复进度，不增加任何一步门禁。更新该 section 不改变 Git
head，也不使已有 Reviewer approval 失效；真正改变 tracked target、canonical truth
或实现 diff 才按正常规则触发新的 CI/review。

Executor 的 STOP 结束 worker assignment，controller 可以在 Automation continuation
范围内继续等待 CI、派发 Reviewer/Verifier、组织 bounded repair，直到授权终点。
独立审查必须使用与实现 assignment 分离的 Reviewer 上下文。

## 先解决阻塞

先做有界诊断，区分 patch-caused、confirmed pre-existing、环境/工具问题和
契约/授权问题。优先派发已有授权内的最小 Executor 修复，重跑失败检查与直接
受影响回归，然后恢复原任务；失败本身不产生新权限。

### 已确认既存验证失败的有限例外

仅显式 Automation 运行适用；普通角色默认停止规则不变。确认既存需要可信 base
证据及因果判断：相同环境/命令的隔离 base 复现，或足以直接证明根因的历史/代码
证据；仅“相关文件未改”不足。

- 无关额外检查失败：所有必需检查已通过，且失败不涉及当前关键语义/安全边界、
  不损害验收可信度时，可记录 `PRE_EXISTING / NON_BLOCKING` 后继续，不修无关代码。
- 直接必要的机械验证修复：未改变的 governing contract 能证明唯一正确修复，
  改动极小且只涉及 test/fixture/验证编译联动，不改变 production semantics，
  不删除/放宽断言，并在已有责任/权限内，才派发 Executor 修复并复验。
- schema literal、enum expected-list、fixture 不天然是机械修复。涉及冻结兼容性、
  持久化、并发、安全或验收定义时不适用该例外。

两类 repair budget 继承 `AGENTS.md`，worker/head/重启不会重置。必需测试或 CI
失败始终阻止交付/merge；不得跳过、过滤或降低 required gate。

### 无法在现有授权内解除时

根因不明、需要新契约/授权、跨责任/另一 writer、必需验证无法可信完成或预算耗尽
时，停止受影响写入/交付，保留证据并报告最小所需决定。其他任务只有在已证明独立、
契约允许乱序且 continuation authority 覆盖时才能推进。

## Merge gate

Automation 使用和正常流程完全相同的 merge gate：

- final-head/current-target `PR contract checks` SUCCESS；
- final Reviewer `[REVIEW APPROVAL]` 对应 final head/current base，P0/P1/P2 = 0；
- 只有真实 CI coverage gap 时才需要对应 head/base 的
  `[VERIFICATION APPROVAL]`；
- canonical/durable docs 与 accepted diff 一致；
- PR 可合并；
- 用户已有明确 merge authority。

`## Automation state` 永远不参与 merge 判断。

合并后核实真实结果，再按已有授权刷新 master/contract/roadmap；仅在用户批准的
continuation 内选择下一任务。

## 交接

结束时报告 capability、PR/base/head、真实 Git actions、CI、Reviewer/Verifier
evidence、repair counts、阻塞与下一安全动作。Automation state 只是恢复提示，
不作为完成证据。