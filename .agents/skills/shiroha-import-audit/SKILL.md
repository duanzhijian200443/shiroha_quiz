---
name: shiroha-import-audit
description: Run bounded, redacted, offline acceptance for changes to OCR, import_pipeline, import_review, QuestionDraft, content auditing, answer fusion, or Import Acceptance in Shiroha Quiz. Use when validating those import-path changes without live providers or private source documents.
---

# Shiroha Import Audit

## Use safe inputs only

Use only:

- synthetic fixtures;
- existing redacted, read-only Replay cases;
- focused import tests;
- the offline mode of `tool/import_acceptance.dart`;
- Provider call-count checks;
- aggregate, redacted statistics.

Do not:

- call real OCR or any network service;
- read a saved key or credential;
- open a private PDF;
- write, refresh, or replace Replay data;
- run a Windows build or start the application;
- print complete question text, answers, OCR content, Provider bodies, credentials, or absolute paths.

Stop and request explicit authorization if the requested evidence requires a
forbidden input or side effect.

## Run a bounded audit

1. Read the task's acceptance criteria and identify the smallest relevant
   synthetic fixture, redacted Replay, and focused tests.
2. Confirm that the selected acceptance invocation is offline and has no
   refresh or write option.
3. Run only the focused tests and offline acceptance explicitly required by
   the task.
4. Verify that Provider calls remain at the expected count, normally zero.
5. Report only safe identifiers, counts, issue codes, stages, statuses, and
   verdicts.
6. Stop after the required evidence is collected; do not broaden into real OCR
   or a full test suite.

## Record required metrics

Record these fields when the selected fixture or Replay exposes them:

- `Questions`
- `Question numbers`
- `Hard issues`
- `Review issues`
- `Missing answers`
- `Repair candidates`
- `Provider calls`
- `Reference answer attachments`

Mark an unavailable metric as `NOT VERIFIED`; do not infer or fabricate it.

## Assign the verdict

- `PASS`: every task-specific requirement is satisfied.
- `REVIEW`: the questions remain safe to import, but expected manual review
  items remain.
- `FAIL`: there are missing or duplicate questions, incorrect answer
  attachment, a Hard issue, an unexpected Provider call, or a broken safety
  contract.

Do not turn a known, safe Review that the task explicitly permits into an
implementation failure. Report that Review and its stable issue code without
including source content.
