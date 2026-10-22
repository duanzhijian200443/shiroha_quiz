# Assistant artifact presentation (AR-R8)

This is the focused source contract for Assistant controller/artifact
decomposition. It preserves the W0 and SPL-1 business contracts and the existing
Assistant layout. Source delivery is independently reviewable; it does not
satisfy or waive AR-R6B production admission, real-client acceptance or Windows
Host/security prerequisites. No Trial 1A or G0-L1/L2/I experiment is activated.

## Ownership and composition

`AssistantWorkspaceShell` owns one `ConversationController` for its lifetime.
The controller retains conversation/message/Turn coordination, streaming,
configuration failures, cancellation, retry targets and diagnostic presentation.
It owns and disposes one `AssistantArtifactController`, which alone holds the
transient artifact display fields, source identity indexes, action wait state
and replacement-confirmation observation. Existing public ConversationController
artifact properties and methods forward to that same instance; they are a
compatibility facade, not another mutable state store.

`AgentWriteProposalService` owns the typed W0 Proposal lifecycle and its approved
write command. `StudyPlanDraftService` owns the typed transient draft lifecycle;
`StudyPlanCommandService` owns adoption/replacement. Presentation retains exact
identities and projections, never a second business lifecycle, writer, authority
token or persisted artifact record. Formal revalidation/CAS and unknown-outcome
reconciliation remain in those Application owners.

The existing Module UI Contribution mechanism uses its finite
`assistantArtifact` slot: `missing_answer_artifact` and `study_plan_artifact` are
contributed by the corresponding production modules. The root passes the frozen
contributions through MainScreen and AssistantWorkspaceShell. An explicitly empty
list supplies no artifact UI/actions; callers omitting the new optional parameter
retain the two existing presenters. Contribution visibility never grants COMMIT.

`AssistantArtifactCards` contains the retained dedicated W0 and SPL-1 card
presenters and safe preview formatting. AssistantScreen hosts that bounded slot
and keeps message/composer rendering. There is no generic Widget registry,
generic approve action, navigation redesign or GeneratedQuestion Review rewrite.

## Source and recovery

ConversationController admits events only from its current session/Turn epoch.
It supplies the exact Conversation/User Message identities captured when that
Turn began. Artifact coordination validates a known typed Proposal/draft against
both source identities before binding the event. An unknown identity in a
configured service cannot become an actionable card. The existing staged-event
preview bridge remains compatible; without the owning service it cannot perform
a business action. Unknown W0 outcome strings remain invalid; unknown SPL-1
outcomes project no card.

The transient indexes retain one identity per source User Message, grouped by
Conversation and artifact kind. Different Turns coexist. Projection/restoration
keeps the first pending artifact reachable, then advances to the next pending
artifact after a terminal action and notifies listeners. Superseded replay cannot
hide the current pending identity. Restoration re-reads outcome/preview from the
typed Application owner and prunes missing or mismatched identities.

Starting a draft or switching Conversations clears only visible presentation;
it does not approve, reject, supersede or cancel formal work. Returning restores
the known source bindings. Deletion drops only that Conversation's transient
bindings. Rebuilding/removing AssistantScreen or its cards retains the workspace
owner; disposing the workspace disposes that owner and cancels its Agent session.
These bindings are not durable recovery: a new controller/service lifetime does
not invent bindings after process restart.

## Actions and asynchronous completion

Card callbacks capture the displayed artifact identity and presentation epoch.
Callbacks retained across a card change or away-and-back navigation refuse action.
Replacement confirm/cancel callbacks additionally capture the exact confirmation
observation; reopening confirmation for the same draft invalidates older callbacks.
Direct compatibility entrypoints recheck the current artifact, source
Conversation, module visibility, moving/Turn restrictions and in-flight guard.
Approval/adoption remain disabled while a Turn is active; existing rejection
semantics remain unchanged.

Action wait markers are per identity and describe only outstanding Presentation
calls. They survive passive dismissal and prevent duplicate dispatch while the
Application owner independently arbitrates lifecycle transitions. Late results
cannot overwrite another artifact or another Conversation, reopen a stale
replacement prompt, or adopt automatically after dismissal. If the same artifact
has been restored while an earlier call settles, coordination refreshes its typed
owner rather than projecting the dismissed call's stale result. Deletion and
Dispose do not let a late result recreate bindings or notify a dead UI. An
already-entered formal write is still settled by its original Application owner.

## Verification boundary

Deterministic regressions cover the retained Controller/Workspace/card API,
stream/cancel/failure/retry behavior, W0/SPL commands, different source Turns,
passive dismissal/restoration, stale callbacks/confirmation, duplicate actions,
late results, deletion, card reconstruction and Dispose. Module parity retains
Agent prompts/tool envelopes and MCP exposure; architectural source guards retain
Runtime, storage and permission boundaries. This is source/offline acceptance
only, not real-provider/device/runtime or AR-R6B production acceptance.
