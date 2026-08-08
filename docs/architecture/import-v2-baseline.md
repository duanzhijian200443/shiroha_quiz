# Import V2 Baseline and Migration Sequence

Status: **Historical R0A characterization/migration baseline retained for design provenance.**

R1–R8 are complete and the current database schema is v15. Statements below that describe v14 as current, R6/R7/R8 as future work, or old V1 paths as present-day authority are historical baseline facts and must not override `../../ARCHITECTURE.md` or the focused R7/R8 contracts.

## Baseline evidence classes

The suite distinguishes three evidence classes:

1. synthetic fixture or in-test data: safe for default CI and used by R0A;
2. read-only redacted Replay: opt-in acceptance, never written by tests;
3. real OCR: final release evidence only, with explicit authorization.

The 2019 baseline in R0A is synthetic-equivalent only. A redacted, read-only
2019 Replay fixture is not currently available, so the parenthesized numbering
and Roman subquestion contracts do not claim real-document verification.

## Characterized V1 behavior

| Area | Locked behavior |
|---|---|
| 2022-equivalent synthetic import | 22 questions, numbers 1 through 22, no missing explicit answers, Q21 has only `latex_unrenderable`, zero ordinary repair candidates and zero provider/network calls |
| 2019-equivalent synthetic import | sequenced parenthesized Arabic markers are top-level questions; Roman numeral markers remain in their parent; one synthetic document yields 23 ordered questions |
| HTML | unsupported table tags are preserved as raw content and produce `raw_html_tag`; R0A does not create a table node |
| LaTeX | complete formulas use the math renderer; malformed array/matrix environments remain unchanged and fall back locally; no missing `\end{...}` is synthesized |
| `\textcircled{n}` | structural preflight currently accepts the command, but `flutter_math_fork` rejects it and the renderer displays the original formula through its local parse-error fallback; R0A does not normalize or repair it |
| review snapshot | revision, deletion through the current item set, retention override and answer-distillation status survive `ImportTask` map serialization |
| V1 question row | JSON options remain readable, independent explanation wins, `answer|||explanation` remains the fallback, and `raw_explanation` survives |

All R0A test data uses synthetic markers. Test assertions and output contain no
private question text, real answers, absolute paths, credentials, authorization
headers or provider response bodies.

## R0-R8 sequence

Each stage must leave the application compiling, retain a V1 rollback point and
use a focused commit boundary.

| Stage | Single responsibility | Compatibility and rollback point |
|---|---|---|
| R0 | Characterization tests and architecture baseline | No production changes; revert new tests/docs only |
| R1 | Add source/content domain types and pure serializers | Types are unused by production; V1 remains authoritative |
| R2 | Adapt `ParsedDocument` and OCR DTOs into one source model | Dual adapters produce V1-compatible output; privacy policy is a prerequisite |
| R3 | Typed question regions and assembly output | Preserve current Regionizer numbering; project typed drafts back to legacy maps |
| R4 | Typed review issues and revisioned review session | Snapshot dual-read, V1 map write remains available |
| R5 | Renderer consumes `RichContent` through a legacy string bridge | Per-field fallback to the existing renderer |
| R6 | Repository and schema additive V2 persistence | Backup, additive tables/columns, V1/V2 dual-read; no old-column deletion |
| R7 | V2 write becomes authoritative after migration verification | Keep V1 reader and downgrade export for one release boundary |
| R8 | Remove compatibility bridges and obsolete duplicate models | Only after metrics, Replay and migrated-database tests prove no V1 consumers remain |

Do not migrate source model, renderer and database in the same stage. Stable
question numbering and option extraction are protected behavior, not redesign
targets.

## Persistence migration constraints

The current database version is 14. The V1 `questions` row stores:
`type`, string `content`, JSON-string `options`, `standard_answer`, independent
`explanation`, `raw_explanation`, timestamps and bank identity. Some writers
also retain the legacy `answer|||explanation` representation.

The future schema migration must therefore be additive:

- introduce versioned V2 question/content/asset records without deleting V1
  columns;
- back up before migration and run the conversion transactionally;
- dual-read V2 first and V1 fallback while recording safe counts only;
- write V2 plus the minimum V1 compatibility projection until rollback support
  expires;
- move assets through stable IDs and question references, never absolute paths;
- retire `answer|||explanation` only after independent answer/explanation reads
  are verified for old databases;
- on conversion failure, roll back the transaction and continue with the
  untouched V1 reader.

Migration tests must cover a copied synthetic database at each supported old
version, failed conversion rollback, repeated migration idempotence, asset
reference integrity and byte-preserving raw fallback. R0A does not execute a
database migration.

## Verification gates for later stages

Every later stage must retain:

- 2022-equivalent counts/order and its single safe Review;
- 2019-equivalent single-document numbering and order;
- HTML/table raw fallback until a typed table bridge is verified;
- malformed LaTeX preservation without guessed closure;
- zero provider calls in offline acceptance;
- snapshot exit/re-entry behavior;
- V1 database reads.

Real evidence still required later:

- a redacted read-only 2019 question-paper Replay;
- independent redacted Replay evidence for each supported single-document case;
- real simple/complex table samples after a privacy review;
- migrated copies of released V1 databases.

Current smoke and acceptance architecture is single-document only: one PDF is
one independent smoke run and one import task. Multiple PDFs are never
automatically fused. Supplemental-answer document matching is deferred to P6,
requires a newly frozen contract, and must not reuse the deprecated default
two-PDF merge path.
