/// Compatibility bridge to the canonical producer-neutral candidate.
///
/// The single `AnswerCandidate` implementation and the sealed
/// [AnswerCandidateOrigin] hierarchy now live in
/// `domain/answers/answer_candidate.dart`. This legacy path only re-exports
/// them so existing P6 call sites keep compiling; it defines no second
/// candidate implementation and no compatibility state.
library;

export '../answers/answer_candidate.dart';
