# U1 Agent-first Information Architecture Freeze

Status: **Canonical U1 Presentation and Navigation contract**.

## 1. Authority and supersession

This document freezes the Agent-first information architecture validated by
U1. It is the current authority for Shiroha's Presentation and Navigation
semantics.

U1 supersedes the U0 target only where the product has validated a different
Presentation or Navigation decision. U0 remains authoritative for retained
domain and lifecycle semantics, including optional Project membership,
reference rather than ownership, valid unclassified assets, and legacy
Subject/Folder compatibility.

This contract does not rename Domain, Application, database, or persistence
types. It does not introduce a schema, runtime, provider, or business feature.

## 2. Primary navigation and product naming

The primary navigation is:

```text
今日 | 助手 | 模考 | 我的
```

- `助手` is a first-class destination.
- The page and assistant brand is `Shiroha`.
- User-facing primary product naming does not expose the implementation term
  `Agent`.
- `今日`, `模考`, and `我的` retain their established responsibilities.

The U0 target `今日 / 项目 / 模考 / 我的` is superseded at the Presentation
layer. Project remains a valid domain concept, but its user-facing name is
Learning Space and it is reached through the Assistant workspace rather than a
primary `项目` tab.

## 3. Presentation terminology

| Domain/Application term | Presentation term |
|---|---|
| `Project` | 学习空间 |
| `LibraryFile` | 文件 |
| `QuestionBank` | 题库 |
| `Conversation` | 对话 |
| `Agent` | Shiroha / 助手 |
| `Subject` | 学科属性 / 筛选 |

These mappings are Presentation terminology only. Existing domain,
application, database, DTO, and persisted names do not change.

## 4. Global Sidebar and workspace destinations

The Desktop Assistant workspace uses a global Sidebar with these
responsibilities:

```text
Shiroha

＋ 新对话
文件库
学习空间
MCP

────────
最近对话
────────
学习空间
```

The Sidebar is a global destination and context switcher. It is not a general
hierarchical asset browser.

### 4.1 Learning Space

A Learning Space may expand in the global Sidebar as:

```text
Learning Space
└─ Conversations
```

This expansion is only for fast context and conversation switching. A
Learning Space home opens an independent Main Workspace. Conversation
persistence and the expansion's runtime data are C0 concerns and are not
implemented by this freeze.

### 4.2 File Library

File Library must not expand in the global Sidebar as a Folder/File tree:

```text
File Library
└─ Folder
   └─ File
```

Clicking File Library opens:

```text
Desktop -> Main Workspace
Mobile  -> full-screen destination
```

Folder is local navigation owned by File Library itself.

### 4.3 MCP

MCP must not expand tools or configuration in the global Sidebar. Clicking MCP
opens an independent MCP Workspace.

### 4.4 Mobile

On Mobile, the global destinations are available through the Assistant drawer
and open as full-screen destinations. This is the compact form of the same IA,
not a separate product hierarchy.

## 5. Learning Space semantics

```text
Learning Space
= optional long-lived learning context
= Project's Presentation name
```

A Learning Space:

- may reference File;
- may reference Bank;
- may later relate to Conversation;
- does not own or duplicate files;
- does not own or duplicate banks or questions;
- may be deleted without deleting File, Bank, or Question;
- is never a prerequisite for using the app.

`未归类内容` is a virtual view over assets with no Learning Space relation. It
is not a persisted Project and must not be represented as one.

## 6. File Library and future Folder boundary

```text
File Library
= the global asset entry for all LibraryFile values
```

The future Folder contract is bounded to:

```text
Folder        -> File only
LearningSpace -> File / Bank / Conversation context
Subject       -> metadata / filter
```

Folder must not become a universal tree containing Bank, Conversation, Exam,
or other product objects. Whether the first Folder release uses
`File -> 0..1 Folder` is reserved for the F0.1 contract. U1-P0 introduces no
Folder schema or implementation.

## 7. Subject compatibility

Subject is frozen as semantic metadata and a compatibility filter. It must not
be promoted into a new primary organization tree.

The legacy Subject/Folder capability remains accessible until a separately
authorized migration changes or retires it. U1 does not modify its persisted
data or behavior.

## 8. Conversation scope candidate

The target scope shape is recorded for C0 without introducing persistence:

```text
ConversationScope
├─ Global
└─ LearningSpace(projectId)
```

- Scope is selected when a conversation is created.
- After the first message is sent, the Learning Space must not change silently.
- Moving a conversation must be an explicit future action.
- Explicit File/Bank attachments are separate from conversation scope.

U1-P0 does not create conversation or message tables, schema migrations, or a
Conversation domain implementation.

## 9. Assistant context semantics

```text
Conversation scope = implicit long-term context
Composer attachments = explicit context for this conversation
```

The composer `+` means:

```text
添加到本次对话
├─ 文件
└─ 题库
```

It must not create a Learning Space, perform global file ingestion, or silently
change conversation scope.

## 10. MCP Presentation

The MCP page is Shiroha's external-capability entry. Its current contract is:

```text
READ_ONLY
local stdio
exactly 6 MCP v0 tools
```

The Presentation must distinguish:

```text
configured / available
!=
server process currently running
```

U1-P0 does not change the MCP contract, add File/Project tools, add transports,
start a server, or modify runtime composition.

## 11. Agent UI v0 non-goals

The first Agent-first Presentation exposes one assistant identity: `Shiroha`.
It does not expose:

- multiple Agent roles;
- wrong-question, planning, or material Agent selectors;
- model or Provider selectors;
- `temperature`;
- `reasoning_effort`.

Future model and Provider settings belong under `我的 -> AI 与联网`.

U1-P0 graduates the validated Presentation shell only. It does not implement
Agent runtime, message persistence, RAG, Web Search, or autonomous actions.

## 12. Canonical Presentation module

The production Assistant Presentation lives under:

```text
lib/ui/assistant/
```

It consumes the existing `U1WorkspaceFacade` application boundary. UI code
must not depend directly on SQLite, `DatabaseHelper`, or repositories. The
module graduation preserves the validated layout, navigation, failure/retry
states, and current application semantics.

## 13. Stage boundary

U1-P0 freezes IA and graduates Presentation naming. It explicitly does not:

- add a business feature;
- change schema or persisted formats;
- implement Folder;
- implement Conversation persistence;
- implement Agent runtime, RAG, or Web Search;
- change MCP runtime or contract;
- redesign `U1WorkspaceFacade`;
- optimize current N+1 queries;
- change Project domain semantics;
- change F0, J0, T0, or M0 contracts.

The near-term product sequence after this freeze is:

```text
F0.1 File Library Folder
-> B0 Backup
-> C0 Conversation
-> A0 Built-in Agent
```
