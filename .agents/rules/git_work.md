# Safe Git Inspection and Authorized Action Protocol

## Purpose and authority

Read this rule only when the task concerns Git status, diffs, staging, commit
preparation, branches, history, tags, or pushing, as routed by `AGENTS.md`.

This file never grants Git write authority. Authority comes from explicit user
instructions, including the user-approved Executor policy and direct approval
source recorded in `AGENTS.md` section 3 and implemented by the active role file.
A role file or task package never creates authority by its own declaration.
A request that mentions `commit`, `push`, `backup`, or a similar word
authorizes only the exact action explicitly requested; it does not authorize
later Git actions, unrelated file changes, or broader staging.

When instructions conflict, follow the precedence and more-restrictive-rule
policy in `AGENTS.md`.

## Read-only inspection

Use non-mutating commands as needed to establish the real repository state:

- `git status --short`;
- `git diff` and `git diff --cached`;
- `git diff --check`;
- `git branch --show-current`;
- `git rev-parse HEAD`;
- bounded `git log` and `git show` queries.

Inspect tracked, staged, unstaged, and untracked paths before proposing or
performing any authorized write. Preserve unrelated user changes.

## Git write requirements

### Task-start baseline

Before creating a branch or editing for a new independent task:

1. Inspect status and worktree ownership; preserve unrelated changes and old task
   branches. Verify the intended repository/remote and query its current default
   branch; a cached `origin/HEAD`, local branch name or old PR head is insufficient.
2. With existing fetch authority, fetch the remote default branch and verify its
   tip against current remote facts. If it advanced during verification, refresh
   the evidence before proceeding; if it cannot be verified, stop.
3. Compare the local default branch with that verified tip. Safely fast-forward a
   behind local default, or establish a missing local default with the required
   authority, before task-branch creation. Ahead/diverged branches or an unsafe
   checkout require bounded diagnosis and user direction; no reset, rebase,
   destructive restore, automatic stash or push-to-default alignment.
4. Record the remote/default branch, verified commit and alignment result, then
   create the authorized task branch from that exact default-branch commit.
   Recheck its initial HEAD. A merged PR branch and its PR-only commits are never
   a new-task baseline; after Squash Merge, the actual remote default-branch
   history owns the baseline, not the original PR head.

This preflight happens at task start, not at PR delivery. Fetch, alignment,
branch/worktree creation and checkout still need their applicable authority;
missing authority blocks dependent writes, not independent read-only work.
For continuation of the same unfinished authorized task before PR creation,
verify and reuse its existing non-default branch/worktree and original verified
baseline under `AGENTS.md` section 7. Check task identity, scope, authority,
baseline evidence, current HEAD/dirty state and writer ownership; inherit repair
counts. Do not rerun new-task alignment or create a new branch solely for
resumption. An OPEN PR is not a prerequisite for otherwise authorized work;
missing baseline evidence, target drift and explicit delivery limits still apply.

Repairs/supplements to an existing PR instead verify and reuse its OPEN source
branch. If it is merged/closed or the identity drifts, stop before writing/pushing.

### Action checks

Before a Git write, verify all of the following:

1. the exact action is explicitly authorized;
2. the current branch, worktree, and `HEAD` match the task target;
3. every affected path is inside the authorized task responsibility; if `Strict path whitelist: yes` is set, every affected path is also explicitly listed;
4. staged content contains no unrelated user changes;
5. the action is not destructive or history-rewriting;
6. task/user authority, including applicable permissions recorded in the active
   role file, is known; other omitted actions remain unauthorized. A delegated
   package may record it using the optional `docs/agents/README.md` template.

Authorization is action-specific:

- staging does not authorize a commit;
- a commit does not authorize a push;
- a push does not authorize PR creation, merge, tag, or release;
- initial work creates an authorized dedicated non-default branch; pre-PR
  continuation reuses its verified task branch and original baseline; same-PR
  repair reuses the verified OPEN PR branch. A writable package may
  record existing branch-creation authority but cannot grant it;
- worktree creation is separate and only needed for parallel writers or explicit checkout isolation.

Task packages normally provide expected ownership paths, not an exhaustive file
list. Only with `Strict path whitelist: no` may directly necessary coupled paths
be added under the repository rules and reported in handoff. With
`Strict path whitelist: yes`, stop before any unlisted path until explicit
authorization expands the whitelist. Staging remains exact-path scoped.

Use path-scoped commands such as:

```text
git add -- <exact-paths>
git commit -m "<reviewed-message>"
```

Never use `git add .` or `git add -A`. Do not create or modify
`DEVELOPMENT_LOG.md` unless that file is explicitly within the task's allowed
write scope and the user requested the change. Do not infer a changelog update
from commit authorization.

## Commit-message preparation

Generate a commit message only from the inspected diff. Prefer the repository's
existing commit style. A suggested Angular-style form is:

```text
<type>(<scope>): <subject>

[optional body]
```

Do not stage, commit, or push merely because a message was requested.

## Post-action verification

After any authorized Git write, re-run the relevant checks:

- `git status --short`;
- `git diff` and/or `git diff --cached`;
- `git rev-parse HEAD` after a commit;
- the remote/branch identity after an authorized push.

Report the exact action performed, affected paths, resulting commit SHA when
applicable, skipped actions, failures, and remaining dirty state. Never claim a
commit or push succeeded unless the command was executed successfully.
