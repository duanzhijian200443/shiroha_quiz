# Review Repair V1

Status: **Current focused contract**.

## Strategies

`StructuralQuestionRepair` retains the existing question-level JSON contract
for `dangling_latex`, `empty_content`, `choice_options_less_than_2`, and
`choice_missing_answer`.

`LatexFragmentRepair` applies only to a pure `latex_unrenderable` review issue.
It requires a frozen typed review snapshot, an unchanged legacy baseline, and
exactly one unrenderable `InlineMathNode` or `BlockMathNode` that aligns
by node index and kind with one also-unrenderable legacy math span. Typed and
legacy content may already differ because of prior normalization; the frozen
legacy span is the fragment/digest authority, while node count and kind remain
strict. Missing, ambiguous, multiple, stale, or unsupported targets stay
manual-review-only with zero provider calls. In V1,
`ImageNode`, `TableNode`, and `RawFallbackNode` make the containing field an
unsupported target rather than allowing repair to cross a structural node.
Mixed structural and LaTeX issues run the structural strategy first and are
audited again before a later fragment attempt.

## Authority and data flow

The Application repair boundary derives fragment identity from the immutable
typed snapshot and legacy baseline. UI renderer fallback state is diagnostic
presentation only and is never repair authority.

The provider receives one fragment plus at most 256 Unicode scalars of the
immediately adjacent text on each side. It is called once and must return only
the corrected fragment body, with the same inline/block node kind and no outer
or nested math delimiter, JSON, Markdown, or explanation. Reasoning content is
never an answer. There is no retry, larger-context escalation, or
whole-question fallback.

The returned fragment must pass the shared LaTeX renderability checker. The
service then performs an exact legacy-span splice and a full final-field audit.
Before producing a proposal it also requires the patched legacy field to retain
the baseline legacy token count, target node index/kind, and every non-target
legacy token value. Only after all gates pass may it produce a proposal. Applying a
proposal remains an explicit user action guarded by the existing review-draft
revision CAS.

## Durable marker

The existing `_review_repair_v1` storage key supports its original schema v1
and an additive schema v2 `latex_fragment` marker. Schema v2 stores only the
field/option locator, node index and kind, and SHA-256 digests of the original
and result field and fragment values. It never stores LaTeX source.

At typed commit, schema v2 is revalidated against the frozen baseline and
current legacy token streams, frozen typed node kinds, replacement span,
renderability, and all digests. Existing typed/legacy normalization differences
on non-target nodes are preserved: the builder clones the original
`RichContent` and replaces exactly the target node. Every other node, option
identity, source reference, asset,
diagnostic, and draft field remains unchanged. Unknown or corrupt markers fail
closed and never grant structural reinterpretation. Schema v1 behavior remains
unchanged. No SQLite migration is introduced.

## Provider and privacy bounds

- fragment: at most 4096 Unicode scalars;
- adjacent context: at most 256 Unicode scalars per side;
- output: at most `min(4096, originalScalars * 4 + 256)` scalars;
- request output cap: 1024 tokens; timeout: at most 90 seconds;
- raw response: at most 64 KiB while streaming.

Diagnostics may contain provider kind/model, HTTP status, response shape,
finish reason, bounded lengths, decode state, and fixed classification only.
They never contain credentials, prompts, question text, LaTeX source,
reasoning text, raw provider bodies, private source content, or paths.

Locator failures use fixed classifications for missing snapshot, identity or
baseline drift, unavailable fields, option mismatch, unsupported nodes,
typed/legacy count/kind mismatch, a typed-bad/legacy-valid target, and
zero/multiple candidates. Shape
metadata is bounded to counts plus at most 32 math-node entries containing only
field, option ordinal, node index/kind, and renderability boolean. A first
typed/legacy mismatch may additionally report both fixed node kinds, both
Unicode-scalar lengths, the unique unrenderable node identity, and whether the
two identities are the same; it never reports either value.
