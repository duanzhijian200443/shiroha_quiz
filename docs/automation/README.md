# 按需自动化协议

入口：用户明确输入 `角色：自动化`。本协议用于赶时间或无人值守时的连续推进；普通角色的默认阅读清单不包含本目录。

## 1. 简单调用与运行范围

```text
角色：自动化
```

加载本协议和 `task-queue/README.md`，恢复本次授权范围内的未完成任务，然后消费用户发布的队列。已有授权持续有效，不在每次交付、修复或合并前重复询问。

临时缩小范围可以直接写：

```text
角色：自动化
本次只完成 B2，合并后停止。
```

模式在同一任务中持续，直到用户明确结束、授权终点到达或无法安全继续。进入 worker 阶段不改变控制者角色，也不把 worker 切换成自动化角色。

本协议不预置 Git 或真实 runtime 权限。一次批准的默认授权可以来自用户明确批准的配置或任务包；单行调用沿用那份授权。没有已有授权时，先准备具体、可审阅的任务和权限清单，再一次性请求缺失授权。仅有 `READY`、`Auto-Merge: yes`、路线图记录或本文件不能证明用户批准了相应动作。

运行前简要记录：

- 用户批准的任务范围、完成终点，以及是否允许队列完成后继续指定 roadmap 阶段；
- implementation、branch-create、worktree、stage、commit、push、fetch、PR-create、merge 的实际授权；
- PR title/body 更新、评论、review submission、close/reopen 等确实需要的独立授权；
- 适用的修复边界和已使用预算。省略的权限仍未授权，显式禁止优先。

这些是本次运行事实，保存在交接上下文中；不写成长效产品契约或记忆。授权只覆盖指定仓库、目标和责任，不传递到 provider、私有文档、tag 或 release。

## 2. 最小阅读与控制边界

控制者遵循 `AGENTS.md` 的共享上下文路由，读取本协议、队列协议和候选任务。先按文件头筛选，再读取当前任务全文、governing contract 和 active execution plan；仅在已授权续作需要时读取对应 roadmap。每次冻结目标前核对当前 Git、必要的远端 PR 状态、dirty state 和已有 writer。

控制者负责选择、冻结、派发、接收交接、检查合并条件和推进，不直接修改 production/test 文件。正常 `角色：总控` 的权限和停止边界不变。

委派使用现有角色及 `docs/agents/model-routing.md`。默认串行，一个任务只有一个 writer；并行及 worktree 仍需已有授权和隔离。子任务不得创建后代、切换角色、扩大责任或自行决定未冻结的公共契约。

worker 只收到：

- 当前 bounded package、必要 contract/plan 路径及必须自行打开的 governing source；
- 从真实用户授权继承的具体动作、目标、ownership、验收和停止条件；
- 实际验证证据，以及需要继承的修复计数。

worker 不加载整个自动化协议或后续队列。若当前任务包本身在本目录，可读取该任务文件；不因此读取相邻任务。控制者必须把适用的有限例外写入当前包，不能仅指示“自动化模式所以可以”。

## 3. 选择任务与恢复

遵循 `task-queue/README.md`：优先恢复未完成任务，之后按文件名优先级和硬依赖选择用户任务。任务顺序服从当前契约、已接受前置能力和 Git/PR 事实。

当前任务受阻时，先定位、解决并验证阻塞，再恢复当前任务。不能仅因队列没有可执行任务而去 roadmap 找新工作。

只有用户任务全部完成或取消、没有未取消任务的遗留 PR/阻塞，而且用户已授权某个 roadmap 续作范围时，才从当前契约和执行计划推导该范围内唯一明确的 NEXT。不能确定、阶段尚未验收或需要新设计决策时，结束推进并报告需要的决定。已取消任务的遗留 PR 单列交接，不继续、不擅自关闭。

派生任务使用现有 writable-package 模板，在本次上下文中冻结为一个 bounded package；不写回用户队列，也不把自身规划当成新增授权。每完成一个 checkpoint 都重新核对下一任务，不无限提前规划。

启动或中断恢复时，先核对任务身份、分支、当前 head、PR 和真实 merge 状态。对已经合并的任务不重复实施；对未合并分支恢复原任务，不重新创建同一 PR。遇到意外 HEAD/dirty state/其他 writer，先只读核对原因；不得 reset、restore、rebase 或覆盖其工作来恢复运行。

额度、环境或可用工具不足时，留下精简交接：任务、阶段、branch/base/head/PR、未完成检查、阻塞证据、两类修复计数和下一安全动作。额度或工具导致的中断本身不撤销仍处于用户明确范围与完成终点内的授权；恢复时重新核对 scope、Git/PR 事实和授权终点。用户明确结束、授权终点已到达、显式撤销/缩小权限，或目标/责任变化使原批准不再适用时，该批准失效，不得继续沿用。

## 4. 实现、验证、审查与修复

```text
冻结当前任务和权限
→ Executor 实现、机械验证、已授权交付，然后 STOP
→ 必要时独立 Verifier
→ 独立 Reviewer
→ 有阻塞 finding：同任务修复、复验、fresh targeted review
→ 控制者检查并执行已授权 conditional merge
→ 刷新 base、契约、任务状态
→ 下一已授权任务
```

Executor 的 STOP 结束 worker assignment，控制者继续调度。Reviewer/Verifier 仍只读，不能修复或合并；控制者不能用自己的实现自检替代独立审查。

独立审查使用与 implementation assignment 分离的审查上下文，读取停止 writer 后的固定目标、原始任务、契约和必要证据。同一模型可以承担不同 assignment；仅在原实现上下文中声明“现在我是 Reviewer”不构成独立审查。

Verifier 只按 `AGENTS.md` 的风险触发条件插入。保留 focused 检查、只读 check helper、Windows 串行 Flutter tests、真实执行结果和 `NOT_EVALUATED` 全局默认值，不为自动化重复无关扫描或运行完整全仓验收。

两类修复预算继承 `AGENTS.md`，切换 worker、推进 head 或重启不会重置计数。修复后重跑失败检查和直接受影响的回归。

## 5. 先解决阻塞

失败本身不是立即交回用户的理由。先做有界诊断，区分当前改动导致的失败、已确认既存失败、环境/工具问题和契约/授权问题。解决动作由对应 Executor 执行，仍需真实授权。

### 当前改动及直接必要联动

根因具体、在同一责任内、保持冻结语义且不弱化验证时，主动修复并复验。必要联动路径遵循共享 ownership 规则；严格 whitelist、另一 writer 的路径或新的产品能力仍不可越过。

### 已确认既存失败的有限例外

本节只适用于显式自动化运行及携带本节条件的派发包。普通任务继续使用现有失败规则。

确认既存需要可信的 base 证据和因果判断。可使用相同环境/命令的隔离 base 复现，或足以直接证明根因的历史与代码证据；仅“测试和 enum 未修改”不足。额外 worktree、网络或 runtime 验证仍需对应授权，不为证明既存擅自执行。

- 无关的额外检查失败：只有不涉及当前关键语义/安全边界、不影响当前验收可信度，且所有必需检查已通过时，才记录为 `PRE_EXISTING / NON_BLOCKING` 后继续；不自动修复无关代码。
- 直接必要的机械验证修复：当唯一正确的修复可由未改变的 governing contract 证明、修改极小且只涉及测试/fixture 或验证编译联动、不改变 production semantics、不删除或放宽断言时，派发 Executor 修复并复验。必须在授权责任内；handoff 单列 `pre-existing verification repair`。纯机械清理按共享预算规则计数；需要选择行为、改变覆盖范围或不确定是否机械时，不能免计语义预算。
- schema literal、enum expected-list、fixture 不天然属于机械修复。它们涉及冻结兼容性、持久化、并发、安全或验收定义时，按对应风险处理，不能仅为变绿修改 expected 值。

必需测试或必需 CI 失败仍阻止完成交付和 merge。不得用 `PASS_WITH_PRE_EXISTING_ISSUES`、跳过测试、过滤失败、降低 CI 要求或改变 required 状态绕过门禁。

### 无法自行解除时

根因不明、需要新契约/授权、跨责任、必需验证无法可信完成或预算耗尽时，停止受影响写入和交付，保留证据并报告最小所需决定。不要无限重试。

不因阻塞自动跳过当前任务。只有调查已确认当前阻塞无法在现有范围内解决，且其他已授权任务被证明确实独立、契约允许乱序时，才可推进该独立任务；原任务仍是未完成，队列不得宣称完成。

## 6. Conditional merge 与 checkpoint

控制者只在已有明确 merge 授权且当前任务允许自动合并时合并；`Auto-Merge: no` 或用户指定的交付停止点仍生效。用户已批准条件式 merge 后，不再逐个请求确认。合并前同时满足：

1. writer 已停止；当前 PR head 正是 Reviewer 批准且必需检查覆盖的 head。
2. 必需本地检查和 required CI 全部通过；仓库自动触发的 `PR contract checks` 是 Automation conditional merge 的 standing required CI gate，即使 GitHub branch protection 没有把它配置为 required status。接受的自动 PR run 必须对应当前 PR head 与当前 base 形成的当前 merge target；旧 head、旧 base/merge target、未运行、失败或过期结果都不能当作成功。
3. 需要 Verifier 时，其固定目标结果为 PASS；独立 Reviewer 为 APPROVE。
4. 当前任务无开放 P0/P1/P2，无未解决的契约、scope 或前置验收阻塞。
5. 目标 base/branch/repository 正确、PR 可合并，使用已授权且符合仓库 Git 规则的合并方式；不采用被禁止的 squash/rebase 或绕过分支保护。

修复推进 head 后，旧批准失效，需要 fresh targeted closure。base 在审查后变化时，核对相关契约/依赖差异并重新确认当前 merge target 的 standing `PR contract checks` 已成功；旧 base/merge target 的 CI 结果不能满足自动合并门禁。Reviewer/Verifier 的旧语义证据只有在确认仍适用时才可继续复用，否则重新冻结受影响审查。意外漂移或无法确认的合并状态不允许盲目重试。

合并后核对真实 merge 结果，按已授权 fetch 刷新远端 base，再读取当前任务所需契约/计划和队列。只有该 checkpoint 已满足独立验收和接受条件，才开放下游依赖。不能仅凭提交存在就宣称验收通过。

结束时报告已完成、仍阻塞、实际 Git 动作、必要检查/审查和恢复入口。具体 SHA/CI/运行状态属于 Git 和本次交接，canonical documents 只按已授权职责更新发生变化的持久事实。
