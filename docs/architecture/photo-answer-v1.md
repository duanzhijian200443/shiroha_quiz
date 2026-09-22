# Photo answer v1

Practice fillBlank and shortAnswer support both manual text answers and photo
answers. Choice interactions expose no photo action. Manual text judging keeps
AiService.judgeAnswer; photo answers never pass transcription to that service.

Presentation calls PhotoAnswerJudgementPort with the question kind, question,
standard answer as authoritative RichContent and a transient picker image.
Typed contexts use typedStem and ContentAnswer.content; incompatible typed answer
shapes fail closed. Legacy text is explicitly wrapped in TextNode at the
Presentation projection boundary. Explanation, raw explanation, history and
other questions never enter judgement context.

The pure PhotoAnswerVisionContextProjector preserves text, original LaTeX and
TableNode row/cell/span structure, including table-cell ImageNodes. Image alt
content supplements rather than replaces an image. The adapter resolves durable
ImageNode bytes only through ContentAssetResolver and builds inline assets via
VisionAssetBuilder. Missing/invalid authoritative images and RawFallback context
fail closed before any provider call. Pure-image and table-only contexts are
valid. Attachments and their explicit prompt manifest follow RichContent traversal
order: question images, standard-answer images, then the student image last.
The adapter resolves only the active Vision engine.
One request returns correct/incorrect/uncertain, faithful transcription and brief
feedback. Question data and image content cannot override judgement instructions.
Strict bounded JSON parsing fails closed; only one outer presentation code fence
is tolerated. There is no answer-specific OCR path. Document and question-import
OCR remain independent and unchanged.

The confirmation screen renders transcription with the existing math renderer.
Empty transcription is valid for non-textual answers. Retaking discards the
result. Only explicit submission invokes PhotoAnswerSubmissionCommand, which
copies the original into managed File Library storage, appends one AnswerAttempt,
and compensates failed attempt persistence through the existing
LibraryFileDeletionPort authority. That compensation removes only the file this
same command just created; it adds no second deletion rule and no ownership
change.
Failed compensation is explicitly classified and emits a content-free diagnostic.
This is compensation across file/database operations, not crash-atomic storage.
The entire submission, including compensation, holds one root BackupRestore
mutation lease. Every admitted mutation action owns a scope that admits its own
descendants until that action finishes, so one root lease covers the whole async
tree and a still-running nested action may keep starting nested work after the
root action returned. Callbacks whose owning action has already ended, and
independent workflows, acquire a new lease and remain blocked during
maintenance. The lease is released only once the root and all admitted
descendants have finished.
Preview sessions never ingest images or append attempts. Session kind and duration
retain existing practice semantics. Vision never selects or submits an FSRS grade.

Schema v26 only extends the AnswerAttempt modality CHECK with image. Payload v1
contains source_file_id and optional bounded transcription/feedback; correctness
is exclusively the nullable AnswerAttempt field. Correct maps to true, incorrect
to false, uncertain to null; only false contributes to existing wrong history.
Question/Explanation remain RichContent. Student photo answers are AnswerAttempt
plus optional retained image evidence, never AnswerAttempt RichContent.

source_file_id is a soft evidence reference, not a lifecycle FK. LibraryFile
removal preserves the attempt, correctness, timestamps and review state. Practice
answer history displays 原始作答图片已清理 when the LibraryFile no longer exists.
Retained images participate in the existing B0 LibraryFile inventory; cleaned
references require no placeholder file and do not invalidate backups.

There is no bulk answer-photo cleanup entry. The existing explicit LibraryFile
delete detaches Project/Conversation relations. Bulk cleanup that preserves those
relations requires a separately frozen atomic eligibility/deletion contract;
read-then-delete checks are insufficient. No new ownership rule is introduced.

There is no local OCR, historical image reanalysis, learning-profile inference,
provider binding to a model ID, or multi-model cascade in this capability.
