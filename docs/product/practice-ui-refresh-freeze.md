# Practice presentation refresh

## Scope and authority

This focused contract supersedes the historical UI-R1 reuse-only restriction
for Practice presentation. Primary navigation and Today behavior remain governed
by their existing contracts. This refresh changes no Application, Domain,
persistence, provider, schema, or public Practice launch contract.

## Layout and actions

- Practice uses neutral surfaces and soft cards consistent with Today, with
  equivalent light/dark presentation. Reading and fixed action areas are centered
  and limited to 640 logical pixels on wide screens.
- The header identifies the practice/preview surface and real question bank.
  Generation and deletion live in the More menu; deletion keeps its existing
  confirmation and is disabled for preview questions.
- Question type and content remain distinct. Typed content uses RichContent;
  legacy content keeps its existing renderer. Formulas and images are preserved.
- Options are selectable across the row. Selection is neutral before reveal;
  revealed correctness uses text/icons as well as semantic color.
- Subjective questions group text and photo capture under 我的作答. Fill input
  remains single-line; short-answer input remains limited to five lines.
- Before reveal, fixed actions expose 查看答案 for choice questions, or
  查看答案并自评 plus optional 呼叫 AI 助教判卷 for subjective questions.
- Revealed answer/explanation and AI feedback occupy separate sections. Typed
  answer/explanation text uses a readable 16 logical pixel base size.
- Formal sessions retain exactly 重来 / 困难 / 顺利 / 极易, grades 1 / 2 / 3 / 4.
  The rating bar wraps to two columns for narrow/large-text layouts. Preview
  reveal retains 丢弃 / 收入题库 and exposes no FSRS rating bar.
- Content scrolls independently of the action footer, including with the
  keyboard visible. No fixed N/M completion indicator is inferred from a queue
  that may requeue questions.

## Preserved behavior

Typed sidecar authority, strict corrupt-sidecar failure, typed explicit-empty
semantics, option identity, reveal/attempt sequencing and duplicate guards,
normal/focused attribution, photo capture/history, AI invocation, FSRS writes,
requeue behavior and preview persistence retain their existing owners and rules.
Empty subjective self-review produces no invented attempt. AI judging remains
user initiated; relocating controls does not introduce a provider call.

This is a presentation pass; unrelated grading/provider defects and broad
Practice architecture decoupling require separate scope.
