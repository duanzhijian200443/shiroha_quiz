# Shiroha Quiz Development Instructions

## Required context

Before making non-trivial changes, read:

- `ARCHITECTURE.md`
- Relevant files under `.agents/rules/`
- Relevant role instructions under `docs/agents/`
- Relevant existing tests
- The implementation surrounding the target code

Do not assume a rule file has been read unless it was explicitly opened during
the current task.

## Role activation

- `ROLE: PLANNER` requires reading `docs/agents/planner.md`.
- `ROLE: EXECUTOR` requires reading `docs/agents/executor.md`.
- `ROLE: VERIFIER` requires reading `docs/agents/verifier.md`.
- `ROLE: REVIEWER` requires reading `docs/agents/reviewer.md`.
- After successfully reading the required role file, explicitly declare which
  role file has been loaded before continuing the task.
- If the required role file does not exist or cannot be read, stop the task and
  report the problem. Do not continue under an assumed role.
- Once activated, keep the same role for the entire task. Do not switch roles
  during the task unless the user explicitly instructs you to do so.

## Architecture

Preserve the project dependency direction:

UI -> Service -> Repository -> DatabaseHelper

- UI and Service layers must not directly access SQLite or `DatabaseHelper`.
- Database operations must go through the appropriate Repository.
- Business logic belongs in Services, not Repositories or Widgets.
- Repositories are responsible for persistence concerns.
- Do not introduce cross-layer shortcuts for convenience.
- Follow the architecture documented in `ARCHITECTURE.md`.

## Development workflow

For each implementation task:

1. Inspect the relevant implementation and tests.
2. Verify that the reported problem actually exists.
3. State a concise implementation plan.
4. Confirm the allowed modification scope.
5. Add or update regression tests when fixing behavior.
6. Make the smallest coherent change.
7. Run focused validation.
8. Report changed files, validation results, and remaining risks.

## Change discipline

- Do not refactor unrelated code.
- Do not rename unrelated symbols.
- Do not reformat unrelated files.
- Do not silently change public behavior.
- Do not silently change persisted data formats.
- Preserve backward compatibility unless explicitly authorized.
- Reuse existing abstractions before introducing new ones.
- Do not add, remove, or upgrade packages without explicit approval.
- Never modify generated files manually.
- Do not modify files outside the declared task scope.
- If an out-of-scope file must be changed, stop and request approval first.

## Agent safety boundaries

- Only operate inside this repository.
- Preserve all existing user changes.
- Never discard or overwrite unrelated changes.
- Never run destructive Git commands, including:
  - `git reset --hard`
  - `git clean -fd`
  - `git clean -fdx`
  - destructive `git checkout`
  - destructive `git restore`
  - force push
- Never commit, push, merge, rebase, or create tags unless explicitly requested.
- Never access, print, copy, expose, or modify:
  - API keys
  - access tokens
  - signing keys
  - keystore files
  - passwords
  - credentials
  - environment secrets
  - private configuration
- Do not enable or use network access unless the task explicitly requires it.
- Do not expand a task merely because nearby problems were discovered.
- Report out-of-scope problems separately instead of fixing them automatically.

## Security and privacy

Never write the following values to logs:

- API keys
- access tokens
- Authorization headers
- credentials
- complete user prompts
- complete answer contents
- private file contents
- sensitive absolute paths

Treat the following areas as high risk:

- logging and redaction
- global exception handling
- database migrations
- import pipelines
- async task recovery
- file rotation
- isolate or multi-process coordination
- API key storage

High-risk changes should include failure-path tests and concurrency tests where
applicable.

## Flutter validation

Use focused validation during implementation.

Run the full validation workflow only when requested or before a release:

```powershell
.\scripts\verify.ps1
```

Individual validation commands may include:

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

Never claim a command or test passed unless it was actually executed.

## Reporting

At the end of a task, report:

- files changed;
- behavior changed;
- tests and commands executed;
- exit status;
- failures or skipped checks;
- remaining risks;
- out-of-scope findings.

Do not hide failed validation.
