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

控制者遵循 `AGENTS.md` 的共享上下文路由，读取本协议和队列协议。选择任务时先只列文件名，跳过 `*-完成.md`，再只读取当前候选任务、governing contract 和必要仓库事实；不要预读整队列。仅在已授权续作需要时读取对应 roadmap。每次冻结目标前核对当前 Git、必要的远端 PR 状态、dirty state 和已有 writer。

控制者负责选择、冻结、派发、接收交接、检查合并条件和推进，不直接修改 production/test 文件。正常 `角色：总控` 的权限和停止边界不变。

委派使用现有角色及 `docs/agents/model-routing.md`。默认串行，一个任务只有一个 writer；并行及 worktree 仍需已有授权和隔离。子任务不得创建后代、切换角色、扩大责任或自行决定未冻结的公共契约。

worker 只收到：

- 当前 bounded package、必要 contract 路径及必须自行打开的 governing source；
- 从真实用户授权继承的具体动作、目标、ownership、验收和停止条件；
- 实际验证证据，以及需要继承的修复计数。

worker 不加载整个自动化协议或后续队列。若当前任务包本身在本目录，可读取该任务文件；不因此读取相邻任务。控制者必须把适用的有限例外写入当前包，不能仅指示“自动化模式所以可以”。

## 3. 选择任务与恢复

遵循 `task-queue/README.md`。先恢复已经存在的未完成 branch/PR；只有没有
待恢复工作时才选新任务。

选择新任务时先只列文件名。对本地 queue 和正式 contract 目录都执行同一
快速规则：`*-完成.md` 直接跳过且不打开；其余候选按数字文件名前缀作为
相对优先级，再服从 governing contract、硬前置和 Git/PR 事实。只打开最终
选中的当前 package，不预读后续任务。

当前任务受阻时，先定位、解决并验证阻塞，再恢复当前任务。不能仅因本地
queue 没有可执行任务就自行扩大范围。

只有本地用户任务都已完成、没有遗留未完成 PR/阻塞，而且用户已授权某个
roadmap/contract continuation 时，才扫描该 focused contract 目录中的正式
task packages。正式 package 与 `00-contract.md` 同目录；不再依赖单独的
execution-plan 文档。若目录没有 package，可从 contract/roadmap 推导一个
bounded package 留在本次上下文，但不能把自身规划当成新增授权。

不能唯一、安全确定下一任务，阶段需要新产品决策，或 contract 与 Git 事实
冲突时，结束推进并报告需要的决定。每完成一个 checkpoint 都刷新 base、
contract directory 和 Git/PR 事实，不无限提前规划。

启动或中断恢复时，先核对任务身份、分支、当前 head、PR 和真实 merge 状态。对已经合并的任务不重复实施；对未合并分支恢复原任务，不重新创建同一 PR。遇到意外 HEAD/dirty state/其他 writer，先只读核对原因；不得 reset、restore、rebase 或覆盖其工作来恢复运行。

额度、环境或可用工具不足时，留下精简交接：任务、阶段、branch/base/head/PR、未完成检查、阻塞证据、两类修复计数和下一安全动作。额度或工具导致的中断本身不撤销仍处于用户明确范围与完成终点内的授权；恢复时重新核对 scope、Git/PR 事实和授权终点。用户明确结束、授权终点已到达、显式撤销/缩小权限，或目标/责任变化使原批准不再适用时，该批准失效，不得继续沿用。

## 4. 实现、验证、审查与修复

Automation 复用正常流程，不维护第二套验收规则：

```text
冻结当前任务、Documentation responsibility 和权限
→ Executor 实现、机械检查、已授权 PR 交付，然后 STOP
→ 当前 merge target 的 standing PR CI
→ 仅当 CI 无法可信覆盖 required acceptance 时独立 Verifier
→ 强制 Independent Reviewer
→ 有阻塞 finding：同任务修复、复验、fresh targeted review
→ provisional APPROVE 后执行已授权 Documentation Closure（含 tracked task package `-完成` 重命名）
→ final-head PR CI + final Reviewer [REVIEW APPROVAL]
→ 控制者检查并执行已授权 conditional merge
→ 刷新 base、契约、任务状态
→ 下一已授权任务
```

Executor 的 STOP 结束 worker assignment，控制者继续调度。控制者不能用
自己的实现自检替代 standing CI、必要 Verifier 或独立 Reviewer。

独立审查使用与 implementation assignment 分离的上下文，读取停止 writer
后的固定目标、原始任务、契约和必要证据。同一模型可以承担不同
assignment；仅在原实现上下文中声明“现在我是 Reviewer”不构成独立审查。

standing `PR contract checks` 是默认 deterministic verification authority。
只有 required acceptance 存在 CI coverage gap 时才派 Verifier；高风险但
已经被明确 hard-failing CI matrix 覆盖的行为不重复消耗 Verifier。
Reviewer 和 Documentation Closure 完全复用 `AGENTS.md` / 角色规则。

两类修复预算继承 `AGENTS.md`，切换 worker、推进 head 或重启不会重置
计数。修复后重跑失败检查和直接受影响的回归，并重新建立被 head 变化
失效的 CI/Review/Verifier 证据。

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

控制者只在已有明确 merge 授权且当前任务允许自动合并时合并；
`Auto-Merge: no` 或用户指定的交付停止点仍生效。用户已批准条件式 merge
后，不再逐个请求确认。Automation 不降低正常流程的 merge gate。

合并前同时满足：

1. writer 已停止，Documentation responsibility 已关闭；最终 PR head 正是
   final Reviewer approval 与必需检查覆盖的 head。
2. 当前 PR head + 当前 base/merge target 对应的自动 `PR contract checks`
   全部 SUCCESS；branch protection 未配置 required status 也不构成例外。
3. 独立 Reviewer 已在 PR 上记录针对 final head 的 `[REVIEW APPROVAL]`，
   且 P0/P1/P2 为 0。
4. 只有 standing CI 无法可信覆盖 required acceptance 时才要求 Verifier；
   一旦要求，其适用的 `[VERIFICATION APPROVAL]` PR evidence 必须存在。
5. 无未解决 contract/scope/前置验收阻塞，目标 base/branch/repository 正确、
   PR 可合并，并使用已授权且符合仓库 Git 规则的合并方式。

修复或 Documentation Closure 推进 head 后，按共享规则重新建立 final-head
CI 和 Review 证据。旧 Verifier PASS 只有在后续变化严格限于已授权的
documentation/PR-metadata closure、且 Reviewer 明确确认 verified behavior
未变时才可沿用；否则重新 Verifier。base 漂移同样必须重新确认当前
merge target 的 standing CI，不能复用旧 base 的结果。

合并后核对真实 merge 结果；若当前任务来自本地 ignored queue，再把该本地
文件重命名为 `-完成.md`。随后按已授权 fetch 刷新远端 base，再读取当前
任务所需 contract directory 和 queue。只有该 checkpoint 已满足独立验收和接受条件，
才开放下游依赖。不能仅凭提交存在就宣称验收通过。

结束时报告已完成、仍阻塞、实际 Git 动作、final-head CI、Reviewer PR
approval、必要 Verifier evidence、Documentation Closure 和恢复入口。
具体 SHA/CI/运行状态属于 Git 和本次交接，canonical documents 只按已授权
职责更新发生变化的持久事实。
