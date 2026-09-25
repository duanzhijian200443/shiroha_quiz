# IMPORT-UX-1: import target and perfect-result workflow

## Bank identity and selection

The import surface uses **分类 → 题库**. A 分类 is the existing folder
organization backed by `bank_folders` / compatible custom folders. A 题库 is
the actual `QuestionBank` selected by `bankName`. The folder is display and
organization context; users select the bank directly before file or clipboard
parsing. `bankName` remains the current globally unique bank identity. Creating
a proposed bank with an existing name is rejected and the user selects the
existing bank instead. There is no `bankId`, registry, duplicate-name bank,
empty-bank writer, migration, or schema change.

The selector lists existing banks with their optional folder path and question
count. A new bank selection is a proposal (`bankName`, optional `folderName`)
until the first successful question commit creates it through the existing
question and `bank_folders` writer. The separate `last_import_target` setting
silently restores the next task's choice. A deleted previously existing bank
invalidates that remembered choice; it is never silently recreated. A proposed
target may survive restart before its first commit.

## Task and Review authority

Every new document task copies the selected `bankName` and `folderName` into
the existing durable ImportTask fields at dispatch. Every PDF in one independent
batch receives the same immutable snapshot. Retry, resume, Task Center, and
Review use the task fields, never the current `last_import_target` setting.
Existing banks keep their current folder mapping during import; moving a bank
belongs to the existing organization feature.

After parse, IMPORT-RD0 persists the typed document ReviewDraft and positive
revision before Review or optional auto commit. PR B does not initialize that
revision. A typed document task at `pendingReview` with revision 0 is a
lifecycle regression for this workflow. A document Review with a frozen target
shows the path read-only and confirms into that target without a second bank
name dialog. Historical tasks, photo capture, and other entries without a
frozen document target keep the compatible save-location flow.

## Optional perfect-result commit

`autoCommitPerfectImports` defaults to false. When enabled, only a current
document task with a frozen target, `pendingReview` / `readyForReview`, the
`typedV2` / `typed_candidate_ready` route, a positive durable ReviewDraft
revision, nonempty final items, existing final quality score 100, zero errors
and warnings, an unblocked current quality gate, no active commit lease, and a
valid typed review snapshot is eligible. Informational metadata alone does
not block eligibility or change the score algorithm.

The automatic attempt is made only for RD0's newly materialized revision 1.
If Review has already saved a later revision, its manual workflow retains
authority and auto commit is skipped.

The auto path consumes the current durable task ReviewDraft and calls the
existing `ImportCommitService.commitTyped`, typed attempt lease, persisted
revision/attempt CAS, and atomic QuestionRepository transaction. It has no
second question writer and never submits a legacy task. Ineligible or bounded
commit failures leave the task and its Review payload available for manual
Review; the existing completion behavior then decides whether to open Review
or notify. A successful auto commit completes the task and uses the existing
nonblocking notification pattern without opening Review.
