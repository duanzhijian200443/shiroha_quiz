# UI Finalization — Final Information Architecture Freeze

Status: **Canonical UI Finalization Presentation / Navigation authority.
UI-R0 is COMPLETE after this freeze. UI-R1 and UI-CL are NOT STARTED. UI
Finalization itself is NOT CLOSED yet.**

This document freezes the final Shiroha Presentation / Navigation
information architecture so that the remaining UI Finalization stages
(UI-R1, then UI-CL) can be implemented without reopening IA decisions. It
is the current authority for the final primary navigation and the final
Today mode organization. It is a docs/contract freeze: UI-R0 implemented
no production code, tests, schema, or workflow change.

## 1. Purpose

UI Finalization has exactly three serial stages:

```text
UI-R0  Final IA Sync / Freeze  (this freeze)
UI-R1  Today modes + bounded navigation migration
UI-CL  Focused UI closure
```

UI-R0 freezes:

- the final primary navigation;
- the final Today mode organization (普通 / 特训 / 考试);
- the Mock/Exam migration contract;
- the StudyPlan dependency for 特训;
- the boundary of the UI-R1 implementation stage;
- the supersession of the old UI-R2 / UI-R3 large redesign plans.

UI Finalization does not redesign the Assistant main conversation, does not
reopen P6/P7/RAG/W0/A0/MCP or schema boundaries, and does not rewrite exam
business logic.

## 2. Authority and supersession

Historical evolution (all remain recorded as history; none is rewritten):

```text
U0:
今日 | 项目 | 模考 | 我的

U1:
今日 | 助手 | 模考 | 我的

UI Finalization:
今日 | 助手 | 我的
今日内部 = 普通 / 特训 / 考试
```

This document supersedes `docs/product/u1-agent-first-ia-freeze.md`
**only** on these Presentation decisions:

- the final primary navigation (three destinations instead of four);
- the Today mode organization (普通 / 特训 / 考试).

The four-tab `今日 | 助手 | 模考 | 我的` shape in the U1 document remains
historical U1 truth. It is not current Presentation authority.

U1 retains authority for everything else it defines, including:

- the Assistant identity `Shiroha`;
- the Assistant workspace and global Sidebar behavior;
- Learning Space semantics;
- File Library semantics;
- Conversation semantics and lifecycle;
- MCP Presentation;
- responsive Assistant behavior;
- Project / File / Conversation domain relationships.

## 3. Final primary navigation

The final primary navigation is exactly:

```text
今日 | 助手 | 我的
```

There is **no fourth formal primary destination**. The top-level 模考
destination is **retired from primary navigation**; the exam capability is
not deleted (see the Mock/Exam migration contract).

No new primary tabs are added: 学习空间, 文件, 题库, and 项目 are not
primary navigation destinations. Learning Space / File Library / Question
Bank continue to live inside the existing Assistant / content workspace
system.

## 4. Today modes

Today is the final training entry. Its internal organization is frozen as:

```text
今日
├─ 普通
├─ 特训
└─ 考试
```

Today does not own: Assistant conversation, File Library management,
Learning Space management, MCP, AI provider settings, or global asset
organization.

### 普通

Presentation continuation of the current regular learning flow. UI-R1 must
reuse the current ordinary-training surfaces and semantics:

- 今日训练 (Today training);
- 新题挑战 / 复习巩固;
- BankDetail / Practice flow;
- current ordinary-training semantics.

UI-R1 does not rewrite any business algorithm.

### 特训

Frozen formal dependency:

```text
real learning state
-> planning capability
-> StudyPlanDraft
-> preview
-> explicit user adoption
-> Active StudyPlan
-> Today / 特训 dynamic selection
```

特训 consumes only a real Active StudyPlan. If the Active StudyPlan
capability does not exist yet, UI-R1 may complete the UI shell / IA but
must show only a genuine empty / setup / dependency-not-ready state.

Forbidden:

- fake plan data;
- hardcoded recommendations;
- a UI-layer planning algorithm;
- claiming that the StudyPlan-driven 特训 capability is complete when no
  Active StudyPlan capability exists.

The UI shell / IA can be complete without the StudyPlan capability; the
StudyPlan-driven 特训 capability itself must not be claimed complete.

### 考试

```text
Today -> 考试
```

is the **only formal user-facing primary Exam entry**. The exam capability
is migrated and reused, not rewritten:

- `MockCenterScreen`;
- `MockExamConfigScreen`;
- `MockExamScreen`;
- `PaperReviewScreen`;
- `AiQuizScreen`;
- `ExamRepository` and the existing hidden exam bank / grading semantics.

There is no second set of exam business logic. Internal navigation, routes,
and helper transitions inside the exam surfaces may continue to exist and
may be reached from the exam surface; the frozen contract is that there is
no second formal primary Exam entry and no broken internal exam navigation.

## 5. Assistant boundary

Assistant main-chat redesign is **OUT OF SCOPE** for UI Finalization. The
following remain unchanged:

- the `Shiroha` first-class Assistant identity;
- `AssistantWorkspaceShell` and the global Sidebar;
- New Conversation;
- File Library;
- Learning Space;
- MCP;
- Recent Conversations;
- Conversation lifecycle;
- the A0 runtime;
- W0 proposal / approval;
- RAG-1 retrieval;
- the existing P7 typed-question AI answer flow.

UI-R1 and UI-CL may at most perform necessary shell adaptation to stay
coherent with the final navigation, plus obvious visual-consistency fixes.
Conversation architecture must not be redesigned.

## 6. Learning Space / File Library / Question Bank

The old giant UI-R2 / UI-R3 plans are **superseded** and are not current
implementation stages. The following must not be restarted as independent
large stages:

- a giant Learning Space redesign;
- a giant File Library redesign;
- a giant Question Bank redesign;
- a full Assistant redesign;
- a repository-wide visual rewrite.

Learning Space, File Library, and Question Bank continue to exist inside
the already-implemented Assistant / content workspace system.

## 7. Profile

The primary 我的 destination is retained. Its responsibility remains:

- user / app settings;
- Shiroha Agent settings;
- provider / AI service settings;
- data / application settings;
- current personal configuration.

UI-R1 allows only bounded cleanup. It must not delete valid settings
entries and must not move File Library / Learning Space into Profile as
primary entries.

## 8. UI-R1 bounded implementation contract

UI-R1 is a bounded Presentation migration, decided against the
UI-R0-merged master at UI-R1 start. Likely production candidates
(listed for scoping only; exact paths must be re-verified against the
UI-R0-merged master before UI-R1 starts):

- `lib/ui/pages/main_screen.dart` — remove the top-level 模考 tab; final
  three-tab navigation;
- `lib/ui/pages/home_page.dart` — Today mode organization
  (普通 / 特训 / 考试);
- an optional narrow Today shell file if the mode organization warrants it;
- `lib/ui/pages/mock_center_screen.dart` — bounded reuse / route adaptation
  for Today -> 考试;
- `lib/ui/pages/profile_screen.dart` — minimum cleanup only.

Explicit reuse (no rewrite): `PracticePage`, `BankDetailScreen`,
`QuestionListScreen`, `PlanConfigScreen`, `TaskCenterScreen`,
`MockCenterScreen`, `MockExamConfigScreen`, `MockExamScreen`,
`PaperReviewScreen`, `AiQuizScreen`, `AssistantWorkspaceShell`, and the
existing Profile settings surfaces.

Explicit no-touch by default: application, domain, data, services, core,
P6, P7, RAG, W0, A0, MCP, and schema.

UI-R1 must not bind to the pre-freeze base of this document; it must
start from the exact master SHA after this UI-R0 freeze is merged.

## 9. UI-R1 acceptance (frozen)

- **A. Primary navigation** — exactly 今日 / 助手 / 我的; no formal
  top-level 模考.
- **B. Today** — modes 普通 / 特训 / 考试; mode switching does not
  accidentally destroy unrelated mode state.
- **C. 普通** — existing ordinary training remains reachable.
- **D. 特训** — consumes only a real Active StudyPlan; without one, an
  explicit empty / setup state; no fake data.
- **E. 考试** — the existing exam capability is reachable through
  Today -> 考试; there is no second formal primary Exam entry; internal
  exam routes may remain.
- **F. Assistant** — the existing main workflow remains functional.
- **G. Profile** — important existing settings remain reachable.
- **H. Responsive** — desktop and narrow/mobile navigation produce no
  unreachable destination.

## 10. UI-CL definition

UI-CL occurs only **after** UI-R1 merges and is reviewed. Its purpose:

- verify the frozen three-tab IA;
- verify the Today mode organization;
- verify the exam migration;
- verify Assistant / Profile regressions;
- verify responsive navigation;
- canonical status closure.

Current status after this UI-R0 docs freeze:

```text
UI-R0  COMPLETE
UI-R1  NOT STARTED
UI-CL  NOT STARTED
```

UI Finalization itself is **not** closed yet; this document must not state
UI-CL COMPLETE.

## 11. Non-goals and stop conditions

UI-R0, UI-R1, and UI-CL must not require or perform:

- a schema migration;
- reopening P7 (CLOSED / FROZEN);
- reopening RAG, W0, A0, or MCP contracts;
- a Conversation semantics change;
- a Project / File lifecycle change;
- an exam domain rewrite;
- a StudyPlan fake implementation;
- a production Dart implementation during UI-R0 (docs-only freeze);
- the old UI-R2 / UI-R3 large redesigns;
- any change outside the allowed scope of the current stage.

Documentation authority:

- `docs/product/ui-finalization-ia-freeze.md` — this document, the final
  Presentation / Navigation IA authority;
- `docs/product/u1-agent-first-ia-freeze.md` — historical U1 authority,
  retained except where superseded above;
- `docs/architecture/n0-post-p5-roadmap.md` — stage ordering and current
  status;
- `ARCHITECTURE.md` — repository-wide dependency and boundary contract.
