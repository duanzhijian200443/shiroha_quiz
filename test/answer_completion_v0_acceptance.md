# Answer Completion V0 acceptance evidence

Package C deterministic Executor evidence, 2026-09-28. Base:
`90d5efe49ef7d5d33e22df33b684c0c7b41a3464` (merged Packages A and B).
This is a test evidence map, not canonical contract authority or independent
Reviewer approval. Exact delivered head and remote CI are recorded in the PR.

## Authoritative suites

Paths below are relative to the repository root.

| Key | Authoritative file |
| --- | --- |
| I | `test/answer_completion_import_commit_acceptance_test.dart` |
| Q | `test/answer_completion_q0_acceptance_test.dart` |
| U | `test/answer_completion_ui_acceptance_test.dart` |
| P6 | `test/application/answer_completion/answer_completion_supplemental_test.dart` |
| D0 | `test/application/answer_completion/document_question_set_seed_test.dart` |
| D1 | `test/core/database/answer_completion_v28_schema_test.dart` |
| B0 | `test/backup/answer_completion_backup_test.dart` |
| G | `test/answer_entry_guard_ui_test.dart` |

## Requirement → authoritative test → result

All PASS entries below refer to the local run of the exact command further
below: 22 files, 392 tests passed, exit 0. Parameterized test families run for
both typed and legacy routes where indicated. No production code was changed.

| Requirement | Authoritative test name / family | Result |
| --- | --- | --- |
| All-missing typed set | Q: `all missing, 21 answered + 1 missing, explicit empty and exact completed` | PASS |
| 21 answered + 1 missing | Q: same test; total 22, missing 1, answered 21 | PASS |
| Full answer file: noOp/fill/conflict; no silent replacement | P6: `full ordered set keeps noOp/fill/conflict and isolates another Q1 in same bank` | PASS |
| Same-bank multiple Q1 isolation; ambiguity retained | P6: preceding test + `answered duplicate locator remains ambiguity evidence` | PASS |
| Legacy-only truthful and non-mutating | Q: `legacy-only, mixed and corrupt stay visible and never shrink`; P6: `empty/mixed/ineligible set cannot bind; caller cannot substitute scope` | PASS |
| Mixed/corrupt truthful; no legacy fallback | Q and P6: preceding tests | PASS |
| Typed explicit-empty is answered | Q: all-missing/21+1 test; I: `V0 typed committed lifecycle preserves identity until member removal` uses the real answer mutation authority | PASS |
| Source-file deletion preserves set, questions, sidecars, review and membership | I: `V0 typed/legacy committed lifecycle preserves identity until member removal`; Q: `null provenance differs from deleted; source deletion preserves set` | PASS |
| Artifact replacement/removal and ImportTask cleanup preserve committed data | I: V0 lifecycle tests compare every durable row after each real repository operation | PASS |
| Folder move preserves set identity and membership | I: V0 lifecycle tests use `updateBankFolder` and compare durable rows | PASS |
| Content/answer edit preserves membership/review; counts are dynamic | I: V0 lifecycle tests use legacy `updateQuestion` / typed `updateTypedAnswer` and requery | PASS |
| Question delete cleans membership | I: V0 lifecycle tests use `QuestionRepository.deleteQuestion`; D1: `question deletion cascades membership and clears the empty set` | PASS |
| Last member removal deletes set | D1: `removing the last member deletes the empty set` and question-deletion test | PASS |
| Question bank move detaches, never auto-attaches | D1: `a question bank move detaches membership without re-attaching`; I: V0 final-member move checks destination queue | PASS |
| Independent successful imports produce distinct sets/Questions; duplicate confirm cannot duplicate | I: `typed/legacy v4 writes ordered actual storage IDs and duplicate import is independent` | PASS |
| Typed writer rollback | I: `typed questions/question_v2_payloads/review_states/set/member/completion CAS failure rolls back the entire outer transaction` | PASS |
| Legacy writer rollback | I: `legacy questions/review_states/set/member/completion CAS failure rolls back the entire outer transaction` | PASS |
| Set/member failure rolls back the outer transaction | I: set/member families above; partial member insertion fails at position 1 | PASS |
| Historical/manual typed stays ungrouped and may use P7 | Q: `ungrouped only valid typed missing; answered leaves without synthetic set`; U: `ungrouped fill refreshes persisted projection and disappears`; D1: `v27 to v28 migration is additive and never backfills` | PASS |
| B0 round-trip setId/order/membership, null/missing provenance | B0: `v28 export and restore preserves ordered set with null/deleted-file-id` | PASS |
| Changed set bank rejected; same-value allowed | D1: `set bank_name is immutable while same-value updates stay legal` | PASS |
| Trigger/schema corruption rejected by restore | B0: `staged restore delegates structural rejection to v28 authority`; empty/cross-bank relation rejection tests | PASS |
| v3 compatibility | I: `typed/legacy v3 without seed stays compatible` | PASS |
| v4 invalid-seed matrix fails closed with zero learning writes | I: typed/legacy missing/null/wrong type/unknown version/missing field/extra field/oversize and incompatible-entry families; D0 exact envelope/byte/scalar/presence tests | PASS |
| Metadata replacement / restart / Review / OCR retry preserves authoritative seed | I: `reserved null/valid seed survives replacement Review reload and OCR retry`; `typed v4 create parse RD0 persistence and reload preserve exact seed`; null-entry restart test | PASS |
| Reserved diagnostics cannot be overwritten or synthesized | I: preceding preservation tests + `parser cannot synthesize reserved seed on non-document dispatch` | PASS |
| Query vs answer update/delete/bank move never mixes snapshots | Q: `concurrent answer/delete/move is complete before/after, all reads share transaction`; writer is queued after first actual SQL read, full before and after states asserted | PASS |
| Safe query failure has no fabricated counts | Q: `empty durable anomaly is not completed; query failure has no snapshot`; U: `query unavailable never presents fabricated counts` | PASS |
| UI 补充答案 → 待补答案; no whole-bank picker/menu | U: `BankDetail opens queue with four categories and never invokes picker`; `detail missing default, show all, truthful counts and provenance` | PASS |
| Typed old editor: zero legacy provider calls | G: `typed question: legacy answerSingleQuestion calls == 0` | PASS |
| Valid legacy old editor remains usable | G: `legacy question: existing legacy AI path still works` (one fake provider invocation) | PASS |
| Per-document isolation / failed sibling / proposed-bank guard / ZIP boundary | I: independent-document, batch target guard and single-ZIP families | PASS |

## Reproduce local verification

```powershell
$suite = @(
  'test/answer_completion_import_commit_acceptance_test.dart',
  'test/answer_completion_q0_acceptance_test.dart',
  'test/answer_completion_ui_acceptance_test.dart',
  'test/application/answer_completion/answer_completion_supplemental_test.dart',
  'test/application/answer_completion/document_question_set_seed_test.dart',
  'test/domain/answer_completion/imported_question_set_test.dart',
  'test/core/database/answer_completion_v28_schema_test.dart',
  'test/backup/answer_completion_backup_test.dart',
  'test/answer_entry_guard_ui_test.dart',
  'test/application/answers/ai_answer_entry_guard_test.dart',
  'test/ui/pages/p6_supplemental_answer_activation_test.dart',
  'test/ui/pages/p6_supplemental_answer_direct_source_test.dart',
  'test/application/supplemental_answers/target_question_snapshot_service_test.dart',
  'test/application/supplemental_answers/supplemental_answer_activation_service_test.dart',
  'test/acceptance/p6_supplemental_answer_acceptance_test.dart',
  'test/application/answers/answer_candidate_review_session_test.dart',
  'test/application/answers/ai_answer_generation_test.dart',
  'test/application/answers/ai_answer_commit_command_test.dart',
  'test/data/repositories/ai_answer_commit_repository_test.dart',
  'test/p7_ai_answer_ui_acceptance_test.dart',
  'test/p7_v0_acceptance_test.dart',
  'test/architecture_boundary_test.dart'
)
flutter test --concurrency=1 @suite --reporter expanded
dart format --output=none --set-exit-if-changed test/answer_completion_import_commit_acceptance_test.dart
flutter analyze test/answer_completion_import_commit_acceptance_test.dart
git diff --check
```

| Check actually run | Exit / outcome |
| --- | --- |
| Initial focused import suite | 1: new test used nonexistent `typedDraft` getter; corrected to existing `draft` API |
| Focused import suite rerun | 0: 56 tests passed |
| Full authoritative command above | 0: 392 tests passed |
| `dart format` on changed Dart | 0; final run zero changes |
| Format gate | 0; zero changes |
| Focused `flutter analyze` | 0; no issues |
| Initial doc `git diff --check` | 1: inserted CRLF on one roadmap row; normalized line endings |
| Final `git diff --check` | 0 |
| Standing-list check against all 22 paths | 0; missing paths = 0 |

## Standing CI and limits

All 22 files are literal entries in the unconditional `$tests` list in
`.github/workflows/pr-contract-checks.yml`. Four serial-within-shard jobs run
them regardless of changed-file selection; the aggregate job requires every
shard. D1, B0, I0, Q0, U0, P6/P7 and the added V0 lifecycle/rollback cases are
covered. Package C additionally adds the existing D0 value-object and
old-editor Application routing tests to that standing list.

The race evidence queues actual SQLite writers during the actual query read
transaction; it does not model multiple processes/devices. Artifact/source
cleanup evidence exercises persistence seams, not managed-byte I/O. No real
provider, OCR request, private document, app startup, real device or full
repository verification was used. Existing fake-provider tests remain offline.
There was no production/transaction/persistence repair and no semantic repair
cycle. Independent review remains a separate role after delivery; these
Executor checks do not grant merge approval.
