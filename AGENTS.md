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
## Agent Cost and Execution Boundaries

Use high-capability agents only for work that requires architectural
reasoning, uncertain root-cause analysis, security decisions, concurrency,
database safety, cross-module changes, or high-risk implementation.

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
## 子代理协作规则

### 角色边界

- 父代理负责架构决策、公共契约、任务拆分、集成和最终审查。
- DeepSeek V4 Flash 子代理只执行边界明确的调查、测试、局部实现和机械修改。
- 子代理不得自行扩大任务范围，不得修改公共架构契约。
- 子代理不得执行 merge、push、rebase、reset 或切换分支。

### 通信规则

子代理执行任务时：

1. 静默执行，不发送百分比、阶段性进度或“仍在工作”消息。
2. 仅在以下状态返回父代理：
   - COMPLETE：任务完成；
   - BLOCKED：需要父代理决策；
   - FAILED：在允许范围内无法完成。
3. 最终交接控制在 800 tokens 以内。
4. 交接只包含：
   - 状态；
   - 修改文件；
   - 实现摘要；
   - 测试命令及结果；
   - commit SHA（要求提交时）；
   - 阻断项或未验证项。
5. 不返回完整 diff、完整源文件、完整测试日志或调查过程。
6. 详细证据保留在当前工作目录、Git commit 或测试输出文件中。
7. 父代理不得频繁轮询，不得重复执行已经委派的任务。

### 并发与工作区

- 同一工作目录同一时间只能有一个写代码代理。
- 只读调查和只读审查可以共享工作目录。
- 两个或更多代理同时写代码时，每个写入代理必须使用独立 Git Worktree。
- 每个任务必须明确允许修改和禁止修改的文件。