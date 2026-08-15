# U1-LIFECYCLE-UX Closure v0

Status: **Canonical U1-LIFECYCLE-UX product and application contract. FROZEN / COMPLETE.**

## 1. Authority and Scope

This document is the canonical authority for **U1-LIFECYCLE-UX Conversation / Learning Space action-entry closure v0**.

Goals:
1. **Conversation Action Entry**: Move Conversation deletion entry to the right-hand action zone (`...` action menu) of each conversation item across Recent and Learning Space conversation lists.
2. **Learning Space Expand UX**: Remove the dedicated chevron button; clicking the entire space card body expands/collapses the space conversation list.
3. **Learning Space Action Menu**: Replace the previous house-style home button with a unified `...` action menu containing "进入主页" and "删除学习空间".
4. **Learning Space Delete & Conversation Delete Closure**: Audit and complete the formal deletion flows and controller-level authority guards.

Non-goals:
- No IA redesign or overall sidebar redesign;
- No new lifecycle concepts;
- No bulk deletion, drag-and-drop, pinning, archiving, or conversation renaming;
- No runtime schema changes (remains **v22**).

---

## 2. Interaction Invariants

### Conversation Item
- **Tap Row Body**: Opens conversation (`onOpenConversation(conversationId)`).
- **Tap Right `...` Action**: Opens action menu without triggering conversation opening.
- **Delete Action**: Triggers a confirmation dialog.
  - Cancel: Zero delete calls.
  - Confirm: Exactly one delete call.

### Learning Space Card
- **Tap Card Body**: Expands or collapses the space conversation list.
- **Tap Right `...` Action**: Opens the space action menu without triggering expansion/collapse.
- **Menu Items**:
  1. `进入主页` (`home`): Navigates to Learning Space home workspace.
  2. `删除学习空间` (`delete`): Shows confirmation dialog and executes deletion on confirmation.
- **Hit Targets**: Full card header is touch/mouse accessible for expand/collapse; `...` menu has its own hit target.

---

## 3. Deletion Semantics & Data Boundaries

### Learning Space Delete
- **Data Boundary**:
  - `projects` row is removed;
  - `project_files` and `project_banks` relation entries are removed (unlinked);
  - Underlying `library_files`, question banks, and questions are **NOT** deleted;
  - Associated conversations have their `project_id` set to `NULL` (`ON DELETE SET NULL`), transitioning safely to `unavailableLearningSpace` with all messages and files preserved.
- **Post-Delete UI State**:
  - Learning space is removed from the list;
  - If expanded, collapses smoothly;
  - If current workspace was viewing the deleted space home, falls back safely to default workspace without dangling state;
  - Lists and cache refresh safely.

### Conversation Delete
- **Data Boundary**:
  - `conversations` row is removed;
  - `conversation_messages` and `conversation_files` relations are removed via cascading deletion;
  - Underlying `library_files`, question banks, and learning spaces are **NOT** deleted.
- **Controller Authority**:
  - `deleteActiveConversation()` and `deleteConversation(conversationId)` reject when:
    - `hasActiveTurn` (safe message: "请先停止当前生成");
    - `isSending` (safe message: "请先停止当前生成");
    - `isMovingConversation` (safe message: "请等待对话移动完成").
- **Two-Phase Durable Delete**:
  - **Phase A (Authoritative Delete)**: `service.deleteConversation(conversationId)`. If fails, active state unchanged and returns `false`.
  - **Phase B (Best-effort Projection Refresh)**: Refresh lists. Once Phase A succeeds, projection refresh failures never retroactively revert deletion to `false`.
- **Post-Delete State (Active Thread)**:
  - `activeThread = null`;
  - `_threadRevision++`;
  - `draftScope = ConversationScope.global()`;
  - `draftFileIds.clear()`;
  - `retrievalApprovedForNextTurn = false`;
  - `canRetry = false`, retry bindings cleared;
  - Transient proposal / study plan bindings cleared.
