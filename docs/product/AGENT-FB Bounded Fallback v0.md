# AGENT-FB Bounded Fallback v0

Status: **Canonical AGENT-FB product/application contract.**

## 1. Authority and scope

This document is the focused authority for the AGENT-FB Bounded Fallback v0
product/application contract. Repository-wide dependency and permission
boundaries remain authoritative in `ARCHITECTURE.md` and
`docs/architecture/adr-003-agent-mcp-and-write-boundary.md`.

AGENT-FB v0 adds a strictly bounded, fault-recovery-only primary-to-fallback
capability for the Shiroha Built-in Agent:

```text
User turn
  -> Primary Profile
  -> (if eligible provider failure occurs before any visible progress or side effect)
  -> Fallback Profile (at most once)
  -> single completed Agent turn
  -> exactly one persisted Assistant Message
```

AGENT-FB v0 is NOT:
- a model router;
- multi-model voting or consensus;
- automatic cost/latency routing;
- a provider expansion stage;
- an MCP v0 expansion.

A0, W0, SPL-1, RAG-1, and S0 contracts remain authoritative and unchanged in
their respective domains.

## 2. Product semantics and configuration

1. **Explicit Opt-in**: The user may configure an optional **备用模型 (Fallback Profile)**
   in Shiroha Agent settings. By default, fallback is disabled (`null` / 不使用备用模型).
2. **Unconfigured / Unchanged**: When no fallback profile is configured, Agent
   behavior is completely identical to A0.
3. **Shared Tuning**: Web enablement, temperature, and reasoning effort are
   shared across Primary and Fallback. No separate tuning configuration is added.
4. **Credential Boundary**: Agent configuration references existing text-model AI
   profiles; it does not store, duplicate, or persist API keys or credentials.
   S0 secure credential storage boundaries remain authoritative.

## 3. AgentConfig and codec

1. `AgentConfig` carries:
   - `mainProfileId` (non-empty bounded string);
   - `fallbackProfileId` (optional bounded string).
2. When `fallbackProfileId` is non-null, it MUST NOT equal `mainProfileId`.
3. Codec rules:
   - **Decode Schema v1**: `fallbackProfileId = null`.
   - **Decode Schema v2**: reads optional `fallback_profile_id`.
   - **Encode Schema v2**: writes `schema_version = 2` with `fallback_profile_id`.
4. Storage:
   - Database remains schema **v22**;
   - Zero SQLite schema migration;
   - Persisted in existing setting key `agent_config_v0`.

## 4. Fallback security gate (`SAFE_TO_FALLBACK`)

Automatic fallback is permitted if and only if **all** of the following conditions hold:

1. **Configured**: A valid, complete fallback profile is configured and resolved;
2. **At Most Once**: The current turn has not yet attempted fallback (`fallbackAttempted == false`);
3. **Not Cancelled**: The turn is not cancelled;
4. **Not Timed Out**: The turn has not exceeded its global timeout;
5. **Within Budget**: The turn has remaining runtime budget (`remainingBudget > 0`);
6. **No Visible Text**: The Primary provider has emitted zero visible text deltas (`visibleText.isEmpty`);
7. **No Web Progress**: The Primary provider has emitted zero Web search progress events;
8. **No Local Tools Dispatched**: Zero local study/read tools have been dispatched (`localCallsUsed == 0` and `toolRoundsUsed == 0`);
9. **No W0 Proposal Staged**: No W0 write proposal has been staged (`proposalStaged == false`);
10. **No StudyPlan Staged**: No StudyPlanDraft has been staged (`studyPlanDraftStaged == false`);
11. **No Retrieval Egress Approval**: The turn does not have approved file-content retrieval egress (`approvedFileIds.isEmpty` / `retrievalGrant == null`);
12. **Pre-Persistence**: The turn has not entered Assistant message persistence.

If any single condition is violated, automatic fallback is **STRICTLY FORBIDDEN**.
The turn terminates with the Primary's failure mapping, allowing the user to
inspect and manually retry.

## 5. Eligible provider failures

Fallback ONLY responds to typed, recoverable provider failures:
- `authentication`
- `rateLimited`
- `temporarilyUnavailable`
- `timeout` (only when global turn has not timed out and remaining budget > 0)
- `unsupportedModel`
- `incompleteResponse`
- `malformedResponse`
- `internalError`

The following are **INELIGIBLE** for fallback:
- `cancelled` (user action)
- `invalidRequest` (malformed client request)
- `unsupportedCapability` (configuration mismatch)
- All Application, Domain, Database, local tool, or internal logic exceptions.

## 6. Turn identity, lifecycle, and concurrency invariants

1. **Turn Identity**: Primary and Fallback share:
   - the same `conversationId`;
   - the same `userMessageId`;
   - the same `turnRequestId`;
   - the same `AgentTurnSession`;
   - the same `AgentCancellationController` / token;
   - the same global `turnTimeout` and `Stopwatch` budget.
2. **Single Assistant Message**: Successful completion persists exactly one
   final Assistant Message.
3. **No Continuation Leak**: Provider continuation state is NEVER transferred
   across providers. Fallback initiates a clean initial provider round with
   canonical system prompt, history messages, tool definitions, and tuning config.
4. **Permanent Switch within Turn**: Once fallback is activated, all remaining
   rounds in that turn use the Fallback provider. The runtime never switches back
   to Primary within the same turn.
5. **Terminal Failure**: If Fallback itself fails, no third attempt is made; the
   turn returns the typed failure from Fallback.

## 7. Retrieval and safe-write invariants

1. **RAG-1 Egress Grant Boundary**: File-content retrieval authorization is
   bound to the specific `providerProfileId`. Fallback across providers would
   violate this grant without re-prompting the user. Therefore, turns with
   approved retrieval file IDs will NOT automatically fallback.
2. **W0 / SPL-1 Side-Effect Barrier**: Once a W0 write proposal or StudyPlan
   draft is staged, the tool side effect is recorded. Provider failure after staging
   must not trigger fallback or duplicate proposals.

## 8. Missing / deleted fallback profile

1. If a configured fallback profile is deleted or becomes incomplete/invalid:
   - Primary remains fully functional;
   - Fallback is treated as unavailable (`null`);
   - The Agent does NOT fail or lock out the user due to an invalid optional fallback.
2. The Settings UI displays a bounded warning notice when the saved fallback
   profile is unavailable, prompting the user to update or clear it.

## 9. Explicit non-goals

- No new provider protocols or HTTP clients (OpenAI, Claude, Gemini adapters);
- No runtime schema migration (remains schema v22);
- No multi-turn fallback history persistence;
- No autonomous or silent write execution;
- No MCP v0 modification or tool addition;
- No UI redesign.
