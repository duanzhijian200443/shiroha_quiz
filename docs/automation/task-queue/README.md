# 用户发布的自动化任务队列

本目录存放用户预先发布的任务包，由显式自动化运行的控制者选择。普通角色不扫描队列；被派发的 worker 只读取当前任务包。

本 README 的模板和示例不是可执行任务。目录中没有任务文件时，不代表获准执行整个 roadmap。

## 1. 任务身份与最小头部

每个任务使用一个 Markdown 文件，保持稳定 `Task-ID`。文件名表达相对优先级，例如 `010-b1-taskcenter-backend.md`、`020-b2-training-config-ui.md`；不要另外维护 `Order` 字段。

任务头部：

```text
# <任务标题>

Task-ID: <稳定且唯一的任务 ID>
Status: READY
Depends-On: none | <任务 ID 列表>
Risk: T1 | T2 | T3
Auto-Merge: yes | no
Authorization: <明确用户授权的来源/适用范围>
```

正文使用 `docs/agents/README.md` 的唯一 writable-package 模板，不另维护第二份模板。包含授权 base、专用 branch/create-or-reuse、contract/plan、ownership、冻结语义、acceptance、validation、具体 Git 权限和修复计数；必要独立验收属于 acceptance。

Base 可以是固定授权值，或用户明确允许开工时冻结的远端 base。需要的 fetch、worktree、PR metadata 更新等独立动作另列实际授权；权限可以引用本次已批准运行范围，由控制者派发时展开。

`READY` 表示用户已发布任务，`Auto-Merge` 表示任务偏好；均不单独授予 implementation/Git 权限。用户必须明确批准队列或对应任务的执行及所需动作。自动生成文件、修改状态或机器提交不构成用户发布/授权。

## 2. 五个状态与事实核对

| Status | 含义 |
|---|---|
| READY | 用户已发布，尚未开始；开工仍需权限、前置条件核对 |
| ACTIVE | 已开始，优先恢复 |
| BLOCKED | 当前不能继续，优先定位并解除阻塞 |
| DONE | 已满足任务验收，且其 PR 已真实合并 |
| CANCELLED | 用户已取消，不再执行 |

同时只有一个 ACTIVE task。未知/重复 Task-ID、未知状态、缺失依赖或依赖环需要报告，不凭猜测启动有关任务。

Status 是调度提示，Git/PR 和固定目标验收证据决定实际完成状态。恢复时关联 Task-ID、分支/PR、head 和接受条件：

- PR 已合并、文件仍是 READY/ACTIVE：核对任务范围和验收后视为已完成，不重复实施。
- 文件写 DONE、PR 未合并或验收未满足：不能放行依赖，报告状态不一致。
- 已存在未完成 PR：恢复原分支/任务，不另建重复 PR。
- BLOCKED 不自动变 CANCELLED/DONE；解除后可恢复 ACTIVE。
- CANCELLED 的遗留分支/PR 不继续，不擅自关闭或删除。

任务文件保持原路径，不通过移动文件表示状态。仅在已授权的队列文件责任内更新状态；不要求每次切换阶段都产生 Git 提交，不要求为标记完成单独创建 PR。

真实 merge commit 只有合并后才存在，不在实施 PR 中预填。可选的 PR/merge 关联记录必须来自已确认事实；中断恢复交接可保留在运行上下文，不创建第二套产品状态 authority。

## 3. 选择与依赖

1. 恢复授权范围内 ACTIVE、未完成 PR 或 BLOCKED 任务，先解决其阻塞。
2. 没有未完成当前任务时，扫描用户发布的 READY 文件头。
3. `Depends-On` 是硬约束；依赖满足要求对应任务已合并并通过必要验收，不仅是文件写 DONE。
4. 根据当前 base、governing contract、active execution plan、ownership 和实际接受状态判断候选是否可执行。
5. 可执行候选按文件名自然排序，数字段按数值比较；同一优先级按完整文件名排序。多个独立候选不因此 STOP，取优先级最前者。
6. 文件名不覆盖依赖或契约。较前任务前置条件不满足时先诊断；无法在现有授权内解除，才可选契约明确允许乱序且已证实独立的后续任务，并保留原阻塞。
7. 缺失依赖不是“没有依赖”；顺序/契约冲突无法解析时停止有关任务，不只凭文件名猜测。
8. 用户任务优先。用户队列全部完成或取消且没有遗留阻塞，才按控制协议检查是否存在已授权的 roadmap 续作范围。

自动派生的 NEXT 留在运行上下文，不写成用户发布的 READY 文件，也不增加本次授权。只读排序/扫描不授权改任务包中的契约、权限或依赖。

## 4. 发布与更新

用户发布任务时给出明确执行授权和范围；只需一次，不要求每个 checkpoint 重复确认。控制者在派发前冻结实际 base/head、动作权限、验收和修复计数。

用户更改当前任务的 scope、权限或 frozen semantics 时，在下一安全边界暂停旧 assignment，重新冻结受影响任务；已有审查证据是否仍有效按目标变化判断。无关队列文件变化无需重复当前任务验证。

每次成功合并是 checkpoint：核对合并事实、更新本次交接、刷新当前 base/契约并重新选择。队列完成必须没有遗留 ACTIVE/BLOCKED 或未取消任务的未完成 PR；跳过阻塞不能宣称整队列完成。CANCELLED 的遗留 PR 单列报告，不算作已完成交付。
