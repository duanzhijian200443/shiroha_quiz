# Shiroha Quiz Agent Instructions

## 1. Scope and precedence

These instructions apply to all agent work in this repository.

When instructions conflict:

1. Follow higher-level platform and user instructions.
2. Follow the more restrictive repository rule.
3. Follow the active role file.
4. Stop and ask for approval when the conflict cannot be resolved safely.

Operate only inside this repository unless the user explicitly authorizes otherwise.

---

## 2. Required context

Before any non-trivial task, read:

- `ARCHITECTURE.md`
- only the files under `.agents/rules/` selected by the routing table below
- the active role file under `docs/agents/`
- relevant existing tests
- the implementation surrounding the target code
- current uncommitted changes affecting the task

Do not claim a file was reviewed unless it was opened during the current task.

### `.agents/rules/` routing

Do not enumerate or read every file under `.agents/rules/` by default. Read
only the files selected by this table.

A rule file explicitly named as a task target may also be read to inspect,
modify, review, diagnose, or verify that target. Reading a rule file as task
evidence does not activate its behavioral instructions; activation still
follows the table.

| Rule file | Read when | Do not read when | Foundation |
|---|---|---|---|
| `architectural-discipline.md` | Every non-trivial task | Only trivial, self-contained requests that need no repository context | Yes |
| `git_work.md` | The task concerns Git status, diffs, staging, commit preparation, branches, history, tags, or pushing | The task has no Git operation or Git-state decision | No |
| `reviewer.md` | The first line explicitly activates `角色：审查` | Planner, Executor, Verifier, Diagnostician, or requests without the Reviewer role | No; routing shim only |

Reviewer behavior is defined only by `docs/agents/reviewer.md`; the rule shim
must not impose Reviewer write restrictions on another role.

There is currently no UI-specific or import/OCR-specific file under
`.agents/rules/`. Do not invent one or load unrelated rules for those tasks.
Presentation/UI tasks use this file, `ARCHITECTURE.md`, and the active role.
OCR, import, Replay, private-document, and diagnostics tasks also follow the
applicable role's dedicated safety or Skill routing.

---

## 3. Role activation

The first line of the user request may activate exactly one role:

| Identifier | Role file |
|---|---|
| `角色：总控` | `docs/agents/coordinator.md` |
| `角色：规划` | `docs/agents/planner.md` |
| `角色：执行` | `docs/agents/executor.md` |
| `角色：验证` | `docs/agents/verifier.md` |
| `角色：审查` | `docs/agents/reviewer.md` |
| `角色：诊断` | `docs/agents/diagnostician.md` |

Rules:

- Read the mapped role file before continuing.
- Then state the active role and loaded role file.
- If the role file is missing or unreadable, stop.
- Do not activate more than one role.
- Do not switch roles during a task unless the user explicitly requests it.
- Without an explicit role, do not assume a write-enabled role.

---

## 4. Architecture

Preserve the dependency direction:

`UI -> Service -> Repository -> DatabaseHelper`

Requirements:

- UI and Services must not access SQLite or `DatabaseHelper` directly.
- Persistence belongs in Repositories.
- Business logic belongs in Services.
- Widgets must not contain domain logic.
- Reuse existing abstractions before adding new ones.
- Follow `ARCHITECTURE.md`.

---

## 5. Task workflow

For implementation tasks:

1. Inspect the relevant code, tests, and current diff.
2. Verify the reported problem exists.
3. State a concise plan.
4. Confirm the allowed modification scope.
5. Add or update regression tests.
6. Make the smallest coherent change.
7. Run focused validation.
8. Report results, remaining risks, and out-of-scope findings.

For read-only tasks, do not modify, format, create, rename, or delete files.

---

## 6. Change discipline

- Do not modify files outside the declared scope.
- Stop and request approval before expanding scope.
- Do not refactor, rename, or reformat unrelated code.
- Do not silently change public behavior or persisted formats.
- Preserve backward compatibility unless explicitly authorized.
- Do not add, remove, or upgrade packages without approval.
- Never edit generated files manually.
- Preserve all existing user changes.
- Report nearby problems instead of fixing them automatically.

---

## 7. Git and destructive actions

Never run destructive or history-rewriting commands, including:

- `git reset --hard`
- `git clean -fd`
- `git clean -fdx`
- destructive `git checkout`
- destructive `git restore`
- force push

Do not commit, push, merge, rebase, tag, or create branches unless explicitly requested.

Git authorization is action-specific. Mentioning or authorizing one action
does not authorize a later action: staging does not authorize commit, commit
does not authorize push, and push does not authorize merge, tag, or release.
Never use `git add .` or `git add -A`. Do not automatically create or modify
`DEVELOPMENT_LOG.md`; it must be explicitly included in the allowed file scope.
No rule file may broaden the Git authority supplied by the user and this file.

An Executor is not authorized to commit by role alone. It may create one
scoped commit only when its task package explicitly provides all of:

- `Commit authorized: yes`;
- the assigned branch;
- the exact paths allowed in the commit;
- `Push authorized: no` (unless the user separately authorizes a push).

Without all four fields, the Executor must hand off an uncommitted diff.

Before and after write tasks, inspect:

```bash
git status --short
```

Do not remove unrelated tracked or untracked files.

---

## 8. Security and privacy

Never access, print, copy, modify, persist, or expose:

- API keys
- access tokens
- Authorization headers
- signing keys
- keystores
- passwords
- credentials
- environment secrets
- private configuration
- complete private file contents

Never write these values to logs, diagnostics, reports, fixtures, or tests.

Also avoid logging:

- complete prompts
- complete answers or explanations
- raw OCR text
- model response bodies
- Base64 payloads
- sensitive absolute paths
- full exception messages when they may contain private data

Prefer safe structured values such as:

- counts
- IDs
- stages
- statuses
- runtime type names
- redacted metrics

Network access is disabled by default. Use it only when the task explicitly requires it.

---

## 9. High-risk areas

Treat these as high risk:

- import pipelines
- logging and redaction
- global exception handling
- database migrations
- async recovery
- file rotation
- isolate or multi-process coordination
- API key storage
- OCR/AI result merging
- persisted data compatibility

High-risk changes should include failure-path tests and concurrency tests where applicable.

---

## 10. Validation

Use focused validation during implementation.

Typical commands:

```bash
dart format <changed-files>
flutter analyze <changed-production-files>
flutter test <focused-tests>
git diff --check
```

Rules:

- Run Flutter tests serially on Windows unless parallel execution is known to be safe.
- Do not run full-repository formatting for a focused task.
- Do not fix unrelated historical analyze findings.
- Never claim a command passed unless it was executed.
- Always report skipped or failed validation.

Run the full workflow only when requested or before release:

```powershell
.\scripts\verify.ps1
```

---

## 11. Local private PDF test corpus

Private smoke-test PDFs are stored under:

```text
scratch/test_pdfs/
```

Current structure:

```text
scratch/test_pdfs/
└─ math/
   ├─ paired/
   └─ single/
```

Meaning:

- `paired/`: a stem-only paper and its matching solution paper
- `single/`: one PDF that should import independently

Future subjects may use the same structure, for example:

```text
politics/paired/
politics/single/
english/paired/
english/single/
```

Rules:

1. Do not scan outside `scratch/test_pdfs/` for test PDFs.
2. Do not modify, rename, copy, upload, commit, or track these PDFs.
3. Do not copy real question text into fixtures, logs, diagnostics, or reports.
4. Reports may include only filenames, counts, question numbers, stages, statuses, and redacted metrics.
5. `paired` verification must distinguish:
   - stem-only import
   - solution-only import
   - combined import
6. `single` verification uses one PDF only.
7. These assets must remain untracked by Git.

---

## 12. Reporting

At the end of a task, report only what is relevant:

- files changed
- behavior changed
- tests and commands executed
- exit status
- failures or skipped checks
- remaining risks
- out-of-scope findings
- `git status --short`

Do not hide failed validation.

---

## 13. Prompt economy

Task prompts should not repeat rules already defined here.

A normal task request should contain only:

- role
- task goal
- allowed scope
- task-specific constraints
- acceptance criteria
- focused validation
- stop conditions
## 14. Agent cost and execution boundaries

Use high-capability agents only for work that requires architectural
reasoning, uncertain root-cause analysis, security decisions, concurrency,
database safety, cross-module changes, or high-risk implementation.

Route work by task risk rather than role name alone:

| Tier | Typical work | Default route |
|---|---|---|
| T0 | format, analyze, focused tests, status, diff collection | local terminal, CI, Verifier, or ordinary low-cost agent |
| T1 | one bounded local implementation with frozen behavior | preferred low-cost Executor, then deterministic validation |
| T2 | cross-file compatibility work or a bounded migration | short Planner/Diagnostician when needed, bounded Executor, independent Reviewer |
| T3 | public contracts, persistence/database, security, concurrency, or high-risk semantics | high-capability planning and review; delegate only frozen implementation slices |

Use the lowest tier that safely covers the actual uncertainty and impact. A
role label does not downgrade a T2/T3 task, and a routine role does not by
itself justify a high-capability model.

Deterministic work must be handed to a Verifier, ordinary agent, local
terminal, or CI. Deterministic work includes:

- running focused tests;
- running focused static analysis;
- formatting already modified files;
- PowerShell syntax checks;
- `git diff --check`;
- `git status --short`;
- collecting command output;
- waiting for builds or long-running processes;
- producing routine validation summaries.

### Phase boundary

An Executor must stop active implementation when all of the following are true:

1. the requested production behavior has been implemented;
2. the relevant code is syntactically complete;
3. at least one focused implementation test or analyze pass has succeeded;
4. the remaining work consists mainly of verification, formatting,
   long-running commands, diff inspection, or report generation.

At this boundary, the Executor must produce a handoff package and stop.
It must not continue into an open-ended "final audit".

### Handoff package

The handoff must contain:

1. files modified or created;
2. implemented behavior;
3. tests already run and their results;
4. commands still needing to be run;
5. known risks and unverified runtime behavior;
6. the recommended next role;
7. current `git status --short`.

### Command limits

Unless the user explicitly authorizes otherwise:

- do not run a full repository test suite;
- do not run Windows Release builds;
- do not start generated applications;
- do not invoke real external APIs;
- do not wait indefinitely for a process;
- do not retry the same failing or stalled command more than once;
- do not silently increase a timeout after it has expired.

A command that produces no meaningful progress for 3 minutes must be treated
as stalled. Stop waiting, preserve its evidence, and report it as incomplete.
This threshold applies only to an individual command monitored by the active
agent. It does not define the execution window for an entire silent child
task, and a Coordinator must not infer that a child is stalled merely because
the child has not emitted commentary or a terminal handoff.

Any long-running build must have an explicit timeout before it starts.
A timeout is an incomplete verification result, not proof of build failure.

### Final audit restriction

During final audit, do not:

- discover and implement unrelated improvements;
- refactor newly noticed code;
- expand the file scope;
- add optional tests;
- clean existing lints;
- run broad builds or test suites.

Only fix a blocking compile or focused-test failure directly caused by the
current task. Make at most one focused repair attempt. If it still fails,
stop and hand the evidence to the next role.

### Model handoff

Agents cannot switch models themselves.

When a task crosses from uncertain implementation into deterministic
verification, explicitly recommend:

`Next role: Verifier or ordinary low-cost agent`

Do not continue merely because verification has not yet been completed.
Agents must automatically apply the shared architecture, safety, privacy, Git, validation, and reporting rules from this file.

---

## 15. Multi-agent orchestration

Repository roles define responsibilities and permissions. Model/provider
selection and cost routing normally belong to the host or global Codex
configuration. The explicit user-authorized repository routing section below
is the authoritative exception for child agents in this repository.

### 15.1 Parent Coordinator responsibilities

Repository-wide orchestration uses the `角色：总控` role. The Coordinator
owns:

- inspecting the base commit, current branch, worktrees, and dirty state;
- choosing serial work or safe parallel work;
- invoking bounded Planner or Diagnostician tasks when needed;
- freezing shared architecture, public contracts, public models, persisted
  formats, database migrations, and cross-module integration order;
- building the dependency graph and assigning non-overlapping file ownership;
- creating or assigning branches and worktrees only when explicitly
  authorized under section 7;
- dispatching role-specific child task packages and waiting for terminal
  handoffs without duplicating delegated work;
- integrating validated work serially when integration is explicitly
  authorized;
- freezing the integrated result before final verification and review;
- reporting to the user without automatically merging or pushing.

The Coordinator must not give two Executors ownership of the same production
file, delegate shared-contract decisions, skip required verification/review,
or edit a shared working tree while a child writer is active there.

The Coordinator must never modify production or test files. It may modify only
explicitly assigned orchestration documentation and may perform explicitly
authorized Git integration of already frozen, validated work. A production or
test repair requires a fresh Executor with exact file ownership, or a new user
decision when the repair exceeds the frozen scope.

### 15.2 Child role activation

Every child task must activate exactly one repository role. Use Planner for a
bounded repository survey or implementation plan and Diagnostician for failure
tracing. A child may not switch roles, create descendants, expand its scope, or
decide public architecture/contracts. Child-agent nesting depth is one.

### 15.3 Delegation package

Every delegated task must state:

1. active role;
2. objective and necessary background;
3. base commit;
4. assigned worktree path;
5. assigned branch or detached state;
6. allowed files;
7. forbidden files and worktrees;
8. dependencies and required shared-contract checkpoint;
9. acceptance criteria;
10. focused validation and per-command timeouts;
11. child execution window;
12. commit authorization and allowed commit paths;
13. stop conditions;
14. handoff token budget.

Do not copy the complete parent conversation. Supply only the context needed
to execute the package safely.

### 15.4 Communication and handoff

Child agents work silently and return only at a terminal state:

- `COMPLETE`: the bounded task is complete;
- `BLOCKED`: a Coordinator decision or new authority is required;
- `FAILED`: the task cannot be completed within its allowed scope.

Default maximum handoff sizes are:

| Child task or role | Default maximum |
|---|---:|
| Bounded repository survey | 700 tokens
| Planner full task package | 1600 tokens
| Executor | 800 tokens |
| Verifier | 800 tokens |
| Diagnostician | 1200 tokens |
| Reviewer | 1200 tokens |

A Coordinator may grant a bounded exception for a complex blocker or P1/P2
finding. Handoffs must not paste complete diffs, source files, logs, or the
investigation transcript. Keep detailed evidence in the assigned worktree,
scoped commit, or bounded test output. The Coordinator must not frequently
poll children or repeat work already delegated to them.

For each pending child set, use one bounded wait operation covering the
declared execution window. Do not emit heartbeat or elapsed-time messages, use
model turns as a timer, or repeatedly issue short waits. A new bounded wait is
allowed only after the pending set changes because a child completed, failed,
or requested attention. A wait timeout is incomplete evidence; request one
terminal handoff, stop the affected child, and do not resume that writer.

### 15.5 Worktrees and file ownership

- A working directory may have only one active writer.
- Read-only agents may share a working directory only when they are not
  reviewing or verifying a moving implementation target.
- Two or more concurrent writers require separate Git worktrees.
- Each writer owns only its assigned files and must not read, modify, or run
  commands in another child's worktree.
- Parallel write packages must not overlap production-file ownership.
- Shared files remain Coordinator-owned until the shared-contract checkpoint
  is frozen; subsequent changes require Coordinator approval and serialization.
- A Coordinator must not modify the shared current worktree concurrently with
  a child writer.
- Children must not switch branches, merge, rebase, reset, push, or perform
  any Git action not explicitly authorized by their package.

### 15.6 Freeze and integration gates

Multi-agent work must pass these gates in order:

1. **Shared-contract gate:** freeze common contracts and ownership before
   parallel writes begin.
2. **Implementation-freeze gate:** stop all writers before a Verifier or
   Reviewer examines their target.
3. **Branch-validation gate:** validate each implementation worktree or target
   commit before integration.
4. **Integration gate:** integrate validated work serially, freeze the
   integrated snapshot, then run integration-level verification and review.
5. **Human gate:** leave merge and push decisions to the user unless separately
   authorized.

### 15.7 Writer lifecycle and frozen-target validity

- Implementation, independent verification, and semantic review are separate
  bounded tasks. An Executor's focused gate is a self-check, not independent
  verification.
- A terminal writer handoff is irreversible. After an Executor returns
  `COMPLETE`, `BLOCKED`, or `FAILED`, or after the Coordinator stops or closes
  it, that Executor must not be resumed, messaged, or granted write ownership
  again.
- Any repair after a terminal handoff must use a fresh Executor with the frozen
  target, actionable findings, exact file ownership, a bounded repair window,
  and one minimal focused gate.
- Before verification or review, capture the branch or detached state, `HEAD`,
  `git status --short`, and target file identities. Include relevant sidecar
  file identities when their drift could change the task or evidence.
- If any captured target identity changes, all verification and review results
  for the previous target are invalid. Stop affected read-only agents, freeze
  the new target, and rerun every required gate from the beginning; do not
  reuse partial PASS evidence.

## 子代理风险与模型路由（用户授权例外）

当父代理或 Coordinator 创建子代理时，先按第 14 节判定 T0-T3 风险，
再按子任务的实际职责选择模型；不得仅根据 Planner、Executor、Verifier、
Reviewer 或 Diagnostician 的角色名称固定模型。

- T0 默认使用本地命令、CI、Verifier 或普通低成本代理；不要为机械验证
  启动高能力代理。
- T1 的默认且最高优先级子代理模型为
  `deepseek/deepseek-v4-flash`。
- T2 的边界清楚实现与机械验证优先使用 DeepSeek；涉及跨模块兼容判断、
  未确定根因或语义审查时，Planner、Diagnostician 或 Reviewer 可使用宿主
  提供的高能力模型。
- T3 必须由高能力模型承担规划、公共契约判断和独立语义审查；DeepSeek
  只执行已经冻结、边界明确的实现切片或确定性验证。
- 用户在当前任务中明确声明的模型覆盖上述默认路由。
- 若首选模型不可用、创建失败或不支持所需工具，允许选择其他可用模型；
  不得静默回退，必须报告原因及实际 provider/model。
- 创建子代理后，应在交接中报告风险等级和实际 provider/model；发生回退
  时还必须报告首选模型不可用的证据类别。
