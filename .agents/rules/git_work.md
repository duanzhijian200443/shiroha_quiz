# Safe Git Inspection and Authorized Action Protocol

## Purpose and authority

Read this rule only when the task concerns Git status, diffs, staging, commit
preparation, branches, history, tags, or pushing, as routed by `AGENTS.md`.

This file never grants Git write authority. Authority comes only from the
current user request, `AGENTS.md`, the active role, and an applicable task
package. A request that mentions `commit`, `push`, `backup`, or a similar word
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

Before a Git write, verify all of the following:

1. the exact action is explicitly authorized;
2. the current branch, worktree, and `HEAD` match the task target;
3. every affected path is explicitly allowed;
4. staged content contains no unrelated user changes;
5. the action is not destructive or history-rewriting;
6. any role-specific authorization fields in `AGENTS.md` are present.

Authorization is action-specific:

- staging does not authorize a commit;
- a commit does not authorize a push;
- a push does not authorize a merge, tag, or release;
- branch or worktree creation requires its own explicit authorization.

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
