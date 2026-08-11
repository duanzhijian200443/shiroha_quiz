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
Learning Space home opens an independent Main Workspace. C0 supplies the
expansion with lazily loaded persisted conversations, while the home remains an
independent destination.

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
or other product objects. F0.1 freezes the first Folder release as
`File -> 0..1 Folder`, with flat folders and a virtual unclassified view.
Folder membership is independent of Learning Space membership. U1-P0 itself
introduced no Folder schema or implementation; the subsequent additive v18
stage supplies it.

## 7. Subject compatibility

Subject is frozen as semantic metadata and a compatibility filter. It must not
be promoted into a new primary organization tree.

The legacy Subject/Folder capability remains accessible until a separately
authorized migration changes or retires it. U1 does not modify its persisted
data or behavior.

## 8. Conversation scope

The Conversation scope contract established by C0 and retained by A0 is:

```text
ConversationScope
├─ Global
└─ LearningSpace(projectId)
```

- Scope is selected when a conversation is created.
- After the first message is sent, the Learning Space must not change silently.
- Moving a conversation must be an explicit future action.
- Deleting the Project preserves the conversation as an unavailable
  LearningSpace scope; it never converts to Global.
- Clicking New Conversation creates only a transient draft. The first valid
  User Message atomically persists the Conversation, Message, and selected File
  relations.
- Explicit File attachments are separate from conversation scope and from
  Project/Folder membership. Bank attachments remain deferred until stable Bank
  identity exists.

## 9. Assistant context semantics

```text
Conversation scope = implicit long-term context
Composer attachments = explicit context for this conversation
```

The composer `+` currently means:

```text
添加到本次对话
├─ 文件（真实 File Library 候选）
└─ 题库（deferred）
```

It must not create a Learning Space, perform global file ingestion, or silently
change conversation scope.

A0 supplies attached File metadata to Shiroha as explicit Conversation context.
It does not supply file bytes, extracted text, PDF pages, images, OCR output, or
vision input. The metadata-only attachment boundary does not change File
ownership or Conversation scope.

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

## 11. Agent UI v0 and A0 amendment

The first Agent-first Presentation established one assistant identity:
`Shiroha`. That U1 decision remains current. The product does not expose
multiple Agent roles or wrong-question, planning, or material Agent selectors.

At C0 completion, the Presentation intentionally had no Agent runtime, Web
capability, model-profile selection, temperature, or reasoning-effort controls.
It persisted Conversation/User Message history while showing a non-persisted
placeholder status. This remains the historical C0 boundary.

Before A0, U1 assigned future model and Provider settings to
`我的 -> AI 与联网`. That was the pre-A0 placement decision and remains
historical U1/C0 truth.

A0 supersedes that runtime/settings state and refines the settings route without
changing the U1 identity or primary navigation contract:

- the Assistant starts a real Agent turn over a persisted User Message;
- streamed text and Web/tool progress are transient;
- only the final persisted Assistant Message enters Conversation history;
- Agent-specific profile selection, Web and tuning live at
  `我的 -> Shiroha Agent 设置` and reference an existing complete main
  text-model profile;
- Provider credentials remain owned by the separate
  `我的 -> AI 与知识库 -> AI 服务` surface and are neither edited nor duplicated
  by Agent settings;
- Web remains optional and available only when enabled and supported by the
  selected provider.

A0 still does not add autonomous mutations, Agent writes, RAG, file-content
reading, or multiple Agent identities. The full current runtime contract is
`docs/product/A0 Built-in Agent v0.md`.

## 12. Canonical Presentation module

The production Assistant Presentation lives under:

```text
lib/ui/assistant/
```

It consumes the existing `U1WorkspaceFacade` and the dedicated
`ConversationService` application boundary. C0 does not expand the workspace
facade. UI code must not depend directly on SQLite, `DatabaseHelper`, or
repositories.

A0 adds injected Agent settings and turn-start seams to this Presentation
module. The UI projects safe transient events and persisted terminal results;
it does not call provider adapters, MCP transport, repositories, or SQLite
directly.

## 13. Stage boundary and A0 supersession

### 13.1 Historical C0 boundary

The C0 transition preserved the U1 IA while adding persisted conversation
foundation. At C0 completion it explicitly did not:

- implement Agent runtime, RAG, or Web Search;
- change MCP runtime or contract;
- redesign `U1WorkspaceFacade`;
- optimize current N+1 queries;
- change Project domain semantics;
- change F0, J0, T0, or M0 contracts.

Sending stores the User Message and displays the non-persisted status
`Shiroha 回复能力尚未接入，消息已保存`. It must not create a mock Assistant row.

That placeholder behavior is historical C0 truth; it is not the current A0
runtime behavior.

### 13.2 A0 amendment

A0 preserves the U1 IA and C0 Conversation lifecycle while adding the bounded
READ_ONLY Shiroha runtime. A send now persists the User Message before starting
the Agent turn, projects streaming as transient state, and adds only the final
persisted Assistant Message to history. Retry targets the same persisted User
Message, and one Conversation has at most one active turn.

Attached Files remain explicit Conversation context but are metadata-only in
A0. A0 does not add RAG, file-content access, Agent writes, MCP expansion, or a
schema change. The current roadmap transition is `A0 COMPLETE -> W0 CURRENT`.

### Unclassified terminology

- File Library「未分类」：没有 Folder relation 的 LibraryFile。
- Learning Space「未归类内容」：没有 Project relation 的资产。
- 两者属于不同维度的 virtual view，不应合并或互换。

B0 Backup is deferred, not cancelled.
