# CONV-MOVE Conversation Relocation v0

Status: **Canonical CONV-MOVE product and application contract. CLOSED / FROZEN.**

## 1. Authority and Scope

This document is the canonical authority for **CONV-MOVE Conversation Relocation v0**.

CONV-MOVE allows a user to explicitly relocate an existing persisted Conversation:
- `Global` ↔ `Learning Space A` ↔ `Learning Space B`
- `Unavailable Learning Space` → `Global` or `Learning Space (existing)`

Core invariant:
```text
same Conversation identity
+ same messages
+ same attached files
+ same title
+ same createdAt
→ explicit scope relocation
→ updated scope
→ monotonically updated recency
→ future Agent turns use new scope
```

CONV-MOVE is NOT:
- copying or cloning a conversation;
- creating a new conversation or deleting/reinserting rows;
- rewriting, mutating, or cloning message rows;
- Project ownership migration;
- automatic scope migration;
- conversation deletion (CONV-DELETE is separate).

---

## 2. Transition Semantics

### Allowed Transitions
1. `Global` → `LearningSpace(A)`
2. `LearningSpace(A)` → `LearningSpace(B)`
3. `LearningSpace(A)` → `Global`
4. `UnavailableLearningSpace` → `Global`
5. `UnavailableLearningSpace` → `LearningSpace(existing)`
6. Same scope → deterministic no-op (`moved = false`, `updatedAt` unchanged).

### Forbidden Targets
- Moving to `ConversationScope.unavailableLearningSpace()` is strictly forbidden. It is a lifecycle state, not a selectable target. Attempting to do so fails safely with `ConversationFailure.scopeUnavailable`.
- Target `LearningSpace(projectId)` where the project does not exist fails safely with `ConversationFailure.projectNotFound` and performs zero mutations.

---

## 3. Persistence & Transaction Contract

- **Runtime Schema**: Remains at **v22**. No schema migration or new columns/tables.
- **Transaction**: In a single SQLite transaction:
  1. Load existing conversation.
  2. Validate target scope (if `LearningSpace`, verify target Project exists).
  3. Compare `currentScope == targetScope`. If equal, return `moved = false` with zero updates and no timestamp change.
  4. If different, update `scope_kind`, `project_id`, and `updated_at`.
  5. Monotonic recency: `newUpdatedAt >= oldUpdatedAt + 1ms`.
  6. Return updated `Conversation` and `moved = true`.

---

## 4. Boundary Invariants

1. **Active Turn Safety**: If an Agent turn is currently running (`hasActiveTurn` or `isSending`), relocation in Presentation is blocked. User is notified: `"请先停止当前生成"`.
2. **Retry Invalidation**: Successful move MUST clear the Presentation retry binding (`canRetry = false`). Future messages under the new scope must be sent as fresh turns.
3. **Retrieval Transient Approval Invalidation**: Successful move MUST clear transient UI retrieval authorization (`retrievalApprovedForNextTurn = false`). Attached files remain attached.
4. **W0 / StudyPlan Invariants**: Move does not modify existing `AgentWriteProposal` or `StudyPlanDraft`. While a proposal or study plan action is pending, move is blocked.
5. **Agent New Turn Scope**: Future turns re-load the conversation scope from persistence, seamlessly adopting the relocated scope.

---

## 5. Presentation Flow

- **Entry**: Space selector in Assistant top header (`u1-ux0-space-selector`).
  - Draft conversation: instant scope selection without confirmation dialog.
  - Persisted conversation: opens "移动对话" sheet/dialog listing Global and all live Learning Spaces.
- **Same Target Selected**: Closes sheet; zero confirmation, zero command.
- **Different Target Selected**: Shows Confirmation Dialog:
  - Title: `移动对话？`
  - Body: `将此对话移动到「{TARGET}」。\n\n历史消息和已附加文件不会改变。\n之后 Shiroha 的回复和本地检索将使用新的对话范围。`
  - Actions: `取消` / `移动`
- **Cancel**: Zero move calls.
- **Confirm**: Executes exactly one move command, updates header, clears retry/retrieval approval, refreshes caches, and displays SnackBar confirmation.
