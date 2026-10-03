# Shiroha Quiz Home Training V3 Execution Plan

**契约入口：docs/product/home-training-implementation-freeze-v3.md**
**性质：派生执行附录；不定义或修改产品语义。**
**状态：实施中；P0、P1a、P1b、P1c 已完成，下一包为 P2a。**

本附录不授予 merge/tag/release 权限。每个写任务使用独立非默认分支；单写者默认不建 worktree，只有并行 writer、脏工作区隔离或 Coordinator 明确要求时才创建 worktree。commit/push/PR 仍按任务包或用户授权执行。

---

# A0. 当前交付状态

截至 master `a388b5c64261ad8cd014ca4282ee69e81c507fdd`：

| Package | Status |
|---|---|
| P0 | COMPLETE |
| P1a | COMPLETE |
| P1b | COMPLETE / CP1 passed |
| P1c | COMPLETE |
| P2a | NEXT |

当前 runtime schema：

```text
v29
```

v29 TrainingContent persistence / migration / B0 compatibility 已进入当前 runtime truth。v30 StudyActivity 与 v31 ImportTask event timestamps 仍为 planned。

以下 A 节保留最初规划基线，仅作为历史 planning evidence，不得覆盖本节 current delivery state。

---

# A. 规划基线

以下值继承 V2 最近一次只读核验记录。V3 文本修订本身没有重新声明这些 SHA 为永久当前事实。

| 项目 | 规划时记录 |
|---|---|
| Repository | duanzhijian200443/shiroha_quiz |
| GitHub master | 47c7f9b6c7f497958c57d068aefa9e03a2457f0d |
| local HEAD | 1356143738a4c42ec3c92851f731a951f58c3cc9 |
| local branch | codex/arch-debt-03a-practice-dependency-decoupling |
| local tree | 92d79318fed5bc2ffe9e58b3eafdd8e79367af4c |
| schema | v28 |
| prior verification | static read / remote compare / Drive review |
| not runtime verified | Flutter tests / App / OCR / Provider |

该 local branch 只用于当时只读核验，不是默认施工分支。

任何 Executor 开工前必须重新核验：

- master；
- schema；
- canonical docs；
- 当前 branch / dirty state；
- worktree（仅当当前任务实际使用 worktree 时）；
- accepted prerequisite PR。

若出现非预期漂移，STOP 并重新评估。

---

# B. 任务拆分与顺序

Risk：

- T1：展示／机械；
- T2：业务／接口；
- T3：持久化／迁移／并发。

默认一个叶子包对应一个 bounded PR。强耦合的 schema 与其 B0 校验属于同一兼容责任，不允许把已生效 schema 与其 backup/restore 兼容拆开交付。

| Package | Responsibility | Risk | Start Condition | Acceptance |
|---|---|---:|---|---|
| P0 | 保存 V3、planned amendments、B0 v28 current-state correction | T2 | RUN_NOW + explicit doc write auth | 不虚构 runtime |
| P1a | CategoryKey、TrainingContent、ratio/quota pure domain | T2 | P0 | identity、0%、allocation |
| P1b | Application ports/DTO、OrdinaryTrainingBankEligibility、activity/task contracts | T2 | P1a | CP1 |
| P1c | v29 schema、seed、B0 staged validation | T3 | CP1 | migration/compatibility |
| P2a | TrainingCatalog/Eligibility adapter、config CRUD、selection、visual CAS | T2 | P1c | atomic config/pure read |
| P2b | persistent binding invalidation across bank lifecycle | T3 | P2a | delete/move/recreate/replace |
| P3a | bounded ID selection + typed materialization | T2 | P2b | random window/fail-closed |
| P3b | new/category-review launch orchestration | T2 | P3a | CP2-T |
| P4a | StudyActivity owner/lifecycle/clock/day split pure logic | T2 | CP1 | matrix/route semantics |
| P4b | v30 persistence/checkpoint/recovery/aggregate/B0 | T3 | P4a + P1c + shared P2 persistence writers finished | CP2-A |
| P5a | v31 + current-attempt timestamp write paths | T3 | P4b | retry reset/stale callback |
| P5b | TaskCenter facade + successful cleanup + retry-selection adapter | T3 | P5a | CP2-I |
| P6 | Category Visual + shared pure UI primitives | T1 | CP1 | theme/accessibility |
| P7a | TrainingContent list pure Presentation | T1 | CP1 + P6 | fixture states |
| P7b | selector + editor pure Presentation | T1 | CP1 + P6 | ratio/limit/visual |
| P7c | real Application integration | T2 | P7a + P7b + P2b | config flow/CAS |
| P8a | Practice StudyActivity integration | T2 | CP2-A + P3b | no grade/queue regression |
| P8b | MockExam StudyActivity integration | T2 | CP2-A | countdown/submit unchanged |
| P9a | Today v2 real query projection | T2 | CP2-T + CP2-A | counts/context/week |
| P9b | TodayController generation/context | T2 | P9a | latest-wins |
| P9c | Home v2 pure Presentation components | T1 | CP1 + P6 | category/page/week fixtures |
| P10a | TaskCenter pure visual components | T1 | CP1 + P6 | four states/time/confirm |
| P10b | TaskCenterScreen facade integration | T2 | P10a + CP2-I | no direct infra |
| I1 | Practice/Exam composition | T2 | P8a + P8b | real injection |
| I2 | Home/config composition + activation | T2 | I1 + P7c + P9b + P9c | Home CP3 |
| I3 | TaskCenter composition + review/retry compatibility bridge | T2 | I2 + P10b | Task CP3 |
| P11a | retire PlanConfigScreen / old home dependency | T1 | I2 + I3 | no orphan entry |
| P11b | final verification / canonical closure | T2 | all | CP4 |

Schema sequence严格为：

v29 → v30 → v31

P4b 不与 P1c 或 P2 的共享 persistence writers 并行修改共享 database/B0 authority。P5a 只在 v30 已完成并接受后开始。

---

# C. 文件 Ownership

每个 package 声明预计 ownership 路径/模块，用于标识主要责任，不要求 Planner 在开工前穷举所有必然联动文件。除非任务明确写 `Strict path whitelist: yes`，Executor 可以补充完成当前责任所必需的直接关联文件，但不得跨另一个 writer 的 ownership、扩大产品范围或改变冻结语义；新增路径必须在 handoff 中说明原因。

| Group | Ownership |
|---|---|
| P1a | 新 training Domain values、CategoryKey、TrainingContent、allocation |
| P1b | 新 training/activity/task Application contracts + eligibility |
| P1c | v29 schema + DatabaseHelper migration/validation + B0 |
| P2a | TrainingCatalog eligibility adapter + TrainingContent repository/service |
| P2b | existing durable bank mutations + invalidation helper |
| P3a | ReviewRepository narrow candidate/materialization seam |
| P3b | TrainingSession Application service + adapter |
| P4a | StudyActivity pure domain/application |
| P4b | v30 + Activity Repository + B0 |
| P5a | v31 + TaskManager/attempt timestamp transition |
| P5b | Task facade + cleanup + retry compatibility adapter |
| P6 | Category Visual / shared presentation primitives |
| P7 | configuration pages/controller |
| P8a | PracticePage Activity wiring |
| P8b | MockExam Activity wiring |
| P9a | Today query/adapter |
| P9b | TodayController |
| P9c | Category/Home weekly pure components |
| P10a | TaskCenter pure components |
| P10b | TaskCenterScreen migration |
| I1–I3 | composition/main/Home assembly/bridges |
| P11a | old PlanConfig removal |
| P11b | canonical closure |

以下共享文件必须明确单 writer：

- DatabaseHelper；
- BackupSnapshotRepository；
- QuestionRepository；
- ReviewRepository；
- TaskManager；
- main.dart；
- HomePage；
- shared architecture/B0/Home tests；
- canonical docs。

测试 ownership 跟随叶子包。新增行为增加 focused tests；修改既有行为时只改直接相关测试。必要的版本 pin、B0/schema 同步、直接 regression 可以作为同一责任的联动路径追加；不得借“补覆盖”顺带做无关改动。

只有新增路径跨责任边界、另一个 active writer、显式 strict whitelist，或会改变 schema/public contract/产品语义时才 STOP。

---

# D. 并行规则

包组类型：

WRITE_PARALLEL_AFTER_CHECKPOINT

执行模式：

MANUAL_DELEGATED

本契约不授权自动创建 child agents、自动 worktree、自动 PR 或自动 merge。

## D.1 CP1 后可提前并行

- P4a pure StudyActivity logic；
- P6；
- P6 完成后的 P7a；
- P6 完成后的 P7b；
- P6 完成后的 P9c；
- P6 完成后的 P10a；
- 文件完全不重叠的其他 pure/Application leaf package。

fixture-driven UI 可以提前实现和 review，但 production HomePage/main wiring 必须等待对应后端 gate。

## D.2 P8 修正规则

P8a/P8b 不是 CP1 后即可开工。

P8a 开始条件：

- CP2-A；
- P3b。

P8b 开始条件：

- CP2-A。

达到各自 B 表开始条件后，P8a 与 P8b 可以彼此并行，前提：

- P8a 只改 Practice-owned files；
- P8b 只改 MockExam-owned files；
- 两者不同时修改 composition。

## D.3 必须串行

- 所有 schema version；
- migration authority；
- B0 sanitize/validation；
- overlapping DatabaseHelper；
- overlapping QuestionRepository；
- overlapping ReviewRepository；
- TaskManager shared mutation；
- production main.dart；
- production HomePage composition；
- shared tests；
- canonical docs；
- I1 → I2 → I3 → P11a → P11b。

每个 writer 必须有独立 branch。单 writer 默认可在当前 checkout 工作；并行 writer 必须使用独立 worktree 且 ownership 不重叠。

---

# E. 执行包格式

执行包保持集中、简洁，不重复 `AGENTS.md` 的全局规则。普通写任务包含：

```text
角色：执行
任务：<bounded objective>

Base: <authorized base>
Branch: <assigned new branch>
Expected ownership paths: <primary files/modules>
Strict path whitelist: no | yes
Frozen task semantics: <only current-stage invariants>
Acceptance: <focused criteria>
Validation: <focused tests/checks>
Git: commit/push/PR/merge authority
Stop only if: <real scope/contract/version/cross-writer/environment blocker>
```

Worktree 仅在并行 writer、脏工作区隔离或 Coordinator 明确要求时加入。

默认 `Strict path whitelist: no`。直接必要联动文件由 Executor 自行处理并在 handoff 说明，不因单纯多出一个文件停下询问。

T3 包只额外写当前任务真正需要的：authoritative path、compatibility bridge/deletion condition、rollback point、evidence class、checkpoint reopening condition。

Handoff 只保留：fixed head/PR、实际 changed files、行为、验证、必要联动路径原因、未解决风险。

---

# F. PR 与独立审查

- 一个 leaf package 对应一个 bounded PR；
- commit/push/PR authority 由任务包或当前用户明确给出；
- Executor 完成机械验证后，只有在授权下才能 commit/push/PR，然后 STOP；
- Reviewer 使用固定 PR head，不复用 Executor 的主观结论作为 evidence。

以下 T3 内容触发独立 deterministic Verifier：

- schema；
- migration；
- B0；
- persistent binding invalidation；
- StudyActivity checkpoint concurrency；
- successful-task cleanup。

普通 T1/T2 流程：

Executor self-check → Independent Reviewer

P0/P1/P2 finding 在同 PR bounded repair，修复后 fresh targeted review。P3 finding 不自动扩范围修复。

Merge 需要用户单独授权。本附录不授权 merge。

模型选择读取当时 docs/agents/model-routing.md；不得把临时模型额度、UI mode 或 preference 写成 durable 产品规则。

---

# G. Checkpoint 交付定义

## CP1

必须已冻结并被独立审查：

- CategoryKey；
- TrainingContent；
- OrdinaryTrainingBankEligibility；
- allocation/quota；
- 0%；
- Application ports/DTO；
- safe result/error；
- StudyActivity lifecycle matrix；
- TaskCenter retry file-selection handoff；
- ownership 边界。

CP1 不要求 schema 已落地，但之后 pure UI 可以 fixture-driven 并行。

## CP2-T

必须证明：

- v29 fresh/create/upgrade；
- seed 只旧合法 current bank；
- TrainingContent CRUD/CAS；
- member invalidation；
- same-name recreate 不复活；
- B0 配置 round-trip；
- quota/refill；
- bounded random selection；
- typed materialization fail-closed；
- startNew/startCategoryReview；
- legacy launcher 兼容。

## CP2-A

必须证明：

- StudyActivity pure lifecycle；
- temporary-cover pause vs true-exit end；
- v30；
- legal matrix；
- checkpoint idempotency/concurrency；
- midnight/DST attribution；
- crash recovery；
- B0 snapshot；
- weekly aggregate。

## CP2-I

必须证明：

- v31；
- current attempt timestamps；
- retry resets；
- old attempt late callback zero mutation；
- TaskCenter facade；
- successful-only cleanup；
- retry file-selection ephemeral handoff；
- review compatibility bridge 仍使用既有 CAS。

## CP3

真实 composition 与生产页面接入完成并通过对应 focused regression。Fixture-only UI 不算 CP3。

## CP4

整体 scope、navigation、canonical current truth、accessibility、runtime/visual evidence 闭合；未完成实机视觉验收必须显式保留待验收，不能宣称视觉 closure。

---

# H. 最终关闭条件

只有同时满足以下条件，本专项才能标记 CLOSED：

- CP2-T、CP2-A、CP2-I、CP3、CP4 全部通过；
- 无开放 P0/P1/P2 finding；
- CategoryKey identity 正确；
- OrdinaryTrainingBankEligibility 成为单一 authority；
- TrainingContent 与 StudyPlan 完全隔离；
- binding invalidation durable；
- 同名 bank recreate 不恢复旧 binding；
- 0% 不参与普通新题；
- 0% 仍正常进入 Category review；
- 仅 seed 合法 old current bank，不 mass seed；
- bounded selection 与 typed fail-closed 正确；
- v29/v30/v31 及 B0 round-trip 正确；
- unavailable currentContent preference 可合法 round-trip；
- structurally valid stale currentCategory 不因 runtime fallback 被误判损坏；
- read fallback 不隐式持久化；
- StudyActivity lifecycle matrix 被持久层与 restore 验证；
- temporary cover 与 true exit 正确区分；
- 四类 Activity 实际接入，未宣称第五类完成；
- TaskCenterScreen 不直接依赖 TaskManager/Coordinator/mutable ImportTask；
- retry file selection 不进入 read DTO/persisted snapshot；
- successful cleanup 不删 error/pending/busy；
- 替代入口完整可达后旧 PlanConfigScreen 已退休；
- canonical current-state 与实际代码一致；
- 实机视觉未验收项明确记录；
- 未扩大到 multi-plan、stable bankId、Category rename、新 question detail page、AI Visual 或其他延期能力。

后续 Agent 可以决定局部实现细节，但不得重新决定 V3 已冻结的产品语义、authority、事务边界、生命周期、迁移规则、eligibility、状态矩阵或交付边界。
