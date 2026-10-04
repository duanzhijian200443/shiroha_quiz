# 用户发布的自动化任务队列

本目录只用于用户临时发布的本地任务包。普通角色不扫描本目录；显式
`角色：自动化` 才读取。若某项工作已经在
`docs/product/<capability>/` 下有正式 task package，不要为了调度再复制一份
同内容到本目录；在已授权的 roadmap/contract continuation 中直接消费正式
package 即可。

## 1. 文件名就是调度信息

不使用 `Task-ID`、`Status`、`READY`、`ACTIVE`、`DONE` 等额外状态字段。

示例：

```text
10-b2-training-config-ui.md
20-b3-study-activity-runtime.md
30-b4-home-v2.md
```

数字前缀表达相对优先级，不覆盖 governing contract、硬前置或 Git/PR 事实。
文件路径/文件名已经足够标识当前任务，不再维护第二套任务 ID。

完成后的本地文件改名：

```text
10-b2-training-config-ui.md
→ 10-b2-training-config-ui-完成.md
```

Automation 扫描目录时先只列文件名：

- `README.md`：协议文件，忽略；
- `*-完成.md`：已关闭，直接跳过，不打开正文；
- 其他 `*.md`：待执行候选。

本地 queue 已被仓库 `.gitignore` 忽略，因此完成改名不要求 Git 提交。
只有对应实现 PR 已确认 merge 后，控制者才把本地 queue 文件改成
`-完成.md`。

## 2. 任务正文

正文直接使用 `docs/agents/README.md` 的 writable-package 结构，或给出
等价的明确用户指令。无需固定头部，也不要为了调度增加 Task-ID/Status。

任务可以写自然语言前置，例如：

```text
Prerequisites:
- B1 已合并；
- governing contract 的 CP2-I 前置满足。
```

前置可由 contract、Git/PR 和当前仓库事实推导时，不要求重复抄写。
Risk、Auto-Merge、Git/PR 权限等只有在任务确实需要覆盖当前运行默认值时
才写；权限始终来自用户明确授权，文件存在本身不授予权限。

## 3. 选择与恢复

1. 启动时先恢复当前仓库里已经存在的未完成 branch/PR；不要仅凭目录文件
   又创建同一任务。
2. 没有待恢复工作时，只列 queue 文件名并跳过所有 `*-完成.md`。
3. 对剩余候选按文件名自然排序；在准备打开候选前先用 contract/Git 事实
   判断明显硬前置。
4. 只打开当前选中的一个任务包。不要为了找 NEXT 把整个 queue 全部读入。
5. 较前候选被前置阻塞时先处理阻塞；只有 contract 明确允许乱序且后项
   被证实独立时才选择后项。
6. queue 中没有待办后，只有用户已经授权 roadmap/contract continuation
   时，才扫描当前 focused contract 目录下的正式 task package；同样先看
   文件名、跳过 `*-完成.md`，再只打开当前候选。
7. 无法从 contract、Git/PR 和候选文件唯一、安全确定下一步时才 STOP。

Git/PR/CI/Reviewer evidence 是精确执行事实；文件名后缀是快速调度标记，
不是替代 Git 历史的审计数据库。

## 4. 完成标记

正式 tracked task package 与本地 queue 的完成时机不同：

- 正式 package：在实现已通过 required verification、Reviewer 已达到
  provisional APPROVE 后，由授权 Documentation Closure 在 PR head 上把
  `NN-name.md` 重命名为 `NN-name-完成.md`；随后仍需 final-head CI 和
  final Reviewer approval。只有 PR merge 后，默认分支才会看到完成后缀。
- 本地 queue：等待对应 PR merge 已确认后再本地改名为 `-完成.md`。

因此默认分支目录本身就是低成本进度视图：看到 `-完成.md` 即可跳过，
不必读取文件正文。
