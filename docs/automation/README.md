# 按需自动化协议

入口：用户明确输入 `角色：自动化`。本协议用于赶时间或无人值守时的连续推进；普通角色默认不读取本文件。

## 1. 运行范围与授权

Automation 不维护第二套 task queue。正式 staged work 直接以
`docs/product/<capability>/` 为 focused contract directory：

```text
docs/product/
├─ capability-a/
│  ├─ 00-contract.md
│  ├─ 10-task-a-完成.md
│  ├─ 20-task-b.md
│  └─ ...
└─ capability-b-完成/
```

`*-完成/` 表示整个 capability 已关闭，正常调度直接跳过且不读取内部文件。
普通目录表示 capability 尚未关闭；其内部 `*-完成.md` 表示已关闭 package。

一次运行的 implementation、branch-create、stage、commit、push、fetch、
PR-create、merge、Documentation Closure 等权限仍来自用户明确授权。目录名、
文件名和完成后缀只表达调度状态，不授予 Git、runtime、provider 或 scope 权限。
已授予的同任务权限持续有效，不在每个 checkpoint 重复询问。

用户可临时缩小范围，例如：

```text
角色：自动化
本次只完成 home-training-v3 的下一个未完成 package，合并后停止。
```

## 2. 启动与恢复

启动时先恢复当前授权范围内已经存在的未完成 branch / PR，而不是先选新任务：

1. 核对 repository、base、branch、HEAD、dirty state、已有 writer 与远端 PR。
2. 对 OPEN PR 恢复原任务，不创建重复 PR。
3. 对 GitHub 已报告为 `MERGED` 的历史 PR，默认视为其 review gate 已通过；
   不因旧流程缺少 `[REVIEW APPROVAL]` 评论而重新审查或重复实现。
4. 若存在 later revert、明确未解决 blocker 或用户要求重开，则作为新的 bounded
   work 处理，而不是改写历史 merged 状态。

MERGED 默认审查通过只用于历史恢复；它绝不允许 OPEN PR 跳过当前 Reviewer gate。

### Legacy local queue 一次性接管

旧版本允许用户在本地被忽略的 `docs/automation/task-queue/*.md` 发布尚未启动
的任务。升级到本协议后，这些旧文件不得被静默遗弃，也不得继续作为第二套
queue 长期运行。

每次启动在选择新任务前，若本地仍存在 `docs/automation/task-queue/`：

1. 只列文件名；忽略 README 与明显完成项，不直接执行旧 package。
2. 对每个未完成 `*.md`，先检查是否已经存在等价的
   `docs/product/<capability>/<package>.md` 或对应 branch/PR。
3. 已有正式 package 或 branch/PR：旧文件视为 superseded，只报告清理建议，
   不重复创建任务。
4. 没有正式 package：若当前用户授权明确允许迁移该任务，则把 bounded scope
   迁入正确 focused contract directory，并按当前规则补齐 contract、acceptance
   与 Documentation responsibility；迁移后不再读取旧副本。
5. 无法唯一映射 capability、缺少 governing contract 或迁移需要扩大 scope 时
   STOP 并报告待迁移文件；绝不静默跳过，也不擅自执行旧 queue item。

只有确认 legacy 目录不存在或不再含未接管任务后，才进入正常 contract-directory
调度。禁止创建新的 legacy queue 文件。

## 3. 选择下一个任务

没有待恢复工作时：

1. 先只列 `docs/product/` 名称。
2. 跳过所有 `*-完成/`，不读取内部文件。
3. 只把包含 `00-contract.md` 的未完成目录视为 staged capability 候选；普通
   legacy 单文件 contract 不因此自动进入连续执行。
4. 用当前用户范围、roadmap、contract prerequisites 与 Git/PR 事实确定唯一
   focused capability。无法唯一确定时 STOP，不创建第二套 queue 来消歧。
5. 进入 focused directory 后仍先只列文件名：跳过 `00-contract.md` 和
   `*-完成.md`，按数字前缀作为相对顺序。
6. 只打开当前选中的一个 package 与 `00-contract.md`。不要为寻找 NEXT
   把所有 package 正文读入上下文。
7. 较前 package 被硬前置阻塞时先处理阻塞；只有 contract 明确允许乱序且后项
   被证实独立时才选择后项。

focused contract directory 本身就是 queue。禁止再创建或维护
`docs/automation/task-queue/`、Task-ID、READY/ACTIVE/DONE 状态表或独立
execution-plan 文档来重复同一状态。

## 4. 实现、验证、审查与修复

Automation 复用正常流程：

```text
冻结当前 package、Documentation responsibility 和权限
→ Executor 实现、机械检查、已授权 PR 交付，然后 STOP
→ 当前 merge target 的 standing PR CI
→ 仅当 CI 无法可信覆盖 required acceptance 时独立 Verifier
→ 强制 Independent Reviewer
→ Reviewer 在 PR 发布本轮 verdict evidence
→ 有阻塞 finding：同任务 repair、复验、fresh targeted review
→ provisional APPROVE
→ 已授权 Documentation Closure
→ 当前 package 重命名为 *-完成.md
→ 若为最终 capability closure 且所有 sibling packages 已完成：
   capability/ 重命名为 capability-完成/
   并同步所有明确列出的 durable external references
→ final-head PR CI
→ final Reviewer [REVIEW APPROVAL]
→ 已授权 conditional merge
→ 刷新 master 与 docs/product/ 目录
→ 下一个已授权任务
```

standing `PR contract checks` 是默认 deterministic verification authority。
只有 required acceptance 存在可信 CI coverage gap，或用户/Reviewer 显式要求，
才派 Verifier；高风险本身不重复触发 Agent verification。

Reviewer / Verifier assignment 明确指向现有 PR 时，每个完成 pass 默认允许发布
一次本角色 evidence，不需要 task package 额外写 comment/review-submit 字段。
Reviewer 使用 `[REVIEW APPROVAL]` / `[REVIEW REQUEST_CHANGES]` /
`[REVIEW INCONCLUSIVE]`；Verifier 使用 `[VERIFICATION APPROVAL]` 或
`[VERIFICATION RESULT]`。这不授权修改 PR title/body、close/reopen 或 merge。

两类 repair budget 继承 `AGENTS.md`；换 agent、推进 head 或重启不会重置。

## 5. 阻塞与既存失败

失败本身不是立即交回用户的理由。先有界区分：

- 当前改动导致；
- 已确认既存且与当前 acceptance 无关；
- environment/toolchain；
- contract/authority；
- 原因不明。

当前改动及直接必要联动由对应 Executor 在授权范围内修复并复验。
既存失败只有在可信 base 证据证明因果无关、且不削弱当前验收时才可记录
`PRE_EXISTING / NON_BLOCKING`；required CI / required acceptance 仍不得绕过。

根因不明、需要新 contract/authority、跨 responsibility、必需验证无法可信完成
或预算耗尽时 STOP。不得为了持续运行而跳过当前阻塞去消费不确定的后续 package。

## 6. Conditional merge 与 completion marker

OPEN PR 合并前必须同时满足：

1. writer 已停止，Documentation responsibility 已关闭；
2. final head + current base/merge target 的 `PR contract checks` SUCCESS；
3. final head 上存在适用的 `[REVIEW APPROVAL]`，P0/P1/P2 为 0；
4. 需要 Verifier 时存在适用的 `[VERIFICATION APPROVAL]`；
5. PR 可合并、scope/contract 无 blocker，且已有明确 merge authority。

package 的 `-完成.md` rename 在 provisional APPROVE 后进入同一
Documentation Closure，并仍需 final-head CI + final Reviewer approval。
capability directory 的 `-完成/` rename 只允许在最终 closure package 中执行：
所有 sibling task package 已关闭，directory 本身被列为 `UPDATE`，所有 durable
external references 也以 exact path 列为 `UPDATE` 并在同一 closure 同步。

内部 package 指向同目录 contract 时优先使用相对路径 `./00-contract.md`，
避免 capability directory 最终改名后内部引用失效。

合并后核对真实 merge 结果并刷新 master。默认分支看到 `*-完成.md` 或
`*-完成/` 后，后续 Automation 可仅凭名称跳过，不必打开正文。

## 7. 交接

结束时只报告必要事实：当前 capability/package、base/branch/head/PR、实际 Git
动作、final-head CI、Reviewer verdict/evidence、必要 Verifier evidence、
Documentation Closure、已用 repair counts、仍阻塞点与下一安全动作。
